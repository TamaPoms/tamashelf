import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/manga.dart';

class DbService {
  Database? _db;
  String _serverUrl = '';
  String _token = '';
  String _role = '';
  String _username = '';

  String get serverUrl => _serverUrl;
  bool get isConfigured => _serverUrl.isNotEmpty;
  bool get isLoggedIn => _token.isNotEmpty;
  bool get isAdmin => _role == 'admin';
  String get currentUsername => _username;


  String _normalizeTitleKey(String input) {
    var out = input.toLowerCase().trim();
    const repl = {
      'à':'a','á':'a','â':'a','ä':'a','ã':'a',
      'ç':'c',
      'è':'e','é':'e','ê':'e','ë':'e',
      'ì':'i','í':'i','î':'i','ï':'i',
      'ñ':'n',
      'ò':'o','ó':'o','ô':'o','ö':'o','õ':'o',
      'ù':'u','ú':'u','û':'u','ü':'u',
      'ý':'y','ÿ':'y',
    };
    repl.forEach((k, v) => out = out.replaceAll(k, v));
    out = out.replaceAll(RegExp(r"[^a-z0-9]+"), ' ').replaceAll(RegExp(r"\s+"), ' ').trim();
    return out;
  }

  ({String baseTitle, String editionLabel}) _splitEditionTitle(String title) {
    final raw = title.trim();
    if (raw.isEmpty) return (baseTitle: '', editionLabel: '');
    final parts = raw.split(RegExp(r'\s+[\-–—]\s+'));
    if (parts.length >= 2) {
      final suffix = parts.last.trim();
      if (RegExp(r'(edition|édition|deluxe|perfect|collector|ultimate|kanzen|prestige|complete|int[eé]grale|version)', caseSensitive: false).hasMatch(suffix)) {
        return (baseTitle: parts.sublist(0, parts.length - 1).join(' - ').trim(), editionLabel: suffix);
      }
    }
    return (baseTitle: raw, editionLabel: '');
  }

  List<Manga> _groupMangas(List<Manga> items) {
    final groups = <String, List<Manga>>{};
    for (final item in items) {
      final split = _splitEditionTitle(item.title);
      final normalized = Manga(
        id: item.id,
        cbzFolder: item.cbzFolder,
        title: item.title,
        coverUrl: item.coverUrl,
        synopsis: item.synopsis,
        matchStatus: item.matchStatus,
        nautiljonUrl: item.nautiljonUrl,
        metadata: item.metadata,
        editions: item.editions,
        hasCover: item.hasCover,
        baseTitle: split.baseTitle.isNotEmpty ? split.baseTitle : item.title,
        editionLabel: split.editionLabel,
      );
      final key = _normalizeTitleKey(normalized.baseTitle.isNotEmpty ? normalized.baseTitle : normalized.title);
      groups.putIfAbsent(key, () => []).add(normalized);
    }
    final out = <Manga>[];
    for (final variants in groups.values) {
      variants.sort((a, b) {
        final aScore = a.editionLabel.isEmpty ? 0 : 1;
        final bScore = b.editionLabel.isEmpty ? 0 : 1;
        if (aScore != bScore) return aScore - bScore;
        return a.title.length.compareTo(b.title.length);
      });
      final primary = variants.first;
      out.add(Manga(
        id: primary.id,
        cbzFolder: primary.cbzFolder,
        title: primary.baseTitle.isNotEmpty ? primary.baseTitle : primary.title,
        coverUrl: primary.coverUrl,
        synopsis: primary.synopsis,
        matchStatus: primary.matchStatus,
        nautiljonUrl: primary.nautiljonUrl,
        metadata: primary.metadata,
        editions: primary.editions,
        hasCover: primary.hasCover,
        baseTitle: primary.baseTitle.isNotEmpty ? primary.baseTitle : primary.title,
        editionLabel: primary.editionLabel,
        variants: variants,
      ));
    }
    out.sort((a, b) => a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase()));
    return out;
  }

  // ── Init ──

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString('server_url') ?? '';
    _token = prefs.getString('auth_token') ?? '';
    _role = prefs.getString('auth_role') ?? '';
    _username = prefs.getString('auth_username') ?? '';
    await _openDb();
  }

  Future<void> setServer(String url) async {
    _serverUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', _serverUrl);
  }

  // ── Auth ──

  String lastError = '';

  Future<bool> login(String username, String password) async {
    lastError = '';
    try {
      final url = '$_serverUrl/api/login';
      print('LOGIN: POST $url');
      final resp = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      ).timeout(const Duration(seconds: 10));
      
      print('LOGIN: status=${resp.statusCode} body=${resp.body.substring(0, (resp.body.length > 200) ? 200 : resp.body.length)}');
      
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final token = data['token'] as String?;
        if (token != null && token.isNotEmpty) {
          _token = token;
          _role = (data['role'] as String?) ?? '';
          _username = username.trim();
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('auth_token', _token);
          await prefs.setString('auth_role', _role);
          await prefs.setString('auth_username', _username);
          return true;
        }
        lastError = 'Pas de token dans la réponse';
      } else {
        lastError = 'Erreur ${resp.statusCode}: ${resp.body}';
      }
    } catch (e) {
      lastError = 'Erreur réseau: $e';
      print('LOGIN ERROR: $e');
    }
    return false;
  }

  Map<String, String> get authHeaders => {
    'Authorization': 'Bearer $_token',
  };

  // ── Database sync ──

  Future<String> get _dbPath async {
    final dir = await getApplicationDocumentsDirectory();
    // Nom de fichier volontairement inchangé (mangashelf.db), comme l'applicationId
    // Android : ce dossier applicatif contient déjà, chez les utilisateurs existants,
    // la BDD locale synchronisée (bibliothèque, tomes téléchargés) -- la renommer ferait
    // perdre cet accès local jusqu'à une resynchronisation manuelle.
    return p.join(dir.path, 'mangashelf.db');
  }

  Future<void> _openDb() async {
    try {
      final path = await _dbPath;
      if (await File(path).exists()) {
        _db = await openDatabase(path);
        print('DB opened: $path');
      }
    } catch (e) {
      print('DB open error: $e');
    }
  }

  Future<bool> syncDatabase() async {
    if (_serverUrl.isEmpty || _token.isEmpty) {
      lastError = 'Serveur ou token manquant';
      return false;
    }
    try {
      final url = '$_serverUrl/api/export/db';
      print('SYNC: GET $url');
      final resp = await http.get(
        Uri.parse(url),
        headers: authHeaders,
      ).timeout(const Duration(minutes: 5));
      
      print('SYNC: status=${resp.statusCode} size=${resp.bodyBytes.length}');
      
      if (resp.statusCode == 200 && resp.bodyBytes.length > 1000) {
        // Close existing DB
        await _db?.close();
        _db = null;

        // Write new DB
        final path = await _dbPath;
        await File(path).writeAsBytes(resp.bodyBytes);

        // Reopen
        _db = await openDatabase(path);
        return true;
      } else {
        lastError = 'Sync: HTTP ${resp.statusCode}, taille=${resp.bodyBytes.length}';
      }
    } catch (e) {
      lastError = 'Sync erreur: $e';
      print('SYNC ERROR: $e');
    }
    return false;
  }

  bool get hasLocalDb => _db != null;

  // ── Queries ──

  Future<List<Map<String, dynamic>>> getLibraries() async {
    if (_db == null) return [];
    try {
      final rows = await _db!.rawQuery(
        'SELECT l.id, l.name, COUNT(m.id) as count '
        'FROM libraries l LEFT JOIN manga_library m ON m.library_id = l.id '
        'GROUP BY l.id ORDER BY l.name'
      );
      return rows.map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (e) {
      print('getLibraries error: $e');
      return [];
    }
  }

  // contentType: null=all, 'tome'=only with tomes, 'chapter'=only with chapters
  Future<List<Manga>> getMangas({String? search, String? letter, int? libraryId, String? contentType}) async {
    if (_db == null) return [];
    try {
      String where = '1=1';
      List<dynamic> args = [];

      if (libraryId != null) {
        where += ' AND library_id = ?';
        args.add(libraryId);
      }

      if (search != null && search.isNotEmpty) {
        where += ' AND (title LIKE ? OR cbz_folder LIKE ?)';
        args.addAll(['%$search%', '%$search%']);
      }

      if (letter != null) {
        if (letter == '#') {
          where += " AND UPPER(SUBSTR(title,1,1)) NOT BETWEEN 'A' AND 'Z'";
        } else {
          where += ' AND UPPER(SUBSTR(title,1,1)) = ?';
          args.add(letter.toUpperCase());
        }
      }

      if (contentType != null) {
        where += ' AND id IN (SELECT DISTINCT m2.id FROM manga_library m2 '
                 'INNER JOIN manga_volumes v2 ON v2.cbz_folder = m2.cbz_folder '
                 'WHERE v2.volume_type = ?)';
        args.add(contentType);
      }

      final rows = await _db!.rawQuery(
        'SELECT id, cbz_folder, title, cover_url, synopsis, match_status, nautiljon_url, metadata_json, editions_json, '
        'CASE WHEN cover_blob IS NOT NULL THEN 1 ELSE 0 END as has_cover '
        'FROM manga_library WHERE $where ORDER BY title COLLATE NOCASE',
        args,
      );
      return _groupMangas(rows.map((r) => Manga.fromMap(r)).toList());
    } catch (e) {
      print('getMangas error: $e');
      return [];
    }
  }

  Future<int> getMangaCount() async {
    if (_db == null) return 0;
    return (await getMangas()).length;
  }

  Future<Uint8List?> getMangaCover(int mangaId) async {
    if (_db == null) return null;
    try {
      final rows = await _db!.query(
        'manga_library',
        columns: ['cover_blob'],
        where: 'id = ?',
        whereArgs: [mangaId],
      );
      if (rows.isNotEmpty && rows.first['cover_blob'] != null) {
        return rows.first['cover_blob'] as Uint8List;
      }
    } catch (e) {
      print('getCover error: $e');
    }
    return null;
  }

  Future<List<Volume>> getVolumes(String cbzFolder) async {
    if (_db == null) return [];
    final rows = await _db!.query(
      'manga_volumes',
      where: 'cbz_folder = ?',
      whereArgs: [cbzFolder],
      orderBy: 'volume_type ASC, volume_num ASC, filename ASC',
    );

    final Map<String, Volume> dedup = {};
    for (final r in rows) {
      final v = Volume.fromMap(r);
      final key = v.volumeType != null && v.volumeNum != null
          ? '${v.volumeType}:${v.volumeNum}'
          : 'file:${v.filename}';
      dedup.putIfAbsent(key, () => v);
    }
    return dedup.values.toList();
  }

  Future<Manga?> getGroupedManga(int id) async {
    final manga = await getManga(id);
    if (manga == null || _db == null) return manga;
    final rows = await _db!.rawQuery(
      'SELECT id, cbz_folder, title, cover_url, synopsis, match_status, nautiljon_url, metadata_json, editions_json, '
      'CASE WHEN cover_blob IS NOT NULL THEN 1 ELSE 0 END as has_cover '
      'FROM manga_library ORDER BY title COLLATE NOCASE'
    );
    final grouped = _groupMangas(rows.map((r) => Manga.fromMap(r)).toList());
    for (final g in grouped) {
      if (g.allVariants.any((v) => v.id == id)) return g;
    }
    return manga;
  }

  Future<Manga?> getGroupedMangaByFolder(String cbzFolder) async {
    if (_db == null) return null;
    final rows = await _db!.rawQuery(
      'SELECT id, cbz_folder, title, cover_url, synopsis, match_status, nautiljon_url, metadata_json, editions_json, '
      'CASE WHEN cover_blob IS NOT NULL THEN 1 ELSE 0 END as has_cover '
      'FROM manga_library ORDER BY title COLLATE NOCASE'
    );
    final grouped = _groupMangas(rows.map((r) => Manga.fromMap(r)).toList());
    for (final g in grouped) {
      if (g.allVariants.any((v) => v.cbzFolder == cbzFolder)) return g;
    }
    return null;
  }

  Future<List<Volume>> getGroupedVolumes(Manga manga) async {
    final out = <Volume>[];
    for (final variant in manga.allVariants) {
      final vols = await getVolumes(variant.cbzFolder);
      out.addAll(vols.map((v) => v.copyWith(
        cbzFolder: variant.cbzFolder,
        editionFolder: variant.cbzFolder,
        editionLabel: variant.editionLabel,
      )));
    }
    return out;
  }

  Future<Manga?> getManga(int id) async {
    if (_db == null) return null;
    try {
      final rows = await _db!.rawQuery(
        'SELECT id, cbz_folder, title, cover_url, synopsis, match_status, '
        'nautiljon_url, metadata_json, editions_json, '
        'CASE WHEN cover_blob IS NOT NULL THEN 1 ELSE 0 END as has_cover '
        'FROM manga_library WHERE id = ?',
        [id],
      );
      if (rows.isEmpty) return null;
      return Manga.fromMap(rows.first);
    } catch (e) {
      print('getManga error: $e');
      return null;
    }
  }

  // Extract all unique tags from metadata_json (Genres, Themes, Type)

  Future<Manga?> getMangaByFolder(String cbzFolder) async {
    if (_db == null) return null;
    try {
      final rows = await _db!.rawQuery(
        'SELECT id, cbz_folder, title, cover_url, synopsis, match_status, '
        'nautiljon_url, metadata_json, editions_json, '
        'CASE WHEN cover_blob IS NOT NULL THEN 1 ELSE 0 END as has_cover '
        'FROM manga_library WHERE cbz_folder = ? LIMIT 1',
        [cbzFolder],
      );
      if (rows.isEmpty) return null;
      return Manga.fromMap(rows.first);
    } catch (e) {
      print('getMangaByFolder error: $e');
      return null;
    }
  }

  Future<Map<String, Set<String>>> getAllTags() async {
    if (_db == null) return {};
    try {
      final rows = await _db!.rawQuery(
        'SELECT metadata_json FROM manga_library WHERE metadata_json IS NOT NULL AND metadata_json != \'{}\''
      );
      final tags = <String, Set<String>>{
        'Type': {},
        'Genres': {},
        'Themes': {},
        'Statut': {},
        'Editeur': {},
        'Auteur': {},
        'Pays': {},
      };
      for (final row in rows) {
        try {
          final json = row['metadata_json'] as String?;
          if (json == null || json.isEmpty) continue;
          final meta = jsonDecode(json);
          if (meta is! Map) continue;
          for (final key in tags.keys) {
            final val = meta[key]?.toString() ?? '';
            if (val.isEmpty) continue;
            // Split by ' - ' for multi-value fields (Nautiljon format)
            if (key == 'Genres' || key == 'Themes') {
              for (final t in val.split(' - ')) {
                final trimmed = t.trim();
                if (trimmed.isNotEmpty) tags[key]!.add(trimmed);
              }
            } else {
              tags[key]!.add(val.trim());
            }
          }
        } catch (_) {}
      }
      // Remove empty categories
      tags.removeWhere((k, v) => v.isEmpty);
      return tags;
    } catch (e) {
      print('getAllTags error: $e');
      return {};
    }
  }

  // Search mangas with tag filters
  Future<List<Manga>> searchMangas({
    String? search,
    String? letter,
    int? libraryId,
    String? contentType,
    Map<String, List<String>>? tagFilters,
  }) async {
    if (_db == null) return [];
    try {
      String where = '1=1';
      List<dynamic> args = [];

      if (libraryId != null) {
        where += ' AND library_id = ?';
        args.add(libraryId);
      }

      if (search != null && search.isNotEmpty) {
        where += ' AND (title LIKE ? OR cbz_folder LIKE ?)';
        args.addAll(['%$search%', '%$search%']);
      }

      if (letter != null) {
        if (letter == '#') {
          where += " AND UPPER(SUBSTR(title,1,1)) NOT BETWEEN 'A' AND 'Z'";
        } else {
          where += ' AND UPPER(SUBSTR(title,1,1)) = ?';
          args.add(letter.toUpperCase());
        }
      }

      if (contentType != null) {
        where += ' AND id IN (SELECT DISTINCT m2.id FROM manga_library m2 '
                 'INNER JOIN manga_volumes v2 ON v2.cbz_folder = m2.cbz_folder '
                 'WHERE v2.volume_type = ?)';
        args.add(contentType);
      }

      if (tagFilters != null) {
        for (final entry in tagFilters.entries) {
          if (entry.value.isEmpty) continue;
          for (final tag in entry.value) {
            where += ' AND metadata_json LIKE ?';
            args.add('%$tag%');
          }
        }
      }

      final rows = await _db!.rawQuery(
        'SELECT id, cbz_folder, title, cover_url, synopsis, match_status, nautiljon_url, metadata_json, editions_json, '
        'CASE WHEN cover_blob IS NOT NULL THEN 1 ELSE 0 END as has_cover '
        'FROM manga_library WHERE $where ORDER BY title COLLATE NOCASE',
        args,
      );
      return _groupMangas(rows.map((r) => Manga.fromMap(r)).toList());
    } catch (e) {
      print('searchMangas error: $e');
      return [];
    }
  }

  // ── Admin / Matching API ──

  Future<List<Manga>> getUnmatchedMangas() async {
    if (_db == null) return [];
    try {
      final rows = await _db!.rawQuery(
        "SELECT id, cbz_folder, title, cover_url, synopsis, match_status, nautiljon_url, "
        "CASE WHEN cover_blob IS NOT NULL THEN 1 ELSE 0 END as has_cover "
        "FROM manga_library WHERE match_status = 'unmatched' ORDER BY title COLLATE NOCASE"
      );
      return rows.map((r) => Manga.fromMap(r)).toList();
    } catch (e) {
      print('getUnmatchedMangas error: $e');
      return [];
    }
  }

  Future<bool> validateMatch(int mangaId, String nautiljonUrl) async {
    if (_serverUrl.isEmpty || !isLoggedIn) return false;
    try {
      final resp = await http.post(
        Uri.parse('$_serverUrl/api/admin/validate-match/$mangaId?nautiljon_url=${Uri.encodeComponent(nautiljonUrl)}'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 20));
      return resp.statusCode == 200;
    } catch (e) {
      print('validateMatch error: $e');
      return false;
    }
  }

  Future<bool> resetMatch(int mangaId) async {
    if (_serverUrl.isEmpty || !isLoggedIn) return false;
    try {
      final resp = await http.post(
        Uri.parse('$_serverUrl/api/admin/reset-match/$mangaId'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 10));
      return resp.statusCode == 200;
    } catch (e) {
      print('resetMatch error: $e');
      return false;
    }
  }

  /// Recherche rapide via l'API locale (pas d'enrichissement, rapide)
  Future<List<Map<String, dynamic>>> nautiljonSearchFast(String query) async {
    if (_serverUrl.isEmpty || !isLoggedIn) return [];
    try {
      final resp = await http.get(
        Uri.parse('$_serverUrl/api/nautiljon/search?q=${Uri.encodeComponent(query.trim())}&limit=24'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        return (data['results'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
    } catch (e) {
      print('nautiljonSearchFast error: $e');
    }
    return [];
  }

  /// Recherche web sur nautiljon.com (scraping, plus complet mais plus lent)
  Future<List<Map<String, dynamic>>> nautiljonSearchWeb(String query) async {
    if (_serverUrl.isEmpty || !isLoggedIn) return [];
    try {
      final resp = await http.get(
        Uri.parse('$_serverUrl/api/nautiljon/search-web?q=${Uri.encodeComponent(query.trim())}&limit=24'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        return (data['results'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
    } catch (e) {
      print('nautiljonSearchWeb error: $e');
    }
    return [];
  }

  Future<Map<String, List<UserListItem>>> getUserLists() async {
    if (_serverUrl.isEmpty || _token.isEmpty) {
      return {'read': [], 'to_read': []};
    }
    try {
      final resp = await http.get(
        Uri.parse('$_serverUrl/api/lists'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'Listes: HTTP ${resp.statusCode}';
        return {'read': [], 'to_read': []};
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      List<UserListItem> parse(String key) => ((data[key] as List?) ?? const [])
          .map((e) => UserListItem.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
      return {'read': parse('read'), 'to_read': parse('to_read')};
    } catch (e) {
      lastError = 'Listes erreur: $e';
      print('getUserLists error: $e');
      return {'read': [], 'to_read': []};
    }
  }

  Future<bool> addUserListItem({
    required String listName,
    required String mangaUrl,
    String volumeId = '',
    String itemType = '',
    String title = '',
    bool autoAdded = false,
  }) async {
    if (_serverUrl.isEmpty || _token.isEmpty) return false;
    try {
      final resp = await http.post(
        Uri.parse('$_serverUrl/api/lists'),
        headers: {'Content-Type': 'application/json', ...authHeaders},
        body: jsonEncode({
          'list_name': listName,
          'manga_url': mangaUrl,
          'volume_id': volumeId,
          'item_type': itemType,
          'title': title,
          'auto_added': autoAdded,
        }),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) return true;
      lastError = 'Ajout liste: HTTP ${resp.statusCode}';
    } catch (e) {
      lastError = 'Ajout liste erreur: $e';
      print('addUserListItem error: $e');
    }
    return false;
  }

  // ── Homepage ──
  Future<Map<String, dynamic>> getHomepage() async {
    if (_serverUrl.isEmpty || _token.isEmpty) return {};
    try {
      final resp = await http.get(
        Uri.parse('$_serverUrl/api/homepage'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) { print('getHomepage error: $e'); }
    return {};
  }

  // ── Stats ──
  Future<Map<String, dynamic>> getStats() async {
    if (_serverUrl.isEmpty || _token.isEmpty) return {};
    try {
      final resp = await http.get(
        Uri.parse('$_serverUrl/api/stats'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) { print('getStats error: $e'); }
    return {};
  }

  Future<bool> logActivity({int pages = 0, int volumes = 0, int seconds = 0}) async {
    if (_serverUrl.isEmpty || _token.isEmpty) return false;
    try {
      final resp = await http.post(
        Uri.parse('$_serverUrl/api/stats/log-activity'),
        headers: {'Content-Type': 'application/json', ...authHeaders},
        body: jsonEncode({'pages': pages, 'volumes': volumes, 'seconds': seconds}),
      ).timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) { return false; }
  }

  // ── Ratings ──
  Future<Map<int, int>> getRatings() async {
    if (_serverUrl.isEmpty || _token.isEmpty) return {};
    try {
      final resp = await http.get(
        Uri.parse('$_serverUrl/api/ratings'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map) return data.map((k, v) => MapEntry(int.parse(k.toString()), (v as num).toInt()));
      }
    } catch (e) { print('getRatings error: $e'); }
    return {};
  }

  Future<bool> setRating(int mangaId, int rating) async {
    if (_serverUrl.isEmpty || _token.isEmpty) return false;
    try {
      final resp = await http.put(
        Uri.parse('$_serverUrl/api/ratings/$mangaId?rating=$rating'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) { return false; }
  }

  Future<bool> deleteRating(int mangaId) async {
    if (_serverUrl.isEmpty || _token.isEmpty) return false;
    try {
      final resp = await http.delete(
        Uri.parse('$_serverUrl/api/ratings/$mangaId'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) { return false; }
  }

  // ── Notes ──
  Future<Map<int, String>> getNotes() async {
    if (_serverUrl.isEmpty || _token.isEmpty) return {};
    try {
      final resp = await http.get(
        Uri.parse('$_serverUrl/api/notes'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map) return data.map((k, v) => MapEntry(int.parse(k.toString()), v.toString()));
      }
    } catch (e) { print('getNotes error: $e'); }
    return {};
  }

  Future<bool> saveNote(int mangaId, String note) async {
    if (_serverUrl.isEmpty || _token.isEmpty) return false;
    try {
      final resp = await http.post(
        Uri.parse('$_serverUrl/api/notes/$mangaId/save'),
        headers: {'Content-Type': 'application/json', ...authHeaders},
        body: jsonEncode({'note': note}),
      ).timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) { return false; }
  }

  // ── Collections ──
  Future<List<Map<String, dynamic>>> getCollections() async {
    if (_serverUrl.isEmpty || _token.isEmpty) return [];
    try {
      final resp = await http.get(
        Uri.parse('$_serverUrl/api/collections'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        return (jsonDecode(resp.body) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (e) { print('getCollections error: $e'); }
    return [];
  }

  Future<int?> createCollection({required String name, String description = '', String color = '#6366f1', String icon = '📚'}) async {
    if (_serverUrl.isEmpty || _token.isEmpty) return null;
    try {
      final resp = await http.post(
        Uri.parse('$_serverUrl/api/collections'),
        headers: {'Content-Type': 'application/json', ...authHeaders},
        body: jsonEncode({'name': name, 'description': description, 'color': color, 'icon': icon}),
      ).timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        return data['id'] as int?;
      }
    } catch (e) { print('createCollection error: $e'); }
    return null;
  }

  Future<bool> deleteCollection(int id) async {
    if (_serverUrl.isEmpty || _token.isEmpty) return false;
    try {
      final resp = await http.delete(
        Uri.parse('$_serverUrl/api/collections/$id'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) { return false; }
  }

  Future<bool> addToCollection(int collectionId, int mangaId) async {
    if (_serverUrl.isEmpty || _token.isEmpty) return false;
    try {
      final resp = await http.post(
        Uri.parse('$_serverUrl/api/collections/$collectionId/add'),
        headers: {'Content-Type': 'application/json', ...authHeaders},
        body: jsonEncode({'manga_id': mangaId}),
      ).timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) { return false; }
  }

  Future<bool> removeFromCollection(int collectionId, int mangaId) async {
    if (_serverUrl.isEmpty || _token.isEmpty) return false;
    try {
      final resp = await http.delete(
        Uri.parse('$_serverUrl/api/collections/$collectionId/remove/$mangaId'),
        headers: authHeaders,
      ).timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) { return false; }
  }

  // ── Change password ──
  Future<bool> changePassword(String oldPassword, String newPassword) async {
    if (_serverUrl.isEmpty || _token.isEmpty) return false;
    lastError = '';
    try {
      final resp = await http.post(
        Uri.parse('$_serverUrl/api/change-password'),
        headers: {'Content-Type': 'application/json', ...authHeaders},
        body: jsonEncode({'old_password': oldPassword, 'new_password': newPassword}),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) return true;
      final data = jsonDecode(resp.body);
      lastError = data['detail']?.toString() ?? 'Erreur ${resp.statusCode}';
    } catch (e) { lastError = 'Erreur: $e'; }
    return false;
  }

  Future<bool> deleteUserListItem({
    required String listName,
    required String mangaUrl,
    String volumeId = '',
    String itemType = '',
  }) async {
    if (_serverUrl.isEmpty || _token.isEmpty) return false;
    try {
      final uri = Uri.parse('$_serverUrl/api/lists').replace(queryParameters: {
        'list_name': listName,
        'manga_url': mangaUrl,
        'volume_id': volumeId,
        'item_type': itemType,
      });
      final resp = await http.delete(uri, headers: authHeaders).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) return true;
      lastError = 'Suppression liste: HTTP ${resp.statusCode}';
    } catch (e) {
      lastError = 'Suppression liste erreur: $e';
      print('deleteUserListItem error: $e');
    }
    return false;
  }
}
