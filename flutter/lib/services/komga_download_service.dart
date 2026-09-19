// KomgaDownloadService — téléchargement de livres Komga pour lecture
// hors-ligne. Même principe que KavitaDownloadService (voir ce fichier) :
// pages récupérées une par une et écrites sur le stockage de l'appli,
// dossier Tamashelf/komga/books/<bookId>/. Identifiants Komga en String
// (UUID), contrairement à Kavita (entiers).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'komga_service.dart';

class KomgaDownloadInfo {
  final String bookId;
  final String label;
  int done;
  int total;
  bool isDone;
  bool hasError;
  String? error;

  KomgaDownloadInfo({
    required this.bookId,
    required this.label,
    this.done = 0,
    this.total = 0,
    this.isDone = false,
    this.hasError = false,
    this.error,
  });

  double get progress => total > 0 ? done / total : 0;
}

class KomgaDownloadService {
  final KomgaService komga;
  KomgaDownloadService(this.komga);

  final Map<String, KomgaDownloadInfo> activeDownloads = {};
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
    final dir = Directory(p.join(base.path, 'Tamashelf', 'komga'));
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
      print('KomgaDownloadService loadManifest error: $e');
    }
  }

  Future<void> _saveManifest() async {
    try {
      final f = await _manifestFile();
      await f.writeAsString(jsonEncode(_manifest));
    } catch (e) {
      print('KomgaDownloadService saveManifest error: $e');
    }
  }

  Future<Directory> _bookDir(String bookId) async {
    final dir = Directory(p.join((await _root()).path, 'books', Uri.encodeComponent(bookId)));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<bool> isDownloaded(String bookId) async {
    await _loadManifest();
    return _manifest.containsKey(bookId);
  }

  Future<Map<String, dynamic>?> info(String bookId) async {
    await _loadManifest();
    final v = _manifest[bookId];
    if (v == null) return null;
    return {'bookId': bookId, ...Map<String, dynamic>.from(v as Map)};
  }

  Future<Set<String>> downloadedIds() async {
    await _loadManifest();
    return _manifest.keys.toSet();
  }

  Future<List<Map<String, dynamic>>> listDownloads() async {
    await _loadManifest();
    final list = _manifest.entries
        .map((e) => {'bookId': e.key, ...Map<String, dynamic>.from(e.value as Map)})
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

  Future<Uint8List?> localPageBytes(String bookId, int page) async {
    await _loadManifest();
    if (!_manifest.containsKey(bookId)) return null;
    final file = File(p.join((await _bookDir(bookId)).path, 'page_${page.toString().padLeft(4, '0')}.img'));
    if (await file.exists()) return file.readAsBytes();
    return null;
  }

  Future<bool> downloadBook({
    required String bookId,
    required String seriesId,
    required String seriesName,
    required String label,
    required int totalPages,
  }) async {
    if (await isDownloaded(bookId)) return true;
    if (totalPages <= 0) return false;
    final info = KomgaDownloadInfo(bookId: bookId, label: label, total: totalPages);
    activeDownloads[bookId] = info;
    _notify();
    try {
      final dir = await _bookDir(bookId);
      var size = 0;
      for (var page = 0; page < totalPages; page++) {
        final bytes = await komga.pageBytes(bookId, page);
        final file = File(p.join(dir.path, 'page_${page.toString().padLeft(4, '0')}.img'));
        await file.writeAsBytes(bytes);
        size += bytes.length;
        info.done = page + 1;
        _notify();
      }
      await _loadManifest();
      _manifest[bookId] = {
        'seriesId': seriesId,
        'seriesName': seriesName,
        'label': label,
        'totalPages': totalPages,
        'createdAt': DateTime.now().millisecondsSinceEpoch / 1000,
        'sizeBytes': size,
      };
      await _saveManifest();
      info.isDone = true;
      activeDownloads.remove(bookId);
      _notify();
      return true;
    } catch (e) {
      info.hasError = true;
      info.error = '$e';
      _notify();
      return false;
    }
  }

  Future<void> deleteBook(String bookId) async {
    await _loadManifest();
    _manifest.remove(bookId);
    await _saveManifest();
    try {
      final dir = Directory(p.join((await _root()).path, 'books', Uri.encodeComponent(bookId)));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      print('KomgaDownloadService deleteBook error: $e');
    }
    _notify();
  }
}
