import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import '../models/manga.dart';
import 'db_service.dart';

class DownloadInfo {
  final String filename;
  final String volumePath;
  double progress;
  bool isDone;
  bool hasError;
  String? error;

  DownloadInfo({
    required this.filename,
    required this.volumePath,
    this.progress = 0,
    this.isDone = false,
    this.hasError = false,
    this.error,
  });
}

class DownloadService {
  final DbService db;
  final Map<String, DownloadInfo> activeDownloads = {};
  final List<Function()> _listeners = [];

  DownloadService(this.db);

  void addListener(Function() listener) => _listeners.add(listener);
  void removeListener(Function() listener) => _listeners.remove(listener);
  void _notify() {
    for (final l in _listeners) l();
  }

  Future<String> get _mangaDir async {
    final dir = await getApplicationDocumentsDirectory();
    final mangaDir = Directory(p.join(dir.path, 'manga'));
    if (!await mangaDir.exists()) await mangaDir.create(recursive: true);
    return mangaDir.path;
  }

  // Check if a volume is downloaded locally
  Future<bool> isDownloaded(Volume vol) async {
    final dir = await _mangaDir;
    final file = File(p.join(dir, vol.filename));
    return file.exists();
  }

  // Get local path for a downloaded volume
  Future<String?> getLocalPath(Volume vol) async {
    final dir = await _mangaDir;
    final file = File(p.join(dir, vol.filename));
    if (await file.exists()) return file.path;
    return null;
  }

  // Get all downloaded files
  Future<List<Map<String, dynamic>>> getDownloadedFiles() async {
    final dir = await _mangaDir;
    final mangaDir = Directory(dir);
    if (!await mangaDir.exists()) return [];

    final files = <Map<String, dynamic>>[];
    await for (final entity in mangaDir.list()) {
      if (entity is File) {
        final stat = await entity.stat();
        files.add({
          'name': p.basename(entity.path),
          'path': entity.path,
          'size': stat.size,
          'modified': stat.modified,
        });
      }
    }
    files.sort((a, b) => (b['modified'] as DateTime).compareTo(a['modified'] as DateTime));
    return files;
  }

  // Download a volume (CBZ) from server
  Future<bool> downloadVolume(Volume vol) async {
    if (db.serverUrl.isEmpty) return false;

    final info = DownloadInfo(filename: vol.filename, volumePath: vol.filepath);
    activeDownloads[vol.filepath] = info;
    _notify();

    try {
      final url = '${db.serverUrl}/api/cbz/download/${vol.filepath}';
      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(db.authHeaders);

      final response = await http.Client().send(request);
      if (response.statusCode != 200) {
        info.hasError = true;
        info.error = 'HTTP ${response.statusCode}';
        _notify();
        return false;
      }

      final contentLength = response.contentLength ?? 0;
      final dir = await _mangaDir;
      final file = File(p.join(dir, vol.filename));
      final sink = file.openWrite();
      int received = 0;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          info.progress = received / contentLength;
          _notify();
        }
      }
      await sink.close();

      info.isDone = true;
      info.progress = 1.0;
      _notify();
      return true;
    } catch (e) {
      info.hasError = true;
      info.error = e.toString();
      _notify();
      return false;
    }
  }

  // Delete a downloaded file
  Future<bool> deleteFile(String filename) async {
    final dir = await _mangaDir;
    final file = File(p.join(dir, filename));
    if (await file.exists()) {
      await file.delete();
      return true;
    }
    return false;
  }

  // Extract pages from a local CBZ file
  Future<List<String>> extractPages(String localPath) async {
    final dir = await _mangaDir;
    final cbzName = p.basenameWithoutExtension(localPath);
    final pagesDir = Directory(p.join(dir, '.pages', cbzName));

    // Check if already extracted
    if (await pagesDir.exists()) {
      final pages = await pagesDir.list().where((e) => e is File).toList();
      final paths = pages.map((e) => e.path).toList();
      paths.sort();
      return paths;
    }

    // Extract
    await pagesDir.create(recursive: true);
    final bytes = await File(localPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final imgExts = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};
    final imageFiles = archive.files.where((f) {
      if (f.isFile) {
        final ext = p.extension(f.name).toLowerCase();
        final name = p.basename(f.name);
        return imgExts.contains(ext) && !name.startsWith('.');
      }
      return false;
    }).toList();

    imageFiles.sort((a, b) => a.name.compareTo(b.name));

    final paths = <String>[];
    for (int i = 0; i < imageFiles.length; i++) {
      final f = imageFiles[i];
      final ext = p.extension(f.name);
      final pagePath = p.join(pagesDir.path, '${i.toString().padLeft(4, '0')}$ext');
      final file = File(pagePath);
      await file.writeAsBytes(f.content as List<int>);
      paths.add(pagePath);
    }
    return paths;
  }

  // Delete extracted pages cache
  Future<void> clearPagesCache(String localPath) async {
    final dir = await _mangaDir;
    final cbzName = p.basenameWithoutExtension(localPath);
    final pagesDir = Directory(p.join(dir, '.pages', cbzName));
    if (await pagesDir.exists()) {
      await pagesDir.delete(recursive: true);
    }
  }

  // Total downloaded size
  Future<int> getTotalDownloadedSize() async {
    final files = await getDownloadedFiles();
    return files.fold<int>(0, (sum, f) => sum + (f['size'] as int));
  }
}
