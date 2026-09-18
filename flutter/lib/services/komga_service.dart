// KomgaService — client autonome pour un serveur Komga externe
// (https://komga.org/), utilisable SANS serveur TamaShelf : la config
// (URL + clé API) est mémorisée en local (SharedPreferences), et tous les
// appels partent directement du téléphone vers Komga. Même principe que
// KavitaService (voir ce fichier pour le détail de l'architecture
// "autonome"), mais Komga est plus simple côté auth : une clé API dans le
// header X-API-Key suffit sur chaque requête, pas d'échange préalable
// contre un jeton JWT (voir openapi.json de Komga : securitySchemes.apiKey
// = header X-API-Key). Les identifiants Komga (séries, livres,
// bibliothèques) sont des chaînes (UUID), contrairement à Kavita (entiers).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class KomgaError implements Exception {
  final String message;
  KomgaError(this.message);
  @override
  String toString() => message;
}

class KomgaService {
  String _serverUrl = '';
  String _apiKey = '';
  Directory? _coverDirCache;
  final Map<String, Uint8List> _seriesCoverCache = {};
  final Map<String, Uint8List> _bookCoverCache = {};

  String get serverUrl => _serverUrl;
  String get apiKey => _apiKey;
  bool get isConfigured => _serverUrl.isNotEmpty && _apiKey.isNotEmpty;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString('komga_url') ?? '';
    _apiKey = prefs.getString('komga_api_key') ?? '';
  }

  Future<void> setConfig(String url, String apiKey) async {
    _serverUrl = (url.endsWith('/') ? url.substring(0, url.length - 1) : url).trim();
    _apiKey = apiKey.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('komga_url', _serverUrl);
    await prefs.setString('komga_api_key', _apiKey);
  }

  Future<void> clearConfig() async {
    _serverUrl = '';
    _apiKey = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('komga_url');
    await prefs.remove('komga_api_key');
  }

  Map<String, String> get _headers => {'X-API-Key': _apiKey};

  Future<http.Response> _request(String method, String path, {Map<String, String>? params, Object? jsonBody}) async {
    if (!isConfigured) throw KomgaError('Serveur Komga non configuré');
    final uri = Uri.parse('$_serverUrl$path').replace(queryParameters: params);
    http.Response resp;
    try {
      switch (method) {
        case 'POST':
          resp = await http.post(uri,
                  headers: {..._headers, if (jsonBody != null) 'Content-Type': 'application/json'},
                  body: jsonBody != null ? jsonEncode(jsonBody) : null)
              .timeout(const Duration(seconds: 30));
          break;
        default:
          resp = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 30));
      }
    } catch (e) {
      throw KomgaError('Serveur Komga injoignable : $e');
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw KomgaError('Clé API Komga invalide ou refusée.');
    }
    if (resp.statusCode >= 400) {
      throw KomgaError('Erreur Komga ${resp.statusCode} sur $path');
    }
    return resp;
  }

  Future<List<Map<String, dynamic>>> libraries() async {
    final resp = await _request('GET', '/api/v1/libraries');
    return (jsonDecode(resp.body) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> seriesInLibrary(String libraryId, {int pageSize = 500}) async {
    final body = {
      'condition': {
        'libraryId': {'operator': 'is', 'value': libraryId},
      },
    };
    final all = <Map<String, dynamic>>[];
    var page = 0;
    while (true) {
      final resp = await _request('POST', '/api/v1/series/list', params: {'page': '$page', 'size': '$pageSize'}, jsonBody: body);
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final content = (data['content'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      all.addAll(content);
      if (data['last'] == true || content.isEmpty) break;
      page++;
      if (page > 100) break; // garde-fou anti-boucle-infinie
    }
    return all;
  }

  Future<Map<String, dynamic>> seriesDetail(String seriesId) async {
    final resp = await _request('GET', '/api/v1/series/$seriesId');
    return Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
  }

  Future<List<Map<String, dynamic>>> booksInSeries(String seriesId, {int pageSize = 500}) async {
    final body = {
      'condition': {
        'seriesId': {'operator': 'is', 'value': seriesId},
      },
    };
    final all = <Map<String, dynamic>>[];
    var page = 0;
    while (true) {
      final resp = await _request('POST', '/api/v1/books/list', params: {'page': '$page', 'size': '$pageSize'}, jsonBody: body);
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final content = (data['content'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      all.addAll(content);
      if (data['last'] == true || content.isEmpty) break;
      page++;
      if (page > 100) break;
    }
    all.sort((a, b) => ((a['number'] as num?) ?? 0).compareTo((b['number'] as num?) ?? 0));
    return all;
  }

  // Covers écrites sur disque (dossier Tamashelf de l'appli) en plus du
  // cache mémoire -- même principe que KavitaService.
  Future<Directory> _coverDir() async {
    if (_coverDirCache != null) return _coverDirCache!;
    Directory base;
    try {
      base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(p.join(base.path, 'Tamashelf', 'komga', 'covers'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _coverDirCache = dir;
    return dir;
  }

  Future<Uint8List> seriesCoverBytes(String seriesId) async {
    final cached = _seriesCoverCache[seriesId];
    if (cached != null) return cached;
    final file = File(p.join((await _coverDir()).path, 'series_${Uri.encodeComponent(seriesId)}.img'));
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      _seriesCoverCache[seriesId] = bytes;
      return bytes;
    }
    final resp = await _request('GET', '/api/v1/series/$seriesId/thumbnail');
    _seriesCoverCache[seriesId] = resp.bodyBytes;
    try { await file.writeAsBytes(resp.bodyBytes); } catch (_) {}
    return resp.bodyBytes;
  }

  Future<Uint8List> bookCoverBytes(String bookId) async {
    final cached = _bookCoverCache[bookId];
    if (cached != null) return cached;
    final file = File(p.join((await _coverDir()).path, 'book_${Uri.encodeComponent(bookId)}.img'));
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      _bookCoverCache[bookId] = bytes;
      return bytes;
    }
    final resp = await _request('GET', '/api/v1/books/$bookId/thumbnail');
    _bookCoverCache[bookId] = resp.bodyBytes;
    try { await file.writeAsBytes(resp.bodyBytes); } catch (_) {}
    return resp.bodyBytes;
  }

  // page : 0-based (zero_based=true), cohérent avec le reste de l'appli
  // (CBZ, Kavita).
  Future<Uint8List> pageBytes(String bookId, int page) async {
    final resp = await _request('GET', '/api/v1/books/$bookId/pages/$page', params: {'zero_based': 'true'});
    return resp.bodyBytes;
  }
}

// Titre à afficher pour une série Komga : metadata.title (éditable dans
// Komga, généralement plus propre) si renseigné, sinon name (nom de
// dossier brut).
String komgaSeriesTitle(Map<String, dynamic> series) {
  final metaTitle = (series['metadata'] is Map) ? (series['metadata']['title']?.toString() ?? '') : '';
  if (metaTitle.trim().isNotEmpty) return metaTitle.trim();
  return (series['name'] ?? '').toString();
}

// Libellé d'un livre Komga : titre de métadonnée s'il existe, sinon
// "Livre <numéro>".
String komgaBookLabel(Map<String, dynamic> book) {
  final metaTitle = (book['metadata'] is Map) ? (book['metadata']['title']?.toString() ?? '') : '';
  if (metaTitle.trim().isNotEmpty) return metaTitle.trim();
  final number = book['number'];
  return number != null ? 'Livre $number' : (book['name'] ?? '?').toString();
}

int komgaPagesCount(Map<String, dynamic> book) {
  final media = book['media'];
  if (media is Map) return (media['pagesCount'] as num?)?.toInt() ?? 0;
  return 0;
}
