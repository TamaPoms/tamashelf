import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'db_service.dart';

class ProgressEntry {
  final String mangaUrl;
  final String volumeId;
  final int currentPage;
  final int totalPages;
  final String title;
  final double lastRead;
  bool needsSync;

  ProgressEntry({
    required this.mangaUrl,
    required this.volumeId,
    required this.currentPage,
    required this.totalPages,
    required this.title,
    required this.lastRead,
    this.needsSync = false,
  });

  factory ProgressEntry.fromJson(Map<String, dynamic> m) => ProgressEntry(
    mangaUrl: m['manga_url'] as String? ?? '',
    volumeId: m['volume_id'] as String? ?? '',
    currentPage: m['current_page'] as int? ?? 0,
    totalPages: m['total_pages'] as int? ?? 0,
    title: m['title'] as String? ?? '',
    lastRead: (m['last_read'] as num?)?.toDouble() ?? 0,
    needsSync: m['needs_sync'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'manga_url': mangaUrl,
    'volume_id': volumeId,
    'current_page': currentPage,
    'total_pages': totalPages,
    'title': title,
    'last_read': lastRead,
    'needs_sync': needsSync,
  };

  double get percent => totalPages > 0 ? currentPage / totalPages : 0;
  bool get isFinished => totalPages > 0 && currentPage >= totalPages - 1;
  String get key => '$mangaUrl::$volumeId';
}

class ProgressService {
  final DbService db;
  Map<String, ProgressEntry> _entries = {};
  final List<Function()> _listeners = [];

  ProgressService(this.db);

  void addListener(Function() l) => _listeners.add(l);
  void removeListener(Function() l) => _listeners.remove(l);
  void _notify() { for (final l in _listeners) l(); }

  List<ProgressEntry> get entries {
    final list = _entries.values.toList();
    list.sort((a, b) => b.lastRead.compareTo(a.lastRead));
    return list;
  }

  List<ProgressEntry> get inProgress =>
    entries.where((e) => !e.isFinished && e.currentPage > 0).toList();

  ProgressEntry? getProgress(String mangaUrl, String volumeId) =>
    _entries['$mangaUrl::$volumeId'];

  // ── Local storage ──

  Future<void> loadLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('reading_progress');
      if (json != null) {
        final list = jsonDecode(json) as List;
        _entries.clear();
        for (final item in list) {
          final entry = ProgressEntry.fromJson(item as Map<String, dynamic>);
          _entries[entry.key] = entry;
        }
      }
    } catch (e) {
      print('ProgressService loadLocal error: $e');
    }
  }

  Future<void> _saveLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _entries.values.map((e) => e.toJson()).toList();
      await prefs.setString('reading_progress', jsonEncode(list));
    } catch (e) {
      print('ProgressService saveLocal error: $e');
    }
  }

  // ── Update progress (local + queue sync) ──

  Future<void> updateProgress({
    required String mangaUrl,
    required String volumeId,
    required int currentPage,
    required int totalPages,
    required String title,
  }) async {
    final entry = ProgressEntry(
      mangaUrl: mangaUrl,
      volumeId: volumeId,
      currentPage: currentPage,
      totalPages: totalPages,
      title: title,
      lastRead: DateTime.now().millisecondsSinceEpoch / 1000,
      needsSync: true,
    );
    _entries[entry.key] = entry;
    await _saveLocal();
    _notify();

    // Try to sync immediately
    await _syncEntry(entry);
  }

  // ── Sync with server ──

  Future<void> _syncEntry(ProgressEntry entry) async {
    if (db.serverUrl.isEmpty || !db.isLoggedIn) return;
    try {
      final resp = await http.post(
        Uri.parse('${db.serverUrl}/api/progress'),
        headers: {
          'Content-Type': 'application/json',
          ...db.authHeaders,
        },
        body: jsonEncode({
          'manga_url': entry.mangaUrl,
          'volume_id': entry.volumeId,
          'current_page': entry.currentPage,
          'total_pages': entry.totalPages,
          'title': entry.title,
        }),
      ).timeout(const Duration(seconds: 5));

      if (resp.statusCode == 200) {
        entry.needsSync = false;
        await _saveLocal();
      }
    } catch (e) {
      print('Sync progress error: $e');
      // Keep needsSync = true, will retry later
    }
  }

  // Sync all pending entries
  Future<int> syncPending() async {
    int synced = 0;
    final pending = _entries.values.where((e) => e.needsSync).toList();
    for (final entry in pending) {
      await _syncEntry(entry);
      if (!entry.needsSync) synced++;
    }
    return synced;
  }

  // Fetch all progress from server and merge
  Future<void> fetchFromServer() async {
    if (db.serverUrl.isEmpty || !db.isLoggedIn) return;
    try {
      final resp = await http.get(
        Uri.parse('${db.serverUrl}/api/progress'),
        headers: db.authHeaders,
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        for (final item in list) {
          final remote = ProgressEntry.fromJson(item as Map<String, dynamic>);
          final local = _entries[remote.key];
          // Keep the most recent one
          if (local == null || remote.lastRead > local.lastRead) {
            _entries[remote.key] = remote;
          }
        }
        await _saveLocal();
        _notify();
      }
    } catch (e) {
      print('Fetch progress error: $e');
    }
  }

  // Full sync: push pending, then pull from server
  Future<void> fullSync() async {
    await syncPending();
    await fetchFromServer();
    await syncPending(); // Re-sync any local-only entries
  }

  // Delete progress
  Future<void> deleteProgress(String mangaUrl, String volumeId) async {
    _entries.remove('$mangaUrl::$volumeId');
    await _saveLocal();
    _notify();

    // Try to delete on server too
    if (db.serverUrl.isNotEmpty && db.isLoggedIn) {
      try {
        await http.delete(
          Uri.parse('${db.serverUrl}/api/progress?manga_url=$mangaUrl&volume_id=$volumeId'),
          headers: db.authHeaders,
        ).timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }
}
