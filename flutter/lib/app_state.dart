import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/db_service.dart';
import 'services/download_service.dart';
import 'services/progress_service.dart';
import 'services/update_service.dart';
import 'services/kavita_service.dart';
import 'services/kavita_download_service.dart';
import 'services/komga_service.dart';
import 'services/komga_download_service.dart';
import 'services/nautiljon_service.dart';
import 'models/manga.dart';

class AppState extends ChangeNotifier {
  final DbService db = DbService();
  late final DownloadService downloads;
  late final ProgressService progress;
  final UpdateService _updateService = UpdateService();
  // Kavita/Komga + Nautiljon (tamajon) : entièrement autonomes du serveur
  // TamaShelf -- config et associations mémorisées en local (voir les
  // services), pour fonctionner même sans serveur TamaShelf configuré. Le
  // matching Nautiljon (NautiljonService) est PARTAGÉ entre Kavita et Komga
  // (voir nautiljon_service.dart : clés "<source>:<seriesId>").
  final KavitaService kavita = KavitaService();
  final KomgaService komga = KomgaService();
  final NautiljonService nautiljon = NautiljonService();
  late final KavitaDownloadService kavitaDownloads;
  late final KomgaDownloadService komgaDownloads;
  UpdateInfo? updateInfo;

  bool isLoading = false;
  bool isSyncing = false;
  String? error;
  List<Manga> mangas = [];
  int mangaCount = 0;
  String searchQuery = '';
  String? letterFilter;
  Map<String, List<String>> tagFilters = {};
  Map<String, Set<String>> availableTags = {};
  int? libraryFilter;
  List<Map<String, dynamic>> libraries = [];
  String? contentType; // null=all, 'tome', 'chapter'
  List<UserListItem> toReadItems = [];
  List<UserListItem> readItems = [];
  Map<int, int> ratings = {};
  Map<int, String> notes = {};
  bool showKavitaShortcut = true;
  bool showKomgaShortcut = true;

  void notifyAllListeners() => notifyListeners();

  AppState() {
    downloads = DownloadService(db);
    downloads.addListener(notifyListeners);
    progress = ProgressService(db);
    progress.addListener(notifyListeners);
    kavitaDownloads = KavitaDownloadService(kavita);
    kavitaDownloads.addListener(notifyListeners);
    komgaDownloads = KomgaDownloadService(komga);
    komgaDownloads.addListener(notifyListeners);
  }

  Future<void> init() async {
    try {
      await db.init();
      await progress.loadLocal();
      await kavita.init();
      await komga.init();
      await nautiljon.init();
      final prefs = await SharedPreferences.getInstance();
      showKavitaShortcut = prefs.getBool('show_kavita_shortcut') ?? true;
      showKomgaShortcut = prefs.getBool('show_komga_shortcut') ?? true;
      if (db.hasLocalDb) {
        await loadMangas();
        availableTags = await db.getAllTags();
        libraries = await db.getLibraries();
        await loadLists();
        // Try to sync progress with server
        try { await progress.fullSync(); } catch (_) {}
        await loadLists();
        // Load ratings and notes
        try { ratings = await db.getRatings(); } catch (_) {}
        try { notes = await db.getNotes(); } catch (_) {}
      }
    } catch (e) {
      error = 'Erreur init: $e';
      print('INIT ERROR: $e');
    }
    notifyListeners();
  }

  Future<void> loadMangas() async {
    isLoading = true;
    notifyListeners();

    try {
      final hasTagFilters = tagFilters.values.any((v) => v.isNotEmpty);
      if (hasTagFilters) {
        mangas = await db.searchMangas(
          search: searchQuery.isEmpty ? null : searchQuery,
          letter: letterFilter,
          libraryId: libraryFilter,
          contentType: contentType,
          tagFilters: tagFilters,
        );
      } else {
        mangas = await db.getMangas(
          search: searchQuery.isEmpty ? null : searchQuery,
          letter: letterFilter,
          libraryId: libraryFilter,
          contentType: contentType,
        );
      }
      mangaCount = mangas.length;
    } catch (e) {
      print('loadMangas error: $e');
      error = 'Erreur chargement: $e';
    }
    isLoading = false;
    notifyListeners();
  }

  Future<bool> syncDb() async {
    isSyncing = true;
    error = null;
    notifyListeners();

    try {
      final ok = await db.syncDatabase();
      if (ok) {
        await loadMangas();
        availableTags = await db.getAllTags();
        libraries = await db.getLibraries();
        try { await progress.fullSync(); } catch (_) {}
        await loadLists();
        try { ratings = await db.getRatings(); } catch (_) {}
        try { notes = await db.getNotes(); } catch (_) {}
      } else {
        error = db.lastError.isNotEmpty ? db.lastError : 'Échec de synchronisation';
      }
      isSyncing = false;
      notifyListeners();
      return ok;
    } catch (e) {
      error = 'Erreur: $e';
      isSyncing = false;
      notifyListeners();
      return false;
    }
  }

  void setSearch(String q) {
    searchQuery = q;
    loadMangas();
  }

  void setLetterFilter(String? l) {
    letterFilter = l;
    loadMangas();
  }

  void setLibrary(int? id) {
    libraryFilter = id;
    loadMangas();
  }

  void setContentType(String? type) {
    contentType = type;
    loadMangas();
  }

  void toggleTag(String category, String tag) {
    tagFilters[category] ??= [];
    if (tagFilters[category]!.contains(tag)) {
      tagFilters[category]!.remove(tag);
    } else {
      tagFilters[category]!.add(tag);
    }
    loadMangas();
  }

  void clearTagFilters() {
    tagFilters.clear();
    loadMangas();
  }


  Future<void> loadLists() async {
    if (!db.isLoggedIn) {
      toReadItems = [];
      readItems = [];
      notifyListeners();
      return;
    }
    final data = await db.getUserLists();
    toReadItems = data['to_read'] ?? [];
    readItems = data['read'] ?? [];
    notifyListeners();
  }

  bool isInList(String listName, String mangaUrl, String volumeId, String itemType) {
    final source = listName == 'read' ? readItems : toReadItems;
    return source.any((e) => e.mangaUrl == mangaUrl && e.volumeId == volumeId && e.itemType == itemType);
  }

  bool isMangaInToRead(String mangaUrl) => isInList('to_read', mangaUrl, '', 'manga');

  Future<bool> addListItem({
    required String listName,
    required String mangaUrl,
    String volumeId = '',
    String itemType = '',
    String title = '',
    bool autoAdded = false,
  }) async {
    final ok = await db.addUserListItem(
      listName: listName,
      mangaUrl: mangaUrl,
      volumeId: volumeId,
      itemType: itemType,
      title: title,
      autoAdded: autoAdded,
    );
    if (ok) {
      await loadLists();
    }
    return ok;
  }

  Future<bool> removeListItem({
    required String listName,
    required String mangaUrl,
    String volumeId = '',
    String itemType = '',
  }) async {
    final ok = await db.deleteUserListItem(
      listName: listName,
      mangaUrl: mangaUrl,
      volumeId: volumeId,
      itemType: itemType,
    );
    if (ok) {
      await loadLists();
    }
    return ok;
  }

  Future<bool> toggleListItem({
    required String listName,
    required String mangaUrl,
    String volumeId = '',
    String itemType = '',
    String title = '',
    bool autoAdded = false,
  }) async {
    if (isInList(listName, mangaUrl, volumeId, itemType)) {
      return removeListItem(
        listName: listName,
        mangaUrl: mangaUrl,
        volumeId: volumeId,
        itemType: itemType,
      );
    }
    return addListItem(
      listName: listName,
      mangaUrl: mangaUrl,
      volumeId: volumeId,
      itemType: itemType,
      title: title,
      autoAdded: autoAdded,
    );
  }

  int get activeFilterCount => tagFilters.values.fold(0, (sum, v) => sum + v.length);

  Future<void> setShowKavitaShortcut(bool v) async {
    showKavitaShortcut = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_kavita_shortcut', v);
  }

  Future<void> setShowKomgaShortcut(bool v) async {
    showKomgaShortcut = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_komga_shortcut', v);
  }

  Future<void> checkForUpdate() async {
    final info = await _updateService.checkForUpdate();
    if (info != null) {
      updateInfo = info;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    downloads.removeListener(notifyListeners);
    progress.removeListener(notifyListeners);
    kavitaDownloads.removeListener(notifyListeners);
    komgaDownloads.removeListener(notifyListeners);
    super.dispose();
  }
}
