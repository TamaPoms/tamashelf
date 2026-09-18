// NautiljonService — client autonome pour tamajon (app.py), le serveur qui
// expose la base Nautiljon scrapée (voir backend/nautiljon_db.py, dont ce
// fichier est un portage Dart). Appelé directement depuis le téléphone --
// PAS via le backend TamaShelf -- pour que le matching Kavita fonctionne
// même sans serveur TamaShelf configuré. Les associations (série Kavita <->
// fiche Nautiljon) sont mémorisées localement, dans un fichier JSON du
// dossier "Tamashelf" du stockage externe de l'appli (accessible sans
// permission spéciale, contrairement à un vrai dossier public partagé).
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kDefaultTamajonUrl = 'http://tamashelf.ddns.net:5555';

// Nautiljon bloque le hotlinking (image directe sans Referer) -- headers
// repris de _HEADERS_SCRAPING (tamajon.py) pour les rares images jamais
// re-téléchargées localement par tamajon (voir _rowToItem/imageUrl).
// Envoyés systématiquement (y compris pour les images déjà servies par
// tamajon lui-même) : sans effet dans ce cas, mais évite de dupliquer la
// logique de sélection des headers par URL.
const kNautiljonImageHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Referer': 'https://www.nautiljon.com/mangas/',
  'Accept-Language': 'fr-FR,fr;q=0.9',
};

// ── Normalisation / variantes de titre (portage de main.py) ──

String _stripAccents(String s) {
  const from = 'àáâäãçèéêëìíîïñòóôöõùúûüýÿÀÁÂÄÃÇÈÉÊËÌÍÎÏÑÒÓÔÖÕÙÚÛÜÝ';
  const to = 'aaaaaceeeeiiiinooooouuuuyyAAAAACEEEEIIIINOOOOOUUUUY';
  final buf = StringBuffer();
  for (final ch in s.split('')) {
    final idx = from.indexOf(ch);
    buf.write(idx >= 0 ? to[idx] : ch);
  }
  return buf.toString();
}

final _articleRe = RegExp(r"^(.*?)\s*\((le|la|les|the|l['’]?|un|une|des)\)\s*$", caseSensitive: false);

String normalizeMatchKey(String text) {
  var t = _stripAccents(text.toLowerCase().trim());
  final m = _articleRe.firstMatch(t);
  if (m != null) {
    final base = (m.group(1) ?? '').trim();
    final art = (m.group(2) ?? '').trim();
    t = ('$art $base').trim();
  }
  t = t.replaceAll("l'", 'l ').replaceAll('’', ' ');
  t = t.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _replaceFirst(String s, String from, String to) {
  final idx = s.indexOf(from);
  if (idx < 0) return s;
  return s.substring(0, idx) + to + s.substring(idx + from.length);
}

List<String> matchQueryVariants(String text) {
  final raw = text.trim();
  if (raw.isEmpty) return [];
  final variants = <String>[];
  void add(String v) {
    final vv = v.trim();
    if (vv.isNotEmpty && !variants.contains(vv)) variants.add(vv);
  }
  add(raw);

  if (raw.contains(' - ')) {
    add(_replaceFirst(raw, ' - ', ' : '));
    add(_replaceFirst(raw, ' - ', ': '));
  }
  if (raw.contains(' : ')) {
    add(_replaceFirst(raw, ' : ', ' - '));
    add(_replaceFirst(raw, ' : ', ': '));
  }
  if (raw.contains(': ') && !raw.contains(' : ')) {
    add(_replaceFirst(raw, ': ', ' - '));
    add(_replaceFirst(raw, ': ', ' : '));
  }

  final m = _articleRe.firstMatch(raw);
  if (m != null) {
    final base = (m.group(1) ?? '').trim();
    final art = (m.group(2) ?? '').trim();
    final lart = art.toLowerCase();
    void addArticled(String b) {
      if (lart.startsWith("l'") || lart.startsWith('l’')) {
        add('$art$b');
        add("L'$b");
        add('L’$b');
      } else {
        add('$art $b');
      }
    }
    addArticled(base);
    if (base.contains(' - ')) addArticled(base.replaceAll(' - ', ' : '));
    if (base.contains(' : ')) addArticled(base.replaceAll(' : ', ' - '));
  }
  return variants;
}

const _editionSuffixes = [
  ' - edition', ' - édition', ' edition', ' édition',
  ' - version', ' - deluxe', ' - perfect', ' - ultimate', ' - collector',
];

String stripEditionSuffix(String name) {
  final n = name.trim();
  final low = n.toLowerCase();
  var best = -1;
  for (final sep in _editionSuffixes) {
    final idx = low.indexOf(sep);
    if (idx > 0 && (best == -1 || idx < best)) best = idx;
  }
  return best > 0 ? n.substring(0, best).trim() : n;
}

// ── Résultat de matching auto (une série sans correspondance exacte, mais
// avec au moins un candidat à valider/refuser à la main) ──

class KavitaMatchCandidate {
  final String title;
  final String url;
  final String cover;
  KavitaMatchCandidate({required this.title, required this.url, required this.cover});
}

class KavitaMatchSuggestion {
  final int seriesId;
  final String seriesName;
  final List<KavitaMatchCandidate> candidates;
  KavitaMatchSuggestion({required this.seriesId, required this.seriesName, required this.candidates});
}

class AutoMatchResult {
  int autoMatched = 0;
  int notFound = 0;
  final List<KavitaMatchSuggestion> suggestions = [];
}

class NautiljonService {
  String _baseUrl = kDefaultTamajonUrl;
  Directory? _matchDir;
  Map<String, Map<String, dynamic>> _matches = {}; // seriesId (String) -> match

  String get baseUrl => _baseUrl;
  Map<String, Map<String, dynamic>> get matches => _matches;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('tamajon_url') ?? kDefaultTamajonUrl;
    await _loadMatches();
  }

  Future<void> setBaseUrl(String url) async {
    final u = url.trim();
    _baseUrl = (u.endsWith('/') ? u.substring(0, u.length - 1) : u).isEmpty ? kDefaultTamajonUrl : u;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tamajon_url', _baseUrl);
  }

  // ── Stockage local des associations, dans <stockage appli>/Tamashelf/ ──
  // (dossier visible via un explorateur de fichiers sous
  // Android/data/<app>/files/Tamashelf -- pas d'accès disque public plus
  // large pour éviter la permission MANAGE_EXTERNAL_STORAGE).

  Future<Directory> _dir() async {
    if (_matchDir != null) return _matchDir!;
    Directory base;
    try {
      base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(p.join(base.path, 'Tamashelf'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _matchDir = dir;
    return dir;
  }

  Future<String> get matchesFilePath async => p.join((await _dir()).path, 'kavita_matches.json');

  Future<void> _loadMatches() async {
    try {
      final file = File(await matchesFilePath);
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is Map && data['matches'] is Map) {
          _matches = (data['matches'] as Map).map((k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)));
        }
      }
    } catch (e) {
      print('NautiljonService loadMatches error: $e');
    }
  }

  Future<void> _saveMatches() async {
    try {
      final file = File(await matchesFilePath);
      await file.writeAsString(jsonEncode({'matches': _matches}));
    } catch (e) {
      print('NautiljonService saveMatches error: $e');
    }
  }

  Map<String, dynamic>? matchFor(int seriesId) => _matches['$seriesId'];

  Future<void> saveMatch(int seriesId, {
    required String nautiljonUrl,
    required String title,
    String cover = '',
    String matchedBy = 'manual',
  }) async {
    _matches['$seriesId'] = {
      'nautiljon_url': nautiljonUrl,
      'title': title,
      'cover_url': cover,
      'matched_by': matchedBy,
      'created_at': DateTime.now().millisecondsSinceEpoch / 1000,
    };
    await _saveMatches();
  }

  Future<void> deleteMatch(int seriesId) async {
    _matches.remove('$seriesId');
    await _saveMatches();
  }

  // ── Images ──

  String imageUrl(String? chemin) {
    final c = (chemin ?? '').trim();
    if (c.isEmpty) return '';
    if (c.startsWith('http://') || c.startsWith('https://')) return c;
    final path = c.startsWith('/') ? c : '/$c';
    return '$_baseUrl$path';
  }

  // ── HTTP vers tamajon ──

  Future<Map<String, dynamic>?> _get(String path, [Map<String, String>? params]) async {
    try {
      final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: params);
      final resp = await http.get(uri).timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (e) {
      print('NautiljonService GET $path error: $e');
    }
    return null;
  }

  Future<bool> isAvailable() async {
    final data = await _get('/api/health');
    return data != null && data['ok'] == true && data['table_series'] == true;
  }

  Map<String, dynamic> _rowToItem(Map<String, dynamic> row) {
    var cover = '';
    if ((row['image_jpg'] ?? '').toString().isNotEmpty) {
      cover = imageUrl(row['image_jpg'] as String);
    } else if ((row['image'] ?? '').toString().isNotEmpty) {
      cover = imageUrl(row['image'] as String);
    }
    final synopsis = (row['synopsis'] ?? '').toString();
    return {
      'url': row['url'],
      'title': row['titre'],
      'cover_url': cover,
      'synopsis': synopsis.length > 200 ? synopsis.substring(0, 200) : synopsis,
    };
  }

  Future<List<Map<String, dynamic>>> search(String query, {int limit = 24, int offset = 0}) async {
    final data = await _get('/api/recherche', {'q': query, 'limit': '$limit', 'offset': '$offset'});
    if (data == null) return [];
    final rows = (data['rows'] as List? ?? []).map((r) => Map<String, dynamic>.from(r as Map));
    return rows.map(_rowToItem).toList();
  }

  // Détails complets d'une série par son URL Nautiljon (portage de manga_auto).
  Future<Map<String, dynamic>?> mangaDetails(String url) async {
    if (url.isEmpty) return null;
    final data = await _get('/api/serie/details', {'url': url});
    if (data == null || data['serie'] == null) return null;
    final row = Map<String, dynamic>.from(data['serie'] as Map);
    Map<String, dynamic> infos = {};
    try {
      final brut = row['infos_brutes'];
      if (brut is String && brut.isNotEmpty) {
        final d = jsonDecode(brut);
        if (d is Map) infos = Map<String, dynamic>.from(d);
      }
    } catch (_) {}
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = infos[k];
        if (v != null && v.toString().isNotEmpty) return v.toString();
      }
      return '';
    }

    var coverUrl = '';
    if ((row['image_jpg'] ?? '').toString().isNotEmpty) {
      coverUrl = imageUrl(row['image_jpg'] as String);
    } else if ((row['image'] ?? '').toString().isNotEmpty) {
      coverUrl = imageUrl(row['image'] as String);
    }

    return {
      'title': row['titre'] ?? '',
      'url': url,
      'cover_url': coverUrl,
      'synopsis': row['synopsis'] ?? '',
      'type': row['type'] ?? pick(['Type']),
      'status': pick(['Statut']),
      'country': row['origine'] ?? pick(['Origine']),
      'author': pick(['Auteur', 'Auteurs']),
      'artist': pick(['Dessinateur', 'Dessinateurs']),
      'publisher': pick(['Éditeur VF', 'Éditeurs VF', 'Éditeur VO', 'Éditeurs VO']),
      'year': row['annee_vf'] ?? row['annee_vo'] ?? pick(['Année VF', 'Année VO']),
      'genres': pick(['Genre', 'Genres']),
      'themes': pick(['Thème', 'Thèmes', 'Theme', 'Themes']),
    };
  }

  // ── Matching auto (portage de kavita_auto_match, main.py) ──
  //
  // Uniquement les correspondances exactes (titre normalisé identique) :
  // on cherche avec plusieurs variantes de ponctuation/édition (voir
  // matchQueryVariants/stripEditionSuffix) mais on ne persiste QUE si l'un
  // des résultats a exactement le même titre normalisé. Le reste (des
  // résultats existent mais aucun exact) part en suggestion, à valider ou
  // refuser à la main.
  Future<AutoMatchResult> autoMatch(
    List<Map<String, dynamic>> seriesList, {
    void Function(int done, int total)? onProgress,
  }) async {
    final result = AutoMatchResult();
    var done = 0;
    for (final s in seriesList) {
      done++;
      onProgress?.call(done, seriesList.length);
      final sid = s['id'] as int?;
      final name = (s['name'] as String? ?? '').trim();
      if (sid == null || name.isEmpty || _matches.containsKey('$sid')) continue;

      final nameSansEdition = stripEditionSuffix(name);
      final titres = List<String>.from(matchQueryVariants(name));
      if (nameSansEdition.isNotEmpty && nameSansEdition != name) {
        for (final t in matchQueryVariants(nameSansEdition)) {
          if (!titres.contains(t)) titres.add(t);
        }
      }
      final keys = titres.map(normalizeMatchKey).where((k) => k.isNotEmpty).toSet();

      final results = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final titre in titres) {
        final rs = await search(titre, limit: 8);
        for (final r in rs) {
          final u = (r['url'] ?? '').toString().trim();
          if (u.isNotEmpty && !seen.contains(u)) {
            seen.add(u);
            results.add(r);
          }
        }
      }

      Map<String, dynamic>? exact;
      for (final r in results) {
        if (keys.contains(normalizeMatchKey((r['title'] ?? '').toString()))) {
          exact = r;
          break;
        }
      }

      if (exact != null && (exact['url'] ?? '').toString().isNotEmpty) {
        await saveMatch(sid,
            nautiljonUrl: exact['url'] as String,
            title: (exact['title'] ?? '').toString(),
            cover: (exact['cover_url'] ?? '').toString(),
            matchedBy: 'auto');
        result.autoMatched++;
      } else {
        result.notFound++;
        if (results.isNotEmpty) {
          result.suggestions.add(KavitaMatchSuggestion(
            seriesId: sid,
            seriesName: name,
            candidates: results.take(6).where((r) => (r['url'] ?? '').toString().isNotEmpty).map((r) => KavitaMatchCandidate(
                  title: (r['title'] ?? '').toString(),
                  url: (r['url'] ?? '').toString(),
                  cover: (r['cover_url'] ?? '').toString(),
                )).toList(),
          ));
        }
      }
    }
    return result;
  }
}
