// KavitaDownloadService — téléchargement de chapitres Kavita pour lecture
// hors-ligne. Les pages sont récupérées une par une via KavitaService (pas
// d'endpoint "chapitre en zip" côté client) et écrites sur le stockage de
// l'appli, dossier Tamashelf/kavita/chapters/<chapterId>/ -- même racine que
// les covers (kavita_service.dart) et les associations Nautiljon
// (nautiljon_service.dart). Un manifeste JSON (downloads.json) mémorise quels
// chapitres sont complets, pour lister/supprimer sans re-scanner le disque.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'kavita_service.dart';

class KavitaDownloadInfo {
  final int chapterId;
  final String label;
  int done;
  int total;
  bool isDone;
  bool hasError;
  String? error;

  KavitaDownloadInfo({
    required this.chapterId,
    required this.label,
    this.done = 0,
    this.total = 0,
    this.isDone = false,
    this.hasError = false,
    this.error,
  });

  double get progress => total > 0 ? done / total : 0;
}

class KavitaDownloadService {
  final KavitaService kavita;
  KavitaDownloadService(this.kavita);

  final Map<int, KavitaDownloadInfo> activeDownloads = {};
  final List<Function()> _listeners = [];
  void addListener(Function() l) => _listeners.add(l);
  void removeListener(Function() l) => _listeners.remove(l);
  void _notify() { for (final l in _listeners) l(); }

  Map<String, dynamic> _manifest = {};
  bool _manifestLoaded = false;

  Future<Directory> _root() async {
    Directory base;
    try {
      base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(p.join(base.path, 'Tamashelf', 'kavita'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _manifestFile() async => File(p.join((await _root()).path, 'downloads.json'));

  Future<void> _loadManifest() async {
    if (_manifestLoaded) return;
    _manifestLoaded = true;
    try {
      final f = await _manifestFile();
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString());
        if (data is Map) _manifest = Map<String, dynamic>.from(data);
      }
    } catch (e) {
      print('KavitaDownloadService loadManifest error: $e');
    }
  }

  Future<void> _saveManifest() async {
    try {
      final f = await _manifestFile();
      await f.writeAsString(jsonEncode(_manifest));
    } catch (e) {
      print('KavitaDownloadService saveManifest error: $e');
    }
  }

  Future<Directory> _chapterDir(int chapterId) async {
    final dir = Directory(p.join((await _root()).path, 'chapters', '$chapterId'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<bool> isDownloaded(int chapterId) async {
    await _loadManifest();
    return _manifest.containsKey('$chapterId');
  }

  Future<Map<String, dynamic>?> info(int chapterId) async {
    await _loadManifest();
    final v = _manifest['$chapterId'];
    if (v == null) return null;
    return {'chapterId': chapterId, ...Map<String, dynamic>.from(v as Map)};
  }

  Future<Set<int>> downloadedIds() async {
    await _loadManifest();
    return _manifest.keys.map(int.parse).toSet();
  }

  Future<List<Map<String, dynamic>>> listDownloads() async {
    await _loadManifest();
    final list = _manifest.entries
        .map((e) => {'chapterId': int.parse(e.key), ...Map<String, dynamic>.from(e.value as Map)})
        .toList();
    list.sort((a, b) => ((b['createdAt'] as num?) ?? 0).compareTo((a['createdAt'] as num?) ?? 0));
    return list;
  }

  Future<int> totalSize() async {
    await _loadManifest();
    var total = 0;
    for (final v in _manifest.values) {
      total += ((v as Map)['sizeBytes'] as num? ?? 0).toInt();
    }
    return total;
  }

  // Octets d'une page déjà téléchargée, ou null si le chapitre n'est pas
  // (encore) disponible hors-ligne -- ReaderScreen l'essaie en premier (voir
  // kavita_screen.dart) avant de retomber sur le réseau.
  Future<Uint8List?> localPageBytes(int chapterId, int page) async {
    await _loadManifest();
    if (!_manifest.containsKey('$chapterId')) return null;
    final file = File(p.join((await _chapterDir(chapterId)).path, 'page_${page.toString().padLeft(4, '0')}.img'));
    if (await file.exists()) return file.readAsBytes();
    return null;
  }

  Future<bool> downloadChapter({
    required int chapterId,
    required int seriesId,
    required String seriesName,
    required String label,
    required int totalPages,
  }) async {
    if (await isDownloaded(chapterId)) return true;
    if (totalPages <= 0) return false;
    final info = KavitaDownloadInfo(chapterId: chapterId, label: label, total: totalPages);
    activeDownloads[chapterId] = info;
    _notify();
    try {
      final dir = await _chapterDir(chapterId);
      var size = 0;
      for (var page = 0; page < totalPages; page++) {
        final bytes = await kavita.pageBytes(chapterId, page);
        final file = File(p.join(dir.path, 'page_${page.toString().padLeft(4, '0')}.img'));
        await file.writeAsBytes(bytes);
        size += bytes.length;
        info.done = page + 1;
        _notify();
      }
      await _loadManifest();
      _manifest['$chapterId'] = {
        'seriesId': seriesId,
        'seriesName': seriesName,
        'label': label,
        'totalPages': totalPages,
        'createdAt': DateTime.now().millisecondsSinceEpoch / 1000,
        'sizeBytes': size,
      };
      await _saveManifest();
      info.isDone = true;
      activeDownloads.remove(chapterId);
      _notify();
      return true;
    } catch (e) {
      info.hasError = true;
      info.error = '$e';
      _notify();
      return false;
    }
  }

  Future<void> deleteChapter(int chapterId) async {
    await _loadManifest();
    _manifest.remove('$chapterId');
    await _saveManifest();
    try {
      final dir = Directory(p.join((await _root()).path, 'chapters', '$chapterId'));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      print('KavitaDownloadService deleteChapter error: $e');
    }
    _notify();
  }
}
