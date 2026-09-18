// NautiljonService — client autonome pour tamajon (app.py), le serveur qui
// expose la base Nautiljon scrapée (voir backend/nautiljon_db.py, dont ce
// fichier est un portage Dart). Appelé directement depuis le téléphone --
// PAS via le backend TamaShelf -- pour que le matching fonctionne même sans
// serveur TamaShelf configuré. Les associations (série externe <-> fiche
// Nautiljon) sont mémorisées localement, dans un fichier JSON du dossier
// "Tamashelf" du stockage externe de l'appli (accessible sans permission
// spéciale, contrairement à un vrai dossier public partagé).
//
// PARTAGÉ entre toutes les sources externes (Kavita, Komga, ...) : chaque
// association est clée par "<source>:<seriesId>" (ex: "kavita:42",
// "komga:3f2a..."), le "source" évitant toute collision entre deux
// identifiants de séries qui se ressembleraient d'un serveur à l'autre
// (Kavita utilise des entiers, Komga des UUID -- rien ne garantit qu'ils ne
// se recoupent jamais en tant que chaînes). Les associations créées avant
// l'ajout de Komga (clé "<seriesId>" nue, implicitement Kavita) sont
// migrées vers "kavita:<seriesId>" au premier chargement (voir
// _loadMatches) -- aucune ré-association à refaire.
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

// Trie une liste de résultats pour mettre en premier ceux dont le titre
// commence par (ou contient) le titre de référence -- tamajon ne trie pas
// forcément par pertinence, le bon résultat peut sinon se retrouver loin
// dans la liste. Tri stable : au même rang, l'ordre d'origine est conservé.
List<Map<String, dynamic>> sortByTitleMatch(List<Map<String, dynamic>> results, String referenceTitle) {
  final ref = normalizeMatchKey(referenceTitle);
  if (ref.isEmpty) return results;
  int score(Map<String, dynamic> r) {
    final t = normalizeMatchKey((r['title'] ?? '').toString());
    if (t == ref) return 0;
    if (t.startsWith(ref)) return 1;
    if (ref.startsWith(t) && t.isNotEmpty) return 2;
    if (t.contains(ref)) return 3;
    return 4;
  }
  final indexed = results.asMap().entries.toList();
  indexed.sort((a, b) {
    final c = score(a.value).compareTo(score(b.value));
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return indexed.map((e) => e.value).toList();
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
  final String source; // 'kavita' | 'komga'
  final String seriesId;
  final String seriesName;
  final List<KavitaMatchCandidate> candidates;
  KavitaMatchSuggestion({required this.source, required this.seriesId, required this.seriesName, required this.candidates});
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
          final raw = (data['matches'] as Map).map((k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)));
          // Migration : clé nue "<seriesId>" (avant le partage avec Komga,
          // implicitement Kavita) -> "kavita:<seriesId>".
          var migrated = false;
          _matches = {};
          raw.forEach((k, v) {
            if (k.contains(':')) {
              _matches[k] = v;
            } else {
              _matches['kavita:$k'] = v;
              migrated = true;
            }
          });
          if (migrated) await _saveMatches();
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

  static String matchKey(String source, String seriesId) => '$source:$seriesId';

  Map<String, dynamic>? matchFor(String source, String seriesId) => _matches[matchKey(source, seriesId)];

  // Mêmes catégories que db_service.dart (bibliothèque locale, getAllTags)
  // -- pour rester cohérent si jamais les deux filtres se retrouvent un
  // jour dans le même écran.
  static const _tagCategories = ['Type', 'Genres', 'Themes', 'Statut', 'Editeur', 'Auteur', 'Pays'];

  Map<String, String> _tagMetadataFrom(Map<String, dynamic>? details) {
    if (details == null) return {};
    final out = <String, String>{};
    void put(String key, dynamic v) {
      final s = (v ?? '').toString().trim();
      if (s.isNotEmpty) out[key] = s;
    }
    put('Type', details['type']);
    put('Genres', details['genres']);
    put('Themes', details['themes']);
    put('Statut', details['status']);
    put('Editeur', details['publisher']);
    put('Auteur', details['author']);
    put('Pays', details['country']);
    return out;
  }

  Future<void> saveMatch({
    required String source,
    required String seriesId,
    required String nautiljonUrl,
    required String title,
    String cover = '',
    String matchedBy = 'manual',
  }) async {
    // Récupère la fiche complète pour en tirer les tags (genres/thèmes/...)
    // -- même logique que _kavita_match_metadata côté backend web : les
    // mémoriser au moment du match plutôt que refetcher à chaque affichage
    // de la grille.
    final details = await mangaDetails(nautiljonUrl);
    _matches[matchKey(source, seriesId)] = {
      'source': source,
      'series_id': seriesId,
      'nautiljon_url': nautiljonUrl,
      'title': title,
      'cover_url': cover,
      'matched_by': matchedBy,
      'created_at': DateTime.now().millisecondsSinceEpoch / 1000,
      'metadata': _tagMetadataFrom(details),
    };
    await _saveMatches();
  }

  // Tags disponibles parmi toutes les séries matchées, pour le panneau de
  // filtre (voir KavitaScreen).
  Map<String, Set<String>> allTags({String? source}) {
    final tags = <String, Set<String>>{for (final c in _tagCategories) c: {}};
    for (final entry in _matches.entries) {
      if (source != null && !entry.key.startsWith('$source:')) continue;
      final m = entry.value;
      final meta = m['metadata'];
      if (meta is! Map) continue;
      for (final key in _tagCategories) {
        final val = meta[key]?.toString() ?? '';
        if (val.isEmpty) continue;
        if (key == 'Genres' || key == 'Themes') {
          for (final t in val.split(RegExp(r'\s*[-,]\s*'))) {
            final trimmed = t.trim();
            if (trimmed.isNotEmpty) tags[key]!.add(trimmed);
          }
        } else {
          tags[key]!.add(val.trim());
        }
      }
    }
    tags.removeWhere((k, v) => v.isEmpty);
    return tags;
  }

  // Même sémantique que searchMangas (db_service.dart, bibliothèque locale) :
  // chaque tag sélectionné (toutes catégories confondues) doit être présent
  // -- une série sans match échoue dès qu'un filtre est actif.
  bool matchHasTags(String source, String seriesId, Map<String, List<String>> tagFilters) {
    final hasFilters = tagFilters.values.any((v) => v.isNotEmpty);
    if (!hasFilters) return true;
    final m = matchFor(source, seriesId);
    final meta = (m?['metadata'] is Map) ? Map<String, dynamic>.from(m!['metadata'] as Map) : const <String, dynamic>{};
    for (final entry in tagFilters.entries) {
      if (entry.value.isEmpty) continue;
      final val = (meta[entry.key] ?? '').toString();
      for (final tag in entry.value) {
        if (!val.contains(tag)) return false;
      }
    }
    return true;
  }

  Future<void> deleteMatch(String source, String seriesId) async {
    _matches.remove(matchKey(source, seriesId));
    await _saveMatches();
  }

  // Associations sauvegardées avant l'ajout des tags (voir saveMatch) --
  // n'ont pas de 'metadata', ou une metadata vide. Repasse dessus pour
  // aller chercher leurs tags sans avoir à tout ré-associer à la main.
  // Par défaut ne touche pas aux associations qui ont déjà des tags
  // (force: true pour tout rafraîchir malgré tout).
  Future<int> refreshMissingTags({bool force = false, void Function(int done, int total)? onProgress}) async {
    final entries = _matches.entries.toList();
    var updated = 0;
    for (var i = 0; i < entries.length; i++) {
      final sid = entries[i].key;
      final m = entries[i].value;
      final meta = m['metadata'];
      final hasMeta = meta is Map && meta.isNotEmpty;
      if (!force && hasMeta) {
        onProgress?.call(i + 1, entries.length);
        continue;
      }
      final url = (m['nautiljon_url'] ?? '').toString();
      if (url.isNotEmpty) {
        final details = await mangaDetails(url);
        final newMeta = _tagMetadataFrom(details);
        if (newMeta.isNotEmpty) {
          _matches[sid] = {...m, 'metadata': newMeta};
          updated++;
        }
      }
      onProgress?.call(i + 1, entries.length);
    }
    if (updated > 0) await _saveMatches();
    return updated;
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

  Future<List<Map<String, dynamic>>> search(String query, {int limit = 40, int offset = 0}) async {
    final data = await _get('/api/recherche', {'q': query, 'limit': '$limit', 'offset': '$offset'});
    if (data == null) return [];
    final rows = (data['rows'] as List? ?? []).map((r) => Map<String, dynamic>.from(r as Map));
    return rows.map(_rowToItem).toList();
  }

  // Recherche manuelle (une seule requête, déclenchée par l'utilisateur) --
  // tamajon ne trie pas par pertinence et un mot court/courant (ex: "Che")
  // peut avoir des centaines de résultats, le bon étant parfois hors de la
  // première page. On parcourt donc plusieurs pages jusqu'à tout récupérer
  // (ou une limite raisonnable), on trie par correspondance de titre (voir
  // sortByTitleMatch), puis on ne garde que les meilleurs pour l'affichage.
  // Réservé aux recherches ponctuelles -- PAS utilisé par le matching auto,
  // qui interroge potentiellement des milliers de séries et resterait sur
  // une seule page par requête pour ne pas multiplier les appels réseau.
  Future<List<Map<String, dynamic>>> searchRanked(String query, {int pageSize = 100, int maxFetch = 1000, int maxResults = 80}) async {
    final all = <Map<String, dynamic>>[];
    final ref = normalizeMatchKey(query);
    var offset = 0;
    int? total;
    while (true) {
      final data = await _get('/api/recherche', {'q': query, 'limit': '$pageSize', 'offset': '$offset'});
      if (data == null) break;
      final rows = (data['rows'] as List? ?? []).map((r) => Map<String, dynamic>.from(r as Map)).toList();
      total ??= (data['total'] as num?)?.toInt();
      if (rows.isEmpty) break;
      all.addAll(rows.map(_rowToItem));
      offset += rows.length;
      if (total != null && offset >= total!) break;
      if (offset >= maxFetch) break;
      // Un titre commençant par la requête a déjà été trouvé : inutile
      // d'aller chercher plus loin (cas courant, reste rapide). Sinon on
      // continue jusqu'à maxFetch -- nécessaire pour un mot très courant
      // ("Che") dont le vrai titre peut être noyé sous des centaines de
      // correspondances de synopsis avant d'apparaître.
      if (ref.isNotEmpty && all.any((r) => normalizeMatchKey((r['title'] ?? '').toString()).startsWith(ref))) {
        break;
      }
    }
    return sortByTitleMatch(all, query).take(maxResults).toList();
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
    String source,
    List<Map<String, dynamic>> seriesList, {
    void Function(int done, int total)? onProgress,
  }) async {
    final result = AutoMatchResult();
    var done = 0;
    for (final s in seriesList) {
      done++;
      onProgress?.call(done, seriesList.length);
      final sidRaw = s['id'];
      final name = (s['name'] as String? ?? '').trim();
      if (sidRaw == null || name.isEmpty || _matches.containsKey(matchKey(source, sidRaw.toString()))) continue;
      final sid = sidRaw.toString();

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
        // limit généreux : côté tamajon les résultats ne sont pas toujours
        // triés par pertinence, le bon match peut être loin dans la liste
        // (voir aussi le retrait du plafond sur les suggestions ci-dessous).
        final rs = await search(titre, limit: 40);
        for (final r in rs) {
          final u = (r['url'] ?? '').toString().trim();
          if (u.isNotEmpty && !seen.contains(u)) {
            seen.add(u);
            results.add(r);
          }
        }
      }
      final sortedResults = sortByTitleMatch(results, name);

      Map<String, dynamic>? exact;
      for (final r in results) {
        if (keys.contains(normalizeMatchKey((r['title'] ?? '').toString()))) {
          exact = r;
          break;
        }
      }

      if (exact != null && (exact['url'] ?? '').toString().isNotEmpty) {
        await saveMatch(
            source: source,
            seriesId: sid,
            nautiljonUrl: exact['url'] as String,
            title: (exact['title'] ?? '').toString(),
            cover: (exact['cover_url'] ?? '').toString(),
            matchedBy: 'auto');
        result.autoMatched++;
      } else {
        result.notFound++;
        if (sortedResults.isNotEmpty) {
          result.suggestions.add(KavitaMatchSuggestion(
            source: source,
            seriesId: sid,
            seriesName: name,
            candidates: sortedResults.where((r) => (r['url'] ?? '').toString().isNotEmpty).map((r) => KavitaMatchCandidate(
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
