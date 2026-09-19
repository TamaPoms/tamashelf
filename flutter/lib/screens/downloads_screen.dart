import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../theme.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  List<Map<String, dynamic>> _files = [];
  bool _loading = true;
  int _totalSize = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final files = await state.downloads.getDownloadedFiles();
    final size = await state.downloads.getTotalDownloadedSize();
    if (mounted) setState(() { _files = files; _totalSize = size; _loading = false; });
  }

  Future<void> _delete(String filename) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg,
        title: Text('Supprimer ?', style: TextStyle(color: AppTheme.t1)),
        content: Text('Supprimer $filename ?', style: TextStyle(color: AppTheme.t2)),
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
      final state = context.read<AppState>();
      await state.downloads.deleteFile(filename);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          color: AppTheme.bg,
          child: Row(
            children: [
              Icon(Icons.download_done, color: AppTheme.ac, size: 22),
              SizedBox(width: 10),
              Text('Téléchargés', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.t1)),
              Spacer(),
              Text(_formatSize(_totalSize), style: TextStyle(color: AppTheme.t3, fontSize: 12)),
            ],
          ),
        ),

        // Active downloads
        Consumer<AppState>(
          builder: (ctx, state, _) {
            final active = state.downloads.activeDownloads.values
              .where((d) => !d.isDone && !d.hasError)
              .toList();
            if (active.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text('En cours', style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
                ...active.map((d) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.c1,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.ac.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(d.filename, style: TextStyle(color: AppTheme.t1, fontSize: 13), overflow: TextOverflow.ellipsis),
                          SizedBox(height: 6),
                          LinearProgressIndicator(value: d.progress, backgroundColor: AppTheme.brd, color: AppTheme.ac),
                        ],
                      )),
                      SizedBox(width: 8),
                      Text('${(d.progress * 100).toStringAsFixed(0)}%', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
                    ],
                  ),
                )),
              ],
            );
          },
        ),

        // Downloaded files
        Expanded(
          child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _files.isEmpty
              ? Center(child: Text('Aucun fichier téléchargé', style: TextStyle(color: AppTheme.t3)))
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppTheme.ac,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _files.length,
                    itemBuilder: (ctx, i) {
                      final f = _files[i];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.c1,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.brd, width: 0.5),
                        ),
                        child: ListTile(
                          leading: Icon(Icons.book, color: AppTheme.ac, size: 28),
                          title: Text(
                            f['name'] as String,
                            style: TextStyle(color: AppTheme.t1, fontSize: 13, fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _formatSize(f['size'] as int),
                            style: TextStyle(color: AppTheme.t3, fontSize: 11),
                          ),
                          trailing: IconButton(
                            icon: Icon(Icons.delete_outline, color: AppTheme.ros, size: 20),
                            onPressed: () => _delete(f['name'] as String),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} Ko';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} Mo';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} Go';
  }
}
