// KavitaService — client autonome pour un serveur Kavita externe
// (https://www.kavitareader.com/), utilisable SANS serveur TamaShelf : la
// config (URL + clé API) est mémorisée en local (SharedPreferences), et
// tous les appels partent directement du téléphone vers Kavita. Portage
// Dart de backend/kavita_client.py -- mêmes endpoints, même logique
// d'authentification (voir les commentaires là-bas pour le détail des
// choix, ex. pourquoi userId/apiKey sont nécessaires en plus du Bearer).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class KavitaError implements Exception {
  final String message;
  KavitaError(this.message);
  @override
  String toString() => message;
}

const _pluginName = 'TamaShelf-Android';
const _tokenAssumedLifetime = 3 * 3600;
const _tokenSafetyMargin = 300;

int? _jwtUserId(String token) {
  try {
    final parts = token.split('.');
    var payload = parts[1];
    payload += '=' * ((4 - payload.length % 4) % 4);
    final decoded = utf8.decode(base64Url.decode(payload));
    final claims = jsonDecode(decoded) as Map<String, dynamic>;
    final v = claims['nameid'];
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
  } catch (_) {}
  return null;
}

class KavitaService {
  String _serverUrl = '';
  String _apiKey = '';
  String? _token;
  int? _userId;
  double _tokenExpiresAt = 0;
  final Map<int, Uint8List> _seriesCoverCache = {};
  final Map<int, Uint8List> _chapterCoverCache = {};
  Directory? _coverDirCache;

  // Covers écrites sur disque (dossier Tamashelf de l'appli) en plus du
  // cache mémoire -- pour rester instantanées après un redémarrage de
  // l'appli plutôt que de tout re-télécharger à chaque ouverture.
  Future<Directory> _coverDir() async {
    if (_coverDirCache != null) return _coverDirCache!;
    Directory base;
    try {
      base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(p.join(base.path, 'Tamashelf', 'kavita', 'covers'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _coverDirCache = dir;
    return dir;
  }

  String get serverUrl => _serverUrl;
  String get apiKey => _apiKey;
  bool get isConfigured => _serverUrl.isNotEmpty && _apiKey.isNotEmpty;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString('kavita_url') ?? '';
    _apiKey = prefs.getString('kavita_api_key') ?? '';
  }

  Future<void> setConfig(String url, String apiKey) async {
    _serverUrl = (url.endsWith('/') ? url.substring(0, url.length - 1) : url).trim();
    _apiKey = apiKey.trim();
    _token = null;
    _userId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('kavita_url', _serverUrl);
    await prefs.setString('kavita_api_key', _apiKey);
  }

  Future<void> clearConfig() async {
    _serverUrl = '';
    _apiKey = '';
    _token = null;
    _userId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('kavita_url');
    await prefs.remove('kavita_api_key');
  }

  Future<String> _authenticate() async {
    if (!isConfigured) throw KavitaError('Serveur Kavita non configuré');
    http.Response resp;
    try {
      resp = await http.post(
        Uri.parse('$_serverUrl/api/Plugin/authenticate').replace(queryParameters: {
          'apiKey': _apiKey,
          'pluginName': _pluginName,
        }),
      ).timeout(const Duration(seconds: 15));
    } catch (e) {
      throw KavitaError('Serveur Kavita injoignable : $e');
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw KavitaError('Clé API Kavita invalide ou refusée.');
    }
    if (resp.statusCode != 200) {
      throw KavitaError('Échec de l\'authentification Kavita (HTTP ${resp.statusCode}).');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final token = data['token'] as String?;
    if (token == null || token.isEmpty) {
      throw KavitaError('Réponse d\'authentification Kavita invalide (pas de jeton).');
    }
    _token = token;
    final id = data['id'];
    _userId = (id is int && id != 0) ? id : _jwtUserId(token);
    _tokenExpiresAt = DateTime.now().millisecondsSinceEpoch / 1000 + _tokenAssumedLifetime - _tokenSafetyMargin;
    return token;
  }

  Future<Map<String, String>> _authHeaders({bool forceRefresh = false}) async {
    if (forceRefresh || _token == null || DateTime.now().millisecondsSinceEpoch / 1000 >= _tokenExpiresAt) {
      await _authenticate();
    }
    return {'Authorization': 'Bearer $_token'};
  }

  Future<http.Response> _request(String method, String path, {Map<String, String>? params, Object? jsonBody}) async {
    final headers = await _authHeaders();
    Future<http.Response> send(Map<String, String> h) {
      final uri = Uri.parse('$_serverUrl$path').replace(queryParameters: params);
      switch (method) {
        case 'POST':
          return http.post(uri, headers: {...h, if (jsonBody != null) 'Content-Type': 'application/json'}, body: jsonBody != null ? jsonEncode(jsonBody) : null).timeout(const Duration(seconds: 30));
        default:
          return http.get(uri, headers: h).timeout(const Duration(seconds: 30));
      }
    }

    http.Response resp;
    try {
      resp = await send(headers);
    } catch (e) {
      throw KavitaError('Serveur Kavita injoignable : $e');
    }
    if (resp.statusCode == 401) {
      final h2 = await _authHeaders(forceRefresh: true);
      try {
        resp = await send(h2);
      } catch (e) {
        throw KavitaError('Serveur Kavita injoignable : $e');
      }
    }
    if (resp.statusCode >= 400) {
      throw KavitaError('Erreur Kavita ${resp.statusCode} sur $path');
    }
    return resp;
  }

  Future<List<Map<String, dynamic>>> libraries() async {
    if (_userId == null) await _authHeaders();
    final resp = await _request('GET', '/api/Library/user-libraries', params: _userId != null ? {'userId': '$_userId'} : null);
    return (jsonDecode(resp.body) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> seriesInLibrary(int libraryId, {int pageSize = 500}) async {
    final body = {
      'statements': [
        {'comparison': 0, 'field': 19, 'value': '$libraryId'}
      ],
      'combination': 1,
    };
    final all = <Map<String, dynamic>>[];
    var page = 1;
    while (true) {
      final resp = await _request('POST', '/api/Series/v2',
          params: {'PageNumber': '$page', 'PageSize': '$pageSize'}, jsonBody: body);
      final batch = (jsonDecode(resp.body) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (batch.isEmpty) break;
      all.addAll(batch);
      if (batch.length < pageSize) break;
      page++;
      if (page > 50) break;
    }
    return all;
  }

  Future<Map<String, dynamic>> seriesDetail(int seriesId) async {
    final resp = await _request('GET', '/api/Series/$seriesId');
    return Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
  }

  // Métadonnées éditables d'une série (résumé, genres, tags, statut, ...) --
  // voir pushNautiljonToKavita (kavita_screen.dart) pour l'usage : on
  // récupère la fiche complète, on ne modifie que certains champs, puis on
  // renvoie l'ensemble (l'API Kavita remplace tout le bloc SeriesMetadata,
  // ce n'est pas un patch partiel comme Komga).
  Future<Map<String, dynamic>> seriesMetadata(int seriesId) async {
    final resp = await _request('GET', '/api/Series/metadata', params: {'seriesId': '$seriesId'});
    return Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
  }

  Future<void> updateSeriesMetadata(Map<String, dynamic> metadata) async {
    await _request('POST', '/api/Series/metadata', jsonBody: {'seriesMetadata': metadata});
  }

  Future<List<Map<String, dynamic>>> volumes(int seriesId) async {
    final resp = await _request('GET', '/api/Series/volumes', params: {'seriesId': '$seriesId'});
    return (jsonDecode(resp.body) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> chapterInfo(int chapterId) async {
    final resp = await _request('GET', '/api/Reader/chapter-info', params: {'chapterId': '$chapterId'});
    return Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
  }

  Future<Uint8List> pageBytes(int chapterId, int page) async {
    final resp = await _request('GET', '/api/Reader/image', params: {
      'chapterId': '$chapterId',
      'page': '$page',
      'apiKey': _apiKey,
    });
    return resp.bodyBytes;
  }

  Future<Uint8List> seriesCoverBytes(int seriesId) async {
    final cached = _seriesCoverCache[seriesId];
    if (cached != null) return cached;
    final file = File(p.join((await _coverDir()).path, 'series_$seriesId.img'));
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      _seriesCoverCache[seriesId] = bytes;
      return bytes;
    }
    final resp = await _request('GET', '/api/Image/series-cover', params: {'seriesId': '$seriesId'});
    _seriesCoverCache[seriesId] = resp.bodyBytes;
    try { await file.writeAsBytes(resp.bodyBytes); } catch (_) {}
    return resp.bodyBytes;
  }

  Future<Uint8List> chapterCoverBytes(int chapterId) async {
    final cached = _chapterCoverCache[chapterId];
    if (cached != null) return cached;
    final file = File(p.join((await _coverDir()).path, 'chapter_$chapterId.img'));
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      _chapterCoverCache[chapterId] = bytes;
      return bytes;
    }
    final resp = await _request('GET', '/api/Image/chapter-cover', params: {'chapterId': '$chapterId'});
    _chapterCoverCache[chapterId] = resp.bodyBytes;
    try { await file.writeAsBytes(resp.bodyBytes); } catch (_) {}
    return resp.bodyBytes;
  }
}
