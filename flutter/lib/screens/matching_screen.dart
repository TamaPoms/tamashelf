import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../models/manga.dart';
import '../theme.dart';

class MatchingScreen extends StatefulWidget {
  const MatchingScreen({super.key});
  @override
  State<MatchingScreen> createState() => _MatchingScreenState();
}

class _MatchingScreenState extends State<MatchingScreen> {
  List<Manga> _unmatched = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await context.read<AppState>().db.getUnmatchedMangas();
    if (mounted) setState(() { _unmatched = list; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        padding: const EdgeInsets.all(16), color: AppTheme.bg,
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
              gradient: const LinearGradient(colors: [MangaColors.warning, MangaColors.accent])),
            child: const Icon(Icons.link, color: Colors.white, size: 18),
          ),
          SizedBox(width: 10),
          Text('A associer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.t1)),
          Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: MangaColors.warning.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
            child: Text('${_unmatched.length}', style: const TextStyle(color: MangaColors.warning, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          IconButton(icon: Icon(Icons.refresh, color: AppTheme.t2, size: 20), onPressed: _load),
        ]),
      ),
      Expanded(
        child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _unmatched.isEmpty
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle, color: AppTheme.grn, size: 48), SizedBox(height: 12),
                Text('Tous les mangas sont associes !', style: TextStyle(color: AppTheme.t2, fontSize: 14)),
              ]))
            : ListView.builder(
                padding: const EdgeInsets.all(8), itemCount: _unmatched.length,
                itemBuilder: (ctx, i) => _Card(manga: _unmatched[i], onDone: () { _load(); context.read<AppState>().loadMangas(); }),
              ),
      ),
    ]);
  }
}

class _Card extends StatefulWidget {
  final Manga manga;
  final VoidCallback onDone;
  const _Card({required this.manga, required this.onDone});
  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false, _expanded = false, _validating = false;
  String _mode = '';

  @override
  void initState() { super.initState(); _ctrl.text = widget.manga.cbzFolder; }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _searchFast() async {
    if (_ctrl.text.trim().isEmpty) return;
    setState(() { _searching = true; _results = []; _mode = 'fast'; });
    final r = await context.read<AppState>().db.nautiljonSearchFast(_ctrl.text.trim());
    if (mounted) setState(() { _results = r; _searching = false; });
  }

  Future<void> _searchWeb() async {
    if (_ctrl.text.trim().isEmpty) return;
    setState(() { _searching = true; _results = []; _mode = 'web'; });
    final r = await context.read<AppState>().db.nautiljonSearchWeb(_ctrl.text.trim());
    if (mounted) setState(() { _results = r; _searching = false; });
  }

  Future<void> _validate(String url) async {
    if (url.isEmpty) return;
    setState(() => _validating = true);
    final ok = await context.read<AppState>().db.validateMatch(widget.manga.id, url);
    if (mounted) {
      setState(() => _validating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? '${widget.manga.title} associe !' : 'Erreur'),
        backgroundColor: ok ? AppTheme.grn : AppTheme.ros,
      ));
      if (ok) widget.onDone();
    }
  }

  String _cover(Map<String, dynamic> r) {
    for (final k in ['cover_mini', 'cover_full', 'cover_url', 'image_url']) {
      final v = r[k]?.toString().trim() ?? '';
      if (v.isNotEmpty) return v.startsWith('/') ? 'https://www.nautiljon.com$v' : v;
    }
    final url = r['url']?.toString() ?? '';
    if (url.contains('/mangas/')) {
      final s = url.split('/mangas/').last.replaceAll('.html', '').replaceAll('/', '');
      if (s.isNotEmpty) return 'https://www.nautiljon.com/images/manga/$s/mini/$s.jpg';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.c1, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _expanded ? MangaColors.accent.withValues(alpha: 0.5) : AppTheme.brd, width: _expanded ? 1.5 : 0.5),
      ),
      child: Column(children: [
        // Header
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
            Container(width: 40, height: 56,
              decoration: BoxDecoration(color: AppTheme.c2, borderRadius: BorderRadius.circular(6)),
              child: ClipRRect(borderRadius: BorderRadius.circular(6),
                child: _Cover(mangaId: widget.manga.id, cbzFolder: widget.manga.cbzFolder))),
            SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.manga.title, style: TextStyle(color: AppTheme.t1, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(widget.manga.cbzFolder, style: TextStyle(color: AppTheme.t3, fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
            Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: AppTheme.t3),
          ])),
        ),

        if (_expanded) ...[
          Divider(color: AppTheme.brd, height: 1),
          // Search
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Column(children: [
            SizedBox(height: 36, child: TextField(
              controller: _ctrl, style: TextStyle(color: AppTheme.t1, fontSize: 12),
              decoration: InputDecoration(hintText: 'Titre a rechercher...', hintStyle: const TextStyle(fontSize: 11),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
              onSubmitted: (_) => _searchFast(),
            )),
            const SizedBox(height: 6),
            Row(children: [
              // Fast search
              Expanded(child: SizedBox(height: 34, child: OutlinedButton.icon(
                onPressed: _searching ? null : _searchFast,
                icon: _searching && _mode == 'fast'
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search, size: 16),
                label: const Text('Rapide', style: TextStyle(fontSize: 11)),
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.cyn, side: BorderSide(color: AppTheme.cyn),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(horizontal: 8)),
              ))),
              const SizedBox(width: 8),
              // Web search (NTJ)
              Expanded(child: SizedBox(height: 34, child: ElevatedButton.icon(
                onPressed: _searching ? null : _searchWeb,
                icon: _searching && _mode == 'web'
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('🌐', style: TextStyle(fontSize: 14)),
                label: const Text('Nautiljon', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(backgroundColor: MangaColors.accent, foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(horizontal: 8)),
              ))),
            ]),
          ])),

          // State
          if (_validating)
            Padding(padding: EdgeInsets.all(20), child: Center(child: Column(children: [
              CircularProgressIndicator(), SizedBox(height: 8),
              Text('Association en cours...', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
            ])))
          else if (_searching)
            Padding(padding: const EdgeInsets.all(16), child: Column(children: [
              SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(height: 8),
              Text(_mode == 'web' ? 'Recherche sur Nautiljon.com...' : 'Recherche rapide...',
                style: TextStyle(color: AppTheme.t3, fontSize: 11)),
            ]))
          else if (_results.isNotEmpty)
            ...List.generate(_results.length, (i) => _item(_results[i]))
          else if (_mode.isNotEmpty)
            Padding(padding: EdgeInsets.all(12),
              child: Text('Aucun resultat. Essayez Nautiljon 🌐', style: TextStyle(color: AppTheme.t3, fontSize: 11)))
          else
            Padding(padding: EdgeInsets.all(12),
              child: Text('Rapide = BDD locale (instant)\nNautiljon = scraping du site (complet)',
                style: TextStyle(color: AppTheme.t3, fontSize: 10), textAlign: TextAlign.center)),
          const SizedBox(height: 6),
        ],
      ]),
    );
  }

  Widget _item(Map<String, dynamic> r) {
    final title = r['title']?.toString() ?? '?';
    final url = r['url']?.toString() ?? '';
    final cov = _cover(r);
    final short = url.replaceAll(RegExp(r'^https?://www\.nautiljon\.com'), '');

    return InkWell(
      onTap: () => _validate(url),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: AppTheme.c2, borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.brd, width: 0.5)),
        child: Row(children: [
          // Cover
          Container(width: 46, height: 64,
            decoration: BoxDecoration(color: AppTheme.inp, borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.brd, width: 0.5)),
            child: ClipRRect(borderRadius: BorderRadius.circular(6),
              child: cov.isNotEmpty
                ? Image.network(cov, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Center(child: Icon(Icons.book, color: AppTheme.t3, size: 20)))
                : Center(child: Icon(Icons.book, color: AppTheme.t3, size: 20)))),
          SizedBox(width: 10),
          // Info
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: AppTheme.t1, fontSize: 12, fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
            if (short.isNotEmpty) Text(short, style: TextStyle(color: AppTheme.t3, fontSize: 9), maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
          SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: AppTheme.grn.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.grn.withValues(alpha: 0.4))),
            child: Text('✓', style: TextStyle(color: AppTheme.grn, fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  final int mangaId;
  final String cbzFolder;
  _Cover({required this.mangaId, required this.cbzFolder});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    if (state.db.serverUrl.isEmpty || cbzFolder.isEmpty) {
      return Center(child: Icon(Icons.folder, color: AppTheme.t3, size: 16));
    }
    return Image.network(
      '${state.db.serverUrl}/api/cbz/folder-cover/${Uri.encodeComponent(cbzFolder)}',
      headers: state.db.authHeaders,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Center(child: Icon(Icons.folder, color: AppTheme.t3, size: 16)),
    );
  }
}
