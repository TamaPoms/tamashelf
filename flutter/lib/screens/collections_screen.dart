import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../theme.dart';
import 'manga_detail_screen.dart';

class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({super.key});

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  List<Map<String, dynamic>> _collections = [];
  bool _loading = true;
  bool _showCreate = false;
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String _selColor = '#6366f1';
  String _selIcon = '📚';

  static const _icons = ['📚', '⭐', '❤️', '🔥', '🎯', '📖', '🏆', '💎', '🌸', '⚔️', '🎭', '🌙'];
  static const _colors = ['#6366f1', '#f43f5e', '#f59e0b', '#10b981', '#3b82f6', '#8b5cf6', '#ec4899', '#14b8a6'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final cols = await state.db.getCollections();
    if (mounted) setState(() { _collections = cols; _loading = false; });
  }

  Future<void> _create() async {
    if (_nameCtrl.text.trim().isEmpty) return;
    final state = context.read<AppState>();
    final id = await state.db.createCollection(
      name: _nameCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      color: _selColor,
      icon: _selIcon,
    );
    if (id != null) {
      _nameCtrl.clear();
      _descCtrl.clear();
      setState(() => _showCreate = false);
      _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('Collection creee'), backgroundColor: AppTheme.grn));
    }
  }

  Future<void> _delete(int id, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg,
        title: Text('Supprimer "$name" ?', style: TextStyle(color: AppTheme.t1, fontSize: 16)),
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
      await context.read<AppState>().db.deleteCollection(id);
      _load();
    }
  }

  Color _parseColor(String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xff')));
    } catch (_) { return AppTheme.ac; }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          color: AppTheme.bg,
          child: Row(
            children: [
              Icon(Icons.folder_special, color: AppTheme.ac, size: 22),
              const SizedBox(width: 10),
              Text('Collections', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.t1)),
              const Spacer(),
              IconButton(
                icon: Icon(_showCreate ? Icons.close : Icons.add_circle, color: AppTheme.ac, size: 24),
                onPressed: () => setState(() => _showCreate = !_showCreate),
              ),
            ],
          ),
        ),
        if (_showCreate) _buildCreateForm(),
        Expanded(
          child: _loading
              ? Center(child: CircularProgressIndicator(color: AppTheme.ac))
              : _collections.isEmpty
                  ? Center(child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_open, color: AppTheme.t3, size: 48),
                        const SizedBox(height: 12),
                        Text('Aucune collection', style: TextStyle(color: AppTheme.t3, fontSize: 14)),
                        const SizedBox(height: 4),
                        Text('Creez-en une avec le bouton +', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
                      ],
                    ))
                  : RefreshIndicator(
                      onRefresh: _load,
                      color: AppTheme.ac,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _collections.length,
                        itemBuilder: (ctx, i) => _buildCollectionCard(_collections[i]),
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildCreateForm() {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.c1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.brd, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: 'Nom', isDense: true),
            style: TextStyle(color: AppTheme.t1, fontSize: 14),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descCtrl,
            decoration: const InputDecoration(labelText: 'Description (optionnel)', isDense: true),
            style: TextStyle(color: AppTheme.t1, fontSize: 14),
          ),
          const SizedBox(height: 12),
          Text('Icone', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: _icons.map((ic) => GestureDetector(
              onTap: () => setState(() => _selIcon = ic),
              child: Text(ic, style: TextStyle(fontSize: 22, color: _selIcon == ic ? null : AppTheme.t3.withValues(alpha: 0.3))),
            )).toList(),
          ),
          const SizedBox(height: 10),
          Text('Couleur', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: _colors.map((c) {
              final color = _parseColor(c);
              return GestureDetector(
                onTap: () => setState(() => _selColor = c),
                child: Container(
                  width: 26, height: 26,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: _selColor == c ? Colors.white : Colors.transparent, width: 2),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(onPressed: _create, child: const Text('Creer')),
          ),
        ],
      ),
    );
  }

  Widget _buildCollectionCard(Map<String, dynamic> col) {
    final color = _parseColor(col['color']?.toString() ?? '#6366f1');
    final mangaIds = (col['manga_ids'] as List?)?.cast<int>() ?? [];
    final state = context.read<AppState>();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.c1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.brd, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(col['icon']?.toString() ?? '📚', style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      col['name']?.toString() ?? '',
                      style: TextStyle(color: AppTheme.t1, fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    if (col['description']?.toString().isNotEmpty == true)
                      Text(col['description'].toString(), style: TextStyle(color: AppTheme.t3, fontSize: 11)),
                  ],
                ),
              ),
              Text('${col['count'] ?? mangaIds.length}', style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(Icons.delete_outline, color: AppTheme.t3, size: 18),
                onPressed: () => _delete(col['id'] as int, col['name']?.toString() ?? ''),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (mangaIds.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 90,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: mangaIds.length,
                itemBuilder: (ctx, i) {
                  return GestureDetector(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MangaDetailScreen(mangaId: mangaIds[i]))),
                    child: Container(
                      width: 60,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.c2,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppTheme.brd, width: 0.5),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: FutureBuilder<dynamic>(
                          future: state.db.getMangaCover(mangaIds[i]),
                          builder: (ctx, snap) {
                            if (snap.hasData && snap.data != null) {
                              return Image.memory(snap.data, fit: BoxFit.cover, width: 60, height: 85);
                            }
                            return Center(child: Icon(Icons.menu_book, color: AppTheme.t3, size: 18));
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }
}
