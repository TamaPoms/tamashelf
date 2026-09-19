import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../services/progress_service.dart';
import '../models/manga.dart';
import '../theme.dart';
import 'reader_screen.dart';
import 'manga_detail_screen.dart';

class ReadingScreen extends StatefulWidget {
  const ReadingScreen({super.key});

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> {
  bool _syncing = false;

  Future<void> _sync() async {
    setState(() => _syncing = true);
    final state = context.read<AppState>();
    await state.progress.fullSync();
    if (mounted) {
      setState(() => _syncing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Progression synchronisee'), backgroundColor: AppTheme.grn),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (ctx, state, _) {
        final reading = state.progress.inProgress;
        final pendingCount = state.progress.entries.where((e) => e.needsSync).length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              color: AppTheme.bg,
              child: Row(
                children: [
                  Icon(Icons.auto_stories, color: AppTheme.ac, size: 22),
                  SizedBox(width: 10),
                  Text('Lectures en cours', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.t1)),
                  Spacer(),
                  if (pendingCount > 0)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.amb,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('$pendingCount a sync', style: TextStyle(color: AppTheme.d, fontSize: 10, fontWeight: FontWeight.w600)),
                    ),
                  IconButton(
                    icon: _syncing
                      ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.ac))
                      : Icon(Icons.sync, color: AppTheme.t2, size: 22),
                    onPressed: _syncing ? null : _sync,
                  ),
                ],
              ),
            ),

            // List
            Expanded(
              child: reading.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.menu_book, color: AppTheme.t3, size: 48),
                        SizedBox(height: 12),
                        Text('Aucune lecture en cours', style: TextStyle(color: AppTheme.t3, fontSize: 14)),
                        SizedBox(height: 4),
                        Text('Commencez a lire un manga !', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: reading.length,
                    itemBuilder: (ctx, i) => _buildProgressItem(state, reading[i]),
                  ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProgressItem(AppState state, ProgressEntry entry) {
    final percent = (entry.percent * 100).toStringAsFixed(0);
    final timeAgo = _timeAgo(entry.lastRead);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.c1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.brd, width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _resumeReading(state, entry),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CbzPreview(entry: entry),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            entry.title.isNotEmpty ? entry.title : entry.mangaUrl,
                            style: TextStyle(color: AppTheme.t1, fontSize: 14, fontWeight: FontWeight.w600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (entry.needsSync)
                          Padding(
                            padding: EdgeInsets.only(left: 6, top: 2),
                            child: Icon(Icons.cloud_off, color: AppTheme.amb, size: 14),
                          ),
                        IconButton(
                          icon: Icon(Icons.delete_outline, color: AppTheme.t3, size: 18),
                          onPressed: () => _deleteProgress(state, entry),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (entry.volumeId.isNotEmpty)
                      Text(
                        _volumeLabel(entry.volumeId),
                        style: TextStyle(color: AppTheme.t3, fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: entry.percent,
                              backgroundColor: AppTheme.inp,
                              color: entry.percent > 0.8 ? AppTheme.grn : AppTheme.ac,
                              minHeight: 6,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '$percent%',
                          style: TextStyle(
                            color: entry.percent > 0.8 ? AppTheme.grn : AppTheme.ac,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Page ${entry.currentPage + 1} / ${entry.totalPages}',
                            style: TextStyle(color: AppTheme.t3, fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          timeAgo,
                          style: TextStyle(color: AppTheme.t3, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _resumeReading(AppState state, ProgressEntry entry) async {
    // Find the volume from DB using volume_id which is the filepath
    final volumes = await state.db.getVolumes(entry.mangaUrl);
    Volume? vol;
    // Match by filepath (web uses filepath as volume_id)
    for (final v in volumes) {
      if (v.filepath == entry.volumeId) { vol = v; break; }
    }
    // Fallback: match by displayName
    if (vol == null) {
      for (final v in volumes) {
        if (v.displayName == entry.volumeId) { vol = v; break; }
      }
    }
    if (vol == null && volumes.isNotEmpty) {
      // Try to find by volume_id containing the filename
      for (final v in volumes) {
        if (entry.volumeId.contains(v.filename)) { vol = v; break; }
      }
    }
    if (vol == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Tome introuvable dans la BDD'), backgroundColor: AppTheme.ros),
        );
      }
      return;
    }

    // Check if downloaded locally
    final localPath = await state.downloads.getLocalPath(vol);
    final title = entry.title;

    if (!mounted) return;

    if (localPath != null) {
      // Read locally
      await Navigator.push(context, MaterialPageRoute(
        builder: (_) => ReaderScreen(
          title: title,
          volume: vol!,
          localPath: localPath,
          startPage: entry.currentPage,
        ),
      ));
    } else {
      // Propose: read online or download
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.bg,
          title: Text(vol!.displayName, style: TextStyle(color: AppTheme.t1, fontSize: 16)),
          content: Text('Ce tome n\'est pas telecharge.', style: TextStyle(color: AppTheme.t2)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: Text('Annuler', style: TextStyle(color: AppTheme.t3)),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(ctx, 'download'),
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Telecharger'),
              style: OutlinedButton.styleFrom(foregroundColor: AppTheme.ac),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, 'online'),
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Lire en ligne'),
            ),
          ],
        ),
      );

      if (!mounted || choice == null || choice == 'cancel') return;

      if (choice == 'download') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Telechargement: ${vol!.displayName}'), backgroundColor: AppTheme.c2),
        );
        final ok = await state.downloads.downloadVolume(vol!);
        if (ok && mounted) {
          final dlPath = await state.downloads.getLocalPath(vol!);
          if (dlPath != null && mounted) {
            await Navigator.push(context, MaterialPageRoute(
              builder: (_) => ReaderScreen(
                title: title,
                volume: vol!,
                localPath: dlPath,
                startPage: entry.currentPage,
              ),
            ));
          }
        }
      } else {
        // Online
        await Navigator.push(context, MaterialPageRoute(
          builder: (_) => ReaderScreen(
            title: title,
            volume: vol!,
            online: true,
            onlineTotalPages: entry.totalPages,
            startPage: entry.currentPage,
          ),
        ));
      }
    }
  }

  Future<void> _deleteProgress(AppState state, ProgressEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg,
        title: Text('Supprimer ?', style: TextStyle(color: AppTheme.t1)),
        content: Text('Supprimer la progression de "${entry.title}" ?', style: TextStyle(color: AppTheme.t2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Annuler', style: TextStyle(color: AppTheme.t3))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.ros),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await state.progress.deleteProgress(entry.mangaUrl, entry.volumeId);
    }
  }

  String _volumeLabel(String volumeId) {
    // volumeId is a filepath like "folder/Tome 13.cbz" or "imgvol:folder:13"
    if (volumeId.startsWith('imgvol:')) {
      final parts = volumeId.split(':');
      return parts.length >= 3 ? 'Tome ${parts.last}' : volumeId;
    }
    // Extract filename without extension
    final name = volumeId.split('/').last;
    if (name.endsWith('.cbz')) return name.substring(0, name.length - 4);
    return name;
  }

  String _timeAgo(double timestamp) {
    if (timestamp == 0) return '';
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final diff = now - timestamp;
    if (diff < 60) return 'A l\'instant';
    if (diff < 3600) return 'Il y a ${(diff / 60).floor()} min';
    if (diff < 86400) return 'Il y a ${(diff / 3600).floor()} h';
    if (diff < 604800) return 'Il y a ${(diff / 86400).floor()} j';
    return 'Il y a ${(diff / 604800).floor()} sem';
  }
}


class _CbzPreview extends StatelessWidget {
  final ProgressEntry entry;
  const _CbzPreview({required this.entry});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final canLoadRemote = state.db.serverUrl.isNotEmpty && state.db.isLoggedIn && entry.volumeId.isNotEmpty;
    final pages = [0, 1, 2];

    return SizedBox(
      width: 72,
      height: 96,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (int i = pages.length - 1; i >= 0; i--)
            Positioned(
              left: i * 6,
              top: i * 4,
              child: _PreviewPage(
                width: 60,
                height: 84,
                page: pages[i],
                enabled: canLoadRemote,
                url: canLoadRemote
                    ? '${state.db.serverUrl}/api/cbz/read/${Uri.encodeComponent(entry.volumeId)}?page=${pages[i]}'
                    : '',
                headers: state.db.authHeaders,
              ),
            ),
        ],
      ),
    );
  }
}

class _PreviewPage extends StatelessWidget {
  final double width;
  final double height;
  final int page;
  final bool enabled;
  final String url;
  final Map<String, String> headers;

  const _PreviewPage({
    required this.width,
    required this.height,
    required this.page,
    required this.enabled,
    required this.url,
    required this.headers,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppTheme.c2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.brd, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: enabled
          ? Image.network(
              url,
              headers: headers,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _fallback(),
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return _fallback(loading: true);
              },
            )
          : _fallback(),
    );
  }

  Widget _fallback({bool loading = false}) {
    return Container(
      color: AppTheme.c2,
      child: Center(
        child: loading
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 1.8, color: AppTheme.ac),
              )
            : Icon(page == 0 ? Icons.menu_book : Icons.description_outlined, color: AppTheme.t3, size: page == 0 ? 24 : 18),
      ),
    );
  }
}
