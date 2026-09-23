import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/manga.dart';
import '../theme.dart';
import 'manga_detail_screen.dart';

class UserListScreen extends StatefulWidget {
  final String listName;
  final String title;
  final IconData icon;

  const UserListScreen({
    super.key,
    required this.listName,
    required this.title,
    required this.icon,
  });

  @override
  State<UserListScreen> createState() => _UserListScreenState();
}

class _UserListScreenState extends State<UserListScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await context.read<AppState>().loadLists();
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final items = widget.listName == 'read' ? state.readItems : state.toReadItems;
        return Scaffold(
          backgroundColor: AppTheme.d,
          body: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: AppTheme.bg,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.ac.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(widget.icon, color: AppTheme.ac, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(widget.title,
                        style: TextStyle(color: AppTheme.t1, fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                    ),
                    Text('${items.length}', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
                    IconButton(
                      onPressed: () async => state.loadLists(),
                      icon: Icon(Icons.refresh, color: AppTheme.t2),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: state.loadLists,
                        child: items.isEmpty
                            ? ListView(
                                children: [
                                  SizedBox(height: MediaQuery.of(context).size.height * 0.18),
                                  Icon(widget.icon, color: AppTheme.t3, size: 46),
                                  const SizedBox(height: 12),
                                  Center(child: Text('Aucun element', style: TextStyle(color: AppTheme.t3))),
                                  const SizedBox(height: 6),
                                  Center(
                                    child: Text(
                                      widget.listName == 'read'
                                          ? 'Les lectures finies a 100% apparaissent aussi ici.'
                                          : 'Ajoutez vos mangas, tomes, chapitres ou one-shots a lire.',
                                      style: TextStyle(color: AppTheme.t3, fontSize: 11),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ],
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.all(10),
                                itemCount: items.length,
                                itemBuilder: (context, index) => _UserListTile(item: items[index]),
                              ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UserListTile extends StatelessWidget {
  final UserListItem item;
  const _UserListTile({required this.item});

  String _subtitle() {
    if (item.itemType == 'manga' || item.volumeId.isEmpty) return 'Manga complet';
    final raw = item.volumeId.split('/').last;
    final filename = raw.replaceAll('.cbz', '').replaceAll('.zip', '');
    switch (item.itemType) {
      case 'chapter':
        return 'Chapitre • $filename';
      case 'oneshot':
        return 'One-shot • $filename';
      default:
        return 'Tome • $filename';
    }
  }

  Future<void> _open(BuildContext context) async {
    final state = context.read<AppState>();
    final manga = await state.db.getGroupedMangaByFolder(item.mangaUrl);
    if (context.mounted && manga != null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => MangaDetailScreen(mangaId: manga.id)));
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Manga introuvable localement'), backgroundColor: AppTheme.ros),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final title = item.title.trim().isNotEmpty ? item.title.trim() : item.mangaUrl;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.c1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.brd, width: 0.5),
      ),
      child: ListTile(
        onTap: () => _open(context),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: item.listName == 'read' ? AppTheme.grn.withValues(alpha: 0.14) : AppTheme.ac.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(item.listName == 'read' ? Icons.check_circle : Icons.bookmark, color: item.listName == 'read' ? AppTheme.grn : AppTheme.ac),
        ),
        title: Text(title, style: TextStyle(color: AppTheme.t1, fontSize: 13, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(_subtitle(), style: TextStyle(color: AppTheme.t2, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _chip(item.itemType == 'manga' ? 'manga' : item.itemType),
                if (item.autoAdded) _chip('auto'),
              ],
            ),
          ],
        ),
        trailing: IconButton(
          onPressed: () async {
            final ok = await state.removeListItem(
              listName: item.listName,
              mangaUrl: item.mangaUrl,
              volumeId: item.volumeId,
              itemType: item.itemType,
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(ok ? 'Retire de la liste' : (state.db.lastError.isNotEmpty ? state.db.lastError : 'Erreur')),
                  backgroundColor: ok ? AppTheme.grn : AppTheme.ros,
                ),
              );
            }
          },
          icon: Icon(Icons.delete_outline, color: AppTheme.ros),
        ),
      ),
    );
  }

  Widget _chip(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: AppTheme.inp,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: AppTheme.brd, width: 0.5),
    ),
    child: Text(label, style: TextStyle(color: AppTheme.t3, fontSize: 10, fontWeight: FontWeight.w600)),
  );
}
