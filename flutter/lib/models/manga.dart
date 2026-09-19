import 'dart:convert';

class Manga {
  final int id;
  final String cbzFolder;
  final String title;
  final String coverUrl;
  final String synopsis;
  final String matchStatus;
  final String nautiljonUrl;
  final Map<String, dynamic> metadata;
  final Map<String, dynamic> editions;
  final bool hasCover;
  final String baseTitle;
  final String editionLabel;
  final List<Manga> variants;

  Manga({
    required this.id,
    required this.cbzFolder,
    required this.title,
    this.coverUrl = '',
    this.synopsis = '',
    this.matchStatus = 'unmatched',
    this.nautiljonUrl = '',
    this.metadata = const {},
    this.editions = const {},
    this.hasCover = false,
    this.baseTitle = '',
    this.editionLabel = '',
    this.variants = const [],
  });

  factory Manga.fromMap(Map<String, dynamic> m) {
    Map<String, dynamic> meta = {};
    Map<String, dynamic> eds = {};
    try {
      if (m['metadata_json'] != null && m['metadata_json'] is String) {
        final decoded = jsonDecode(m['metadata_json'] as String);
        if (decoded is Map) meta = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    try {
      if (m['editions_json'] != null && m['editions_json'] is String) {
        final decoded = jsonDecode(m['editions_json'] as String);
        if (decoded is Map) eds = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    final title = m['title'] as String? ?? '';
    return Manga(
      id: m['id'] as int,
      cbzFolder: m['cbz_folder'] as String? ?? '',
      title: title,
      coverUrl: m['cover_url'] as String? ?? '',
      synopsis: m['synopsis'] as String? ?? '',
      matchStatus: m['match_status'] as String? ?? 'unmatched',
      nautiljonUrl: m['nautiljon_url'] as String? ?? '',
      metadata: meta,
      editions: eds,
      hasCover: (m['has_cover'] as int? ?? 0) == 1 || m['cover_blob'] != null,
      baseTitle: title,
    );
  }

  String get displayTitle => baseTitle.isNotEmpty ? baseTitle : title;
  List<Manga> get allVariants => variants.isNotEmpty ? variants : [this];

  String get letter {
    if (title.isEmpty) return '#';
    final c = title[0].toUpperCase();
    return RegExp(r'[A-Z]').hasMatch(c) ? c : '#';
  }

  List<MapEntry<String, String>> get infoEntries {
    final entries = <MapEntry<String, String>>[];
    final keys = [
      'Type', 'Statut', 'Auteur', 'Dessinateur', 'Editeur',
      'Genres', 'Themes', 'Volumes', 'Pays', 'Annee',
      'Prepublication', 'Format', 'ReadingMode',
    ];
    for (final k in keys) {
      final v = metadata[k];
      if (v != null && v.toString().isNotEmpty) {
        entries.add(MapEntry(k, v.toString()));
      }
    }
    for (final k in metadata.keys) {
      if (!keys.contains(k) && metadata[k] != null && metadata[k].toString().isNotEmpty) {
        entries.add(MapEntry(k, metadata[k].toString()));
      }
    }
    return entries;
  }
}

class Volume {
  final int id;
  final String cbzFolder;
  final int libraryId;
  final String filename;
  final String filepath;
  final int? volumeNum;
  final String? volumeType;
  final String? volumeDisplay;
  final String source;
  final int fileSize;
  final int totalPages;
  final List<int> chapters;
  final String editionFolder;
  final String editionLabel;
  bool isDownloaded;
  String? localPath;

  Volume({
    required this.id,
    required this.cbzFolder,
    required this.libraryId,
    required this.filename,
    required this.filepath,
    this.volumeNum,
    this.volumeType,
    this.volumeDisplay,
    this.source = 'archive',
    this.fileSize = 0,
    this.totalPages = 0,
    this.chapters = const [],
    this.editionFolder = '',
    this.editionLabel = '',
    this.isDownloaded = false,
    this.localPath,
  });

  factory Volume.fromMap(Map<String, dynamic> m) {
    List<int> ch = [];
    if (m['chapters_json'] != null && m['chapters_json'] is String) {
      try {
        final list = m['chapters_json'] as String;
        if (list.isNotEmpty && list != '[]') {
          ch = list.replaceAll('[', '').replaceAll(']', '').split(',')
              .where((s) => s.trim().isNotEmpty)
              .map((s) => int.parse(s.trim()))
              .toList();
        }
      } catch (_) {}
    }
    return Volume(
      id: m['id'] as int,
      cbzFolder: m['cbz_folder'] as String? ?? '',
      libraryId: m['library_id'] as int? ?? 0,
      filename: m['filename'] as String? ?? '',
      filepath: m['filepath'] as String? ?? '',
      volumeNum: m['volume_num'] as int?,
      volumeType: m['volume_type'] as String?,
      volumeDisplay: m['volume_display'] as String?,
      source: m['source'] as String? ?? 'archive',
      fileSize: m['file_size'] as int? ?? 0,
      totalPages: m['total_pages'] as int? ?? 0,
      chapters: ch,
      editionFolder: m['edition_folder'] as String? ?? '',
      editionLabel: m['edition_label'] as String? ?? '',
    );
  }

  Volume copyWith({
    String? cbzFolder,
    String? editionFolder,
    String? editionLabel,
  }) => Volume(
    id: id,
    cbzFolder: cbzFolder ?? this.cbzFolder,
    libraryId: libraryId,
    filename: filename,
    filepath: filepath,
    volumeNum: volumeNum,
    volumeType: volumeType,
    volumeDisplay: volumeDisplay,
    source: source,
    fileSize: fileSize,
    totalPages: totalPages,
    chapters: chapters,
    editionFolder: editionFolder ?? this.editionFolder,
    editionLabel: editionLabel ?? this.editionLabel,
    isDownloaded: isDownloaded,
    localPath: localPath,
  );

  String get displayName => volumeDisplay ?? (volumeNum != null ? 'Tome $volumeNum' : filename);
}

class ReadingProgress {
  final int userId;
  final String mangaUrl;
  final String volumeId;
  final int currentPage;
  final int totalPages;
  final double lastRead;

  ReadingProgress({
    required this.userId,
    required this.mangaUrl,
    required this.volumeId,
    required this.currentPage,
    required this.totalPages,
    required this.lastRead,
  });

  factory ReadingProgress.fromMap(Map<String, dynamic> m) => ReadingProgress(
    userId: m['user_id'] as int? ?? 0,
    mangaUrl: m['manga_url'] as String? ?? '',
    volumeId: m['volume_id'] as String? ?? '',
    currentPage: m['current_page'] as int? ?? 0,
    totalPages: m['total_pages'] as int? ?? 0,
    lastRead: (m['last_read'] as num?)?.toDouble() ?? 0,
  );
}


class UserListItem {
  final String listName;
  final String mangaUrl;
  final String volumeId;
  final String itemType;
  final String title;
  final bool autoAdded;
  final double createdAt;

  const UserListItem({
    required this.listName,
    required this.mangaUrl,
    required this.volumeId,
    required this.itemType,
    required this.title,
    required this.autoAdded,
    required this.createdAt,
  });

  factory UserListItem.fromMap(Map<String, dynamic> m) => UserListItem(
    listName: m['list_name'] as String? ?? '',
    mangaUrl: m['manga_url'] as String? ?? '',
    volumeId: m['volume_id'] as String? ?? '',
    itemType: m['item_type'] as String? ?? 'tome',
    title: m['title'] as String? ?? '',
    autoAdded: (m['auto_added'] as int? ?? (m['auto_added'] == true ? 1 : 0)) == 1 || m['auto_added'] == true,
    createdAt: (m['created_at'] as num?)?.toDouble() ?? 0,
  );

  String get key => '$listName::$mangaUrl::$volumeId::$itemType';
  bool get isMangaLevel => itemType == 'manga' || volumeId.isEmpty;
}
