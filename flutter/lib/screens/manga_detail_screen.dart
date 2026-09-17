import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../models/manga.dart';
import '../theme.dart';
import 'reader_screen.dart';

class MangaDetailScreen extends StatefulWidget {
  final int mangaId;
  const MangaDetailScreen({super.key, required this.mangaId});

  @override
  State<MangaDetailScreen> createState() => _MangaDetailScreenState();
}

class _MangaDetailScreenState extends State<MangaDetailScreen> {
  Manga? _manga;
  List<Volume> _volumes = [];
  Uint8List? _cover;
  bool _loading = true;
  bool _showInfo = false;
  final Map<int, bool> _downloaded = {};
  String? _volFilter;
  String? _activeEditionFolder;

  List<Manga> get _variants => _manga?.allVariants ?? const [];
  List<Volume> get _editionVolumes => _activeEditionFolder == null
      ? _volumes
      : _volumes.where((v) => (v.editionFolder.isNotEmpty ? v.editionFolder : v.cbzFolder) == _activeEditionFolder).toList();
  bool get _hasTomes => _editionVolumes.any((v) => v.volumeType == 'tome');
  bool get _hasChapters => _editionVolumes.any((v) => v.volumeType == 'chapter');
  bool get _hasOneshots => _editionVolumes.any((v) => v.volumeType == 'oneshot');
  int get _typeCount => [_hasTomes, _hasChapters, _hasOneshots].where((b) => b).length;
  List<Volume> get _filteredVolumes => _volFilter == null
      ? _editionVolumes
      : _editionVolumes.where((v) => v.volumeType == _volFilter).toList();

  @override
  void initState() {
    super.initState();
    _load();
    Future.microtask(() => context.read<AppState>().loadLists());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final manga = await state.db.getGroupedManga(widget.mangaId);
    final cover = await state.db.getMangaCover(widget.mangaId);
    List<Volume> volumes = [];
    if (manga != null) {
      volumes = await state.db.getGroupedVolumes(manga);
      for (final v in volumes) {
        _downloaded[v.id] = await state.downloads.isDownloaded(v);
      }
    }
    if (!mounted) return;
    setState(() {
      _manga = manga;
      _cover = cover;
      _volumes = volumes;
      _activeEditionFolder = manga?.allVariants.first.cbzFolder;
      _loading = false;
    });
  }

  Future<void> _downloadVolume(Volume vol) async {
    final state = context.read<AppState>();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Telechargement: ${vol.displayName}'), backgroundColor: AppTheme.c2),
    );
    final ok = await state.downloads.downloadVolume(vol);
    if (!mounted) return;
    setState(() => _downloaded[vol.id] = ok);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '${vol.displayName} OK' : 'Erreur'),
        backgroundColor: ok ? AppTheme.grn : AppTheme.ros,
      ),
    );
  }

  Future<void> _readVolume(Volume vol, {bool forceOnline = false}) async {
    final state = context.read<AppState>();
    final localPath = await state.downloads.getLocalPath(vol);
    final isLocal = localPath != null && !forceOnline;
    if (!mounted) return;

    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          title: '${_manga?.displayTitle ?? ''} - ${vol.displayName}',
          volume: vol,
          localPath: isLocal ? localPath : null,
          online: !isLocal,
        ),
      ),
    );

    if (deleted == true && localPath != null) {
      await state.downloads.deleteFile(vol.filename);
      await state.downloads.clearPagesCache(localPath);
      if (!mounted) return;
      setState(() => _downloaded[vol.id] = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${vol.displayName} supprime'), backgroundColor: AppTheme.t3),
      );
    }
  }

  Widget _volTypeChip(String? type, String label) {
    final isActive = _volFilter == type;
    return GestureDetector(
      onTap: () => setState(() => _volFilter = type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: isActive ? MangaColors.accent : AppTheme.c2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isActive ? MangaColors.accent : AppTheme.brd),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.white : AppTheme.t2,
            fontSize: 11,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: AppTheme.d,
        appBar: AppBar(backgroundColor: AppTheme.bg),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_manga == null) {
      return Scaffold(
        backgroundColor: AppTheme.d,
        appBar: AppBar(backgroundColor: AppTheme.bg),
        body: Center(child: Text('Manga introuvable', style: TextStyle(color: AppTheme.t3))),
      );
    }

    final info = _manga!.infoEntries;

    return Scaffold(
      backgroundColor: AppTheme.d,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            backgroundColor: AppTheme.bg,
            expandedHeight: 300,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (_cover != null) Image.memory(_cover!, fit: BoxFit.cover),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, AppTheme.d.withValues(alpha: 0.95)],
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 16,
                    left: 16,
                    right: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_manga!.displayTitle,
                            style: TextStyle(color: AppTheme.t1, fontSize: 22, fontWeight: FontWeight.w700)),
                        if (_manga!.matchStatus == 'matched')
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                Icon(Icons.check_circle, color: AppTheme.grn, size: 14),
                                SizedBox(width: 4),
                                Text('Associe', style: TextStyle(color: AppTheme.grn, fontSize: 12)),
                              ],
                            ),
                          ),
                        if (_variants.length > 1)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: _variants.map((variant) {
                                final active = _activeEditionFolder == variant.cbzFolder;
                                return GestureDetector(
                                  onTap: () => setState(() => _activeEditionFolder = variant.cbzFolder),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: active ? AppTheme.ac.withValues(alpha: 0.18) : AppTheme.c1,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(color: active ? AppTheme.ac : AppTheme.brd),
                                    ),
                                    child: Text(
                                      variant.editionLabel.isNotEmpty ? variant.editionLabel : 'Édition standard',
                                      style: TextStyle(color: active ? AppTheme.ac : AppTheme.t2, fontSize: 11, fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_manga!.synopsis.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  _manga!.synopsis,
                  style: TextStyle(color: AppTheme.t2, fontSize: 13, height: 1.5),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          if (_manga!.metadata.containsKey('Genres') || _manga!.metadata.containsKey('Type'))
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (_manga!.metadata['Type'] != null)
                      _genreBadge(_manga!.metadata['Type'].toString(), filled: true),
                    ...(_manga!.metadata['Genres']?.toString() ?? '')
                        .split(' - ')
                        .where((g) => g.trim().isNotEmpty)
                        .map((g) => _genreBadge(g.trim())),
                  ],
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Consumer<AppState>(
                builder: (context, state, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _listActionChip(
                          icon: Icons.bookmark_add,
                          label: 'A lire (manga)',
                          color: AppTheme.ac,
                          active: state.isMangaInToRead(_manga!.cbzFolder),
                          onTap: _toggleMangaToRead,
                        ),
                      ],
                    ),
                    // ── Rating stars ──
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Text('Note : ', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
                        ...List.generate(5, (i) {
                          final star = i + 1;
                          final current = state.ratings[_manga!.id] ?? 0;
                          return GestureDetector(
                            onTap: () async {
                              if (current == star) {
                                await state.db.deleteRating(_manga!.id);
                                state.ratings.remove(_manga!.id);
                              } else {
                                await state.db.setRating(_manga!.id, star);
                                state.ratings[_manga!.id] = star;
                              }
                              state.notifyAllListeners();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: Icon(
                                star <= current ? Icons.star_rounded : Icons.star_outline_rounded,
                                color: star <= current ? Colors.amber : AppTheme.t3,
                                size: 28,
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                    // ── Note text ──
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () => _showNoteDialog(state),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.inp,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.brd, width: 0.5),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.edit_note, color: AppTheme.t3, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                (state.notes[_manga!.id]?.isNotEmpty == true) ? state.notes[_manga!.id]! : 'Ajouter une note perso...',
                                style: TextStyle(
                                  color: (state.notes[_manga!.id]?.isNotEmpty == true) ? AppTheme.t2 : AppTheme.t3,
                                  fontSize: 12, fontStyle: FontStyle.italic,
                                ),
                                maxLines: 2, overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (info.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GestureDetector(
                  onTap: () => setState(() => _showInfo = !_showInfo),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.brd))),
                    child: Row(
                      children: [
                        Text('Plus d\'infos', style: TextStyle(color: AppTheme.ac, fontSize: 13, fontWeight: FontWeight.w600)),
                        Spacer(),
                        Icon(_showInfo ? Icons.expand_less : Icons.expand_more, color: AppTheme.t3, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_showInfo)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  children: info.map((e) => _infoRow(e.key, e.value)).toList(),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text('${_volFilter == null ? "Tout" : _volFilter == "tome" ? "Tomes" : _volFilter == "chapter" ? "Chapitres" : "One-shots"} (${_filteredVolumes.length})',
                          style: TextStyle(color: AppTheme.t1, fontSize: 16, fontWeight: FontWeight.w600)),
                      Spacer(),
                      TextButton.icon(
                        onPressed: () => _downloadAll(),
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('Tout', style: TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(foregroundColor: AppTheme.ac),
                      ),
                    ],
                  ),
                  if (_typeCount >= 2)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _volTypeChip(null, 'Tout'),
                        if (_hasOneshots) _volTypeChip('oneshot', 'One-Shot'),
                        if (_hasTomes) _volTypeChip('tome', 'Tomes'),
                        if (_hasChapters) _volTypeChip('chapter', 'Chapitres'),
                      ],
                    ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _buildVolumeItem(_filteredVolumes[i]),
              childCount: _filteredVolumes.length,
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
        ],
      ),
    );
  }

  Widget _genreBadge(String genre, {bool filled = false}) {
    final color = MangaColors.tagColor(genre);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
        border: filled ? null : Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Text(
        genre,
        style: TextStyle(color: filled ? Colors.white : color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildVolumeItem(Volume vol) {
    final isDl = _downloaded[vol.id] ?? false;
    final dlInfo = context.read<AppState>().downloads.activeDownloads[vol.filepath];
    final isDownloading = dlInfo != null && !dlInfo.isDone && !dlInfo.hasError;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.c1,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDl ? AppTheme.grn.withValues(alpha: 0.3) : AppTheme.brd, width: 0.5),
      ),
      child: Consumer<AppState>(
        builder: (context, state, _) {
          final itemType = vol.volumeType ?? 'tome';
          final inToRead = state.isInList('to_read', vol.cbzFolder, vol.filepath, itemType);
          final inRead = state.isInList('read', vol.cbzFolder, vol.filepath, itemType);
          return Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _readVolume(vol, forceOnline: !isDl),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 56,
                          decoration: BoxDecoration(color: AppTheme.c2, borderRadius: BorderRadius.circular(4)),
                          child: Center(
                            child: Text(vol.volumeNum?.toString() ?? '?', style: TextStyle(color: AppTheme.t2, fontSize: 16, fontWeight: FontWeight.w700)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(vol.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.t1, fontSize: 14, fontWeight: FontWeight.w500)),
                              const SizedBox(height: 2),
                              if (vol.editionLabel.isNotEmpty)
                                Text(vol.editionLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.t3, fontSize: 10)),
                              Text(
                                '${vol.totalPages} pages${vol.fileSize > 0 ? " - ${_formatSize(vol.fileSize)}" : ""}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: AppTheme.t3, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      splashRadius: 22,
                      icon: Icon(Icons.bookmark_add, color: inToRead ? AppTheme.ac : AppTheme.t3, size: 19),
                      tooltip: inToRead ? 'Retirer de A lire' : 'Ajouter a A lire',
                      onPressed: () => _toggleVolumeList(vol, 'to_read'),
                    ),
                    IconButton(
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      splashRadius: 22,
                      icon: Icon(Icons.check_circle, color: inRead ? AppTheme.grn : AppTheme.t3, size: 19),
                      tooltip: inRead ? 'Retirer de Lu' : 'Ajouter a Lu',
                      onPressed: () => _toggleVolumeList(vol, 'read'),
                    ),
                    IconButton(
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      splashRadius: 22,
                      icon: Icon(Icons.play_arrow, color: isDl ? AppTheme.grn : AppTheme.cyn),
                      tooltip: isDl ? 'Lire (local)' : 'Lire en ligne',
                      onPressed: () => _readVolume(vol, forceOnline: !isDl),
                    ),
                    if (!isDl && !isDownloading)
                      IconButton(
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        splashRadius: 24,
                        padding: const EdgeInsets.all(12),
                        icon: Icon(Icons.download, color: AppTheme.ac, size: 22),
                        tooltip: 'Telecharger',
                        onPressed: () => _downloadVolume(vol),
                      ),
                    if (isDownloading)
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: CircularProgressIndicator(value: dlInfo!.progress, strokeWidth: 2, color: AppTheme.ac),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _toggleMangaToRead() async {
    if (_manga == null) return;
    final state = context.read<AppState>();
    final wasInList = state.isMangaInToRead(_manga!.cbzFolder);
    final ok = await state.toggleListItem(
      listName: 'to_read',
      mangaUrl: _manga!.cbzFolder,
      volumeId: '',
      itemType: 'manga',
      title: _manga!.displayTitle,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? (wasInList ? 'Retire de A lire' : 'Ajoute a A lire') : (state.db.lastError.isNotEmpty ? state.db.lastError : 'Erreur')),
        backgroundColor: ok ? AppTheme.grn : AppTheme.ros,
      ),
    );
  }

  Future<void> _toggleVolumeList(Volume vol, String listName) async {
    final state = context.read<AppState>();
    final itemType = vol.volumeType ?? 'tome';
    final wasInList = state.isInList(listName, vol.cbzFolder, vol.filepath, itemType);
    final ok = await state.toggleListItem(
      listName: listName,
      mangaUrl: vol.cbzFolder,
      volumeId: vol.filepath,
      itemType: itemType,
      title: '${_manga?.displayTitle ?? vol.cbzFolder}${vol.editionLabel.isNotEmpty ? ' — ${vol.editionLabel}' : ''} - ${vol.displayName}',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? (wasInList ? 'Retire de ${listName == 'read' ? 'Lu' : 'A lire'}' : 'Ajoute a ${listName == 'read' ? 'Lu' : 'A lire'}') : (state.db.lastError.isNotEmpty ? state.db.lastError : 'Erreur')),
        backgroundColor: ok ? AppTheme.grn : AppTheme.ros,
      ),
    );
  }

  Widget _listActionChip({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.18) : AppTheme.c1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? color : AppTheme.brd),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: active ? color : AppTheme.t2),
            SizedBox(width: 6),
            Text(label, style: TextStyle(color: active ? color : AppTheme.t2, fontSize: 11, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String title, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 110, child: Text(title, style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600))),
            Expanded(child: Text(value, style: TextStyle(color: AppTheme.t1, fontSize: 12))),
          ],
        ),
      );

  Future<void> _showNoteDialog(AppState state) async {
    final ctrl = TextEditingController(text: state.notes[_manga!.id] ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg,
        title: Text('Note personnelle', style: TextStyle(color: AppTheme.t1, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          maxLines: 5,
          decoration: InputDecoration(hintText: 'Votre note sur ce manga...'),
          style: TextStyle(color: AppTheme.t1, fontSize: 13),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Annuler', style: TextStyle(color: AppTheme.t3)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (result != null) {
      await state.db.saveNote(_manga!.id, result);
      state.notes[_manga!.id] = result;
      state.notifyAllListeners();
    }
    ctrl.dispose();
  }

  Future<void> _downloadAll() async {
    for (final vol in _filteredVolumes) {
      if (!(_downloaded[vol.id] ?? false)) {
        await _downloadVolume(vol);
      }
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} Ko';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} Mo';
  }
}
