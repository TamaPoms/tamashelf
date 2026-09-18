// Écran Kavita — parcours/lecture d'un serveur Kavita externe, INDÉPENDANT
// d'un serveur TamaShelf (voir services/kavita_service.dart et
// services/nautiljon_service.dart : config, associations et progression
// sont mémorisées localement sur le téléphone). Portage du KavitaBrowser du
// site (frontend/src/App.jsx) en plus simple pour une première version
// mobile : recherche + filtre associé/non-associé, matching auto avec file
// de suggestions à valider, association manuelle une par une, lecture avec
// reprise.
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../models/manga.dart';
import '../services/kavita_service.dart';
import '../services/nautiljon_service.dart';
import '../theme.dart';
import 'reader_screen.dart';

Volume _kavitaVolume(int seriesId, int chapterId, int totalPages) => Volume(
      id: chapterId,
      cbzFolder: 'kavita:series:$seriesId',
      libraryId: 0,
      filename: 'kavita_chapter_$chapterId',
      filepath: 'kavita:chapter:$chapterId',
      totalPages: totalPages,
    );

Future<void> _openKavitaChapter(
  BuildContext context, {
  required int seriesId,
  required String seriesName,
  required int chapterId,
  required int totalPages,
  int startPage = 0,
}) async {
  final kavita = context.read<AppState>().kavita;
  await Navigator.push(context, MaterialPageRoute(
    builder: (_) => ReaderScreen(
      title: seriesName,
      volume: _kavitaVolume(seriesId, chapterId, totalPages),
      online: true,
      onlineTotalPages: totalPages,
      startPage: startPage,
      onlinePageLoader: (page) => kavita.pageBytes(chapterId, page),
      progressMangaUrl: 'kavita:series:$seriesId',
      progressVolumeId: 'kavita:chapter:$chapterId',
      enableNextVolume: false,
    ),
  ));
}

// Déclenche la mise en cache des pages côté Kavita (chapter-info) avant
// d'ouvrir le lecteur -- sans cet appel préalable la première lecture d'un
// chapitre renvoie des pages vides/noires (voir kavita_service.dart).
Future<void> openKavitaChapterFresh(
  BuildContext context, {
  required int seriesId,
  required String seriesName,
  required int chapterId,
  required int fallbackPages,
  int startPage = 0,
}) async {
  final kavita = context.read<AppState>().kavita;
  try {
    final info = await kavita.chapterInfo(chapterId);
    final pages = (info['pages'] as num?)?.toInt() ?? fallbackPages;
    if (!context.mounted) return;
    await _openKavitaChapter(context,
        seriesId: seriesId, seriesName: seriesName, chapterId: chapterId, totalPages: pages, startPage: startPage);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur Kavita : $e'), backgroundColor: AppTheme.ros));
    }
  }
}

class KavitaScreen extends StatefulWidget {
  const KavitaScreen({super.key});
  @override
  State<KavitaScreen> createState() => _KavitaScreenState();
}

class _KavitaScreenState extends State<KavitaScreen> {
  bool _checking = true;
  bool _available = false;
  String? _error;
  List<Map<String, dynamic>> _libraries = [];
  int? _libId;
  List<Map<String, dynamic>> _seriesList = [];
  bool _loadingSeries = false;
  final _searchCtrl = TextEditingController();
  String? _matchFilter; // null | 'matched' | 'unmatched'
  bool _autoMatching = false;
  String _autoMatchStatus = '';

  KavitaService get _kavita => context.read<AppState>().kavita;
  NautiljonService get _naut => context.read<AppState>().nautiljon;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() { _checking = true; _error = null; });
    if (!_kavita.isConfigured) {
      setState(() { _checking = false; _available = false; });
      return;
    }
    try {
      final libs = await _kavita.libraries();
      if (!mounted) return;
      setState(() {
        _libraries = libs;
        _libId = libs.isNotEmpty ? libs.first['id'] as int : null;
        _available = true;
        _checking = false;
      });
      if (_libId != null) await _loadSeries();
    } catch (e) {
      if (!mounted) return;
      setState(() { _available = false; _error = '$e'; _checking = false; });
    }
  }

  Future<void> _loadSeries() async {
    if (_libId == null) return;
    setState(() => _loadingSeries = true);
    try {
      final list = await _kavita.seriesInLibrary(_libId!);
      list.sort((a, b) => (a['name'] as String? ?? '').toLowerCase().compareTo((b['name'] as String? ?? '').toLowerCase()));
      if (!mounted) return;
      setState(() { _seriesList = list; _loadingSeries = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadingSeries = false; _error = '$e'; });
    }
  }

  Future<void> _openConfig() async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const KavitaConfigScreen()));
    if (saved == true) _check();
  }

  Future<void> _runAutoMatch() async {
    if (_libId == null || _autoMatching) return;
    setState(() { _autoMatching = true; _autoMatchStatus = ''; });
    try {
      final result = await _naut.autoMatch(_seriesList, onProgress: (done, total) {
        if (mounted) setState(() => _autoMatchStatus = '$done/$total');
      });
      if (!mounted) return;
      setState(() => _autoMatching = false);
      var msg = '${result.autoMatched} associée(s) automatiquement';
      if (result.notFound > 0) msg += ', ${result.notFound} sans résultat exact';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      if (result.suggestions.isNotEmpty) {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => KavitaReviewQueueScreen(queue: result.suggestions)));
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _autoMatching = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur : $e'), backgroundColor: AppTheme.ros));
    }
  }

  Future<void> _openMatchAll() async {
    final unmatched = _seriesList.where((s) => _naut.matchFor(s['id'] as int) == null).toList();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => KavitaMatchAllScreen(seriesList: unmatched)));
    if (mounted) setState(() {});
  }

  Future<void> _resumeChapter({required String mangaUrl, required String volumeId, required String title, required int startPage}) async {
    final seriesId = int.tryParse(mangaUrl.replaceFirst('kavita:series:', '')) ?? 0;
    final chapterId = int.tryParse(volumeId.replaceFirst('kavita:chapter:', '')) ?? 0;
    if (seriesId == 0 || chapterId == 0) return;
    await openKavitaChapterFresh(context, seriesId: seriesId, seriesName: title, chapterId: chapterId, fallbackPages: 0, startPage: startPage);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.d,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: Text('Kavita', style: TextStyle(color: AppTheme.t1)),
        iconTheme: IconThemeData(color: AppTheme.t1),
        actions: [
          IconButton(icon: Icon(Icons.settings, color: AppTheme.t2), onPressed: _openConfig),
        ],
      ),
      body: _checking
          ? const Center(child: CircularProgressIndicator())
          : !_kavita.isConfigured
              ? _buildNotConfigured()
              : !_available
                  ? _buildError()
                  : _buildBrowser(),
    );
  }

  Widget _buildNotConfigured() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.dns, color: AppTheme.t3, size: 48),
          const SizedBox(height: 12),
          Text('Serveur Kavita non configuré', style: TextStyle(color: AppTheme.t1, fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            'Indépendant de TamaShelf : renseigne juste l\'adresse de ton serveur Kavita et ta clé API.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.t3, fontSize: 12),
          ),
          const SizedBox(height: 18),
          ElevatedButton.icon(onPressed: _openConfig, icon: const Icon(Icons.settings, size: 18), label: const Text('Configurer Kavita')),
        ]),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.wifi_off, color: AppTheme.ros, size: 48),
          const SizedBox(height: 12),
          Text('Serveur Kavita injoignable', style: TextStyle(color: AppTheme.t1, fontSize: 15, fontWeight: FontWeight.w600)),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: AppTheme.t3, fontSize: 11)),
            ),
          const SizedBox(height: 18),
          Row(mainAxisSize: MainAxisSize.min, children: [
            OutlinedButton.icon(onPressed: _check, icon: const Icon(Icons.refresh, size: 16), label: const Text('Réessayer')),
            const SizedBox(width: 10),
            ElevatedButton.icon(onPressed: _openConfig, icon: const Icon(Icons.settings, size: 16), label: const Text('Config')),
          ]),
        ]),
      ),
    );
  }

  Widget _buildBrowser() {
    final state = context.watch<AppState>();
    final inProgress = state.progress.inProgress.where((e) => e.volumeId.startsWith('kavita:chapter:')).toList();
    final q = _searchCtrl.text.trim().toLowerCase();
    final filtered = _seriesList.where((s) {
      final name = (s['name'] as String? ?? '');
      if (q.isNotEmpty && !name.toLowerCase().contains(q)) return false;
      final matched = _naut.matchFor(s['id'] as int) != null;
      if (_matchFilter == 'matched' && !matched) return false;
      if (_matchFilter == 'unmatched' && matched) return false;
      return true;
    }).toList();

    return RefreshIndicator(
      onRefresh: _loadSeries,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_libraries.length > 1) ...[
            Wrap(
              spacing: 6,
              children: _libraries.map((l) {
                final id = l['id'] as int;
                return ChoiceChip(
                  label: Text(l['name']?.toString() ?? '?'),
                  selected: id == _libId,
                  onSelected: (_) { setState(() => _libId = id); _loadSeries(); },
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
          ],
          if (inProgress.isNotEmpty) ...[
            Text('📖 En cours de lecture', style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 8),
            SizedBox(
              height: 150,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: inProgress.length,
                itemBuilder: (ctx, i) {
                  final e = inProgress[i];
                  final seriesId = int.tryParse(e.mangaUrl.replaceFirst('kavita:series:', '')) ?? 0;
                  return GestureDetector(
                    onTap: () => _resumeChapter(mangaUrl: e.mangaUrl, volumeId: e.volumeId, title: e.title, startPage: e.currentPage),
                    child: Container(
                      width: 100,
                      margin: const EdgeInsets.only(right: 10),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _KavitaCover(key: ValueKey('prog_$seriesId'), seriesId: seriesId))),
                        const SizedBox(height: 4),
                        Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.t1, fontSize: 10, fontWeight: FontWeight.w600)),
                        Text('${(e.percent * 100).round()}%', style: TextStyle(color: AppTheme.t3, fontSize: 9)),
                      ]),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(hintText: 'Rechercher une série...', isDense: true, prefixIcon: const Icon(Icons.search, size: 18)),
            style: TextStyle(color: AppTheme.t1, fontSize: 13),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            ChoiceChip(label: const Text('Toutes'), selected: _matchFilter == null, onSelected: (_) => setState(() => _matchFilter = null)),
            ChoiceChip(label: const Text('✓ Associées'), selected: _matchFilter == 'matched', onSelected: (_) => setState(() => _matchFilter = _matchFilter == 'matched' ? null : 'matched')),
            ChoiceChip(label: const Text('✗ Non associées'), selected: _matchFilter == 'unmatched', onSelected: (_) => setState(() => _matchFilter = _matchFilter == 'unmatched' ? null : 'unmatched')),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _autoMatching ? null : _runAutoMatch,
                icon: _autoMatching
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_fix_high, size: 16),
                label: Text(_autoMatching ? (_autoMatchStatus.isEmpty ? '...' : _autoMatchStatus) : 'Matching auto', style: const TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _seriesList.isEmpty ? null : _openMatchAll,
                icon: const Icon(Icons.link, size: 16),
                label: const Text('Associer', style: TextStyle(fontSize: 12)),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          if (_loadingSeries)
            const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
          else if (filtered.isEmpty)
            Padding(padding: const EdgeInsets.all(30), child: Center(child: Text('Aucune série', style: TextStyle(color: AppTheme.t3))))
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 120, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.6),
              itemCount: filtered.length,
              itemBuilder: (ctx, i) {
                final s = filtered[i];
                final sid = s['id'] as int;
                final matched = _naut.matchFor(sid) != null;
                return GestureDetector(
                  onTap: () async {
                    await Navigator.push(context, MaterialPageRoute(
                      builder: (_) => KavitaSeriesDetailScreen(seriesId: sid, seriesName: s['name']?.toString() ?? '?'),
                    ));
                    if (mounted) setState(() {});
                  },
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Stack(children: [
                      Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _KavitaCover(key: ValueKey(sid), seriesId: sid))),
                      if (matched)
                        Positioned(
                          top: 4, right: 4,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(color: AppTheme.grn, shape: BoxShape.circle),
                            child: const Icon(Icons.check, color: Colors.white, size: 10),
                          ),
                        ),
                    ])),
                    const SizedBox(height: 4),
                    Text(s['name']?.toString() ?? '?', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.t1, fontSize: 11, fontWeight: FontWeight.w600)),
                  ]),
                );
              },
            ),
        ],
      ),
    );
  }
}

// ── Cover série (mise en cache en mémoire côté KavitaService) ──

class _KavitaCover extends StatefulWidget {
  final int seriesId;
  const _KavitaCover({super.key, required this.seriesId});
  @override
  State<_KavitaCover> createState() => _KavitaCoverState();
}

class _KavitaCoverState extends State<_KavitaCover> {
  Uint8List? _bytes;
  bool _error = false;

  @override
  void initState() { super.initState(); _load(); }

  @override
  void didUpdateWidget(covariant _KavitaCover old) {
    super.didUpdateWidget(old);
    if (old.seriesId != widget.seriesId) {
      _bytes = null; _error = false; _load();
    }
  }

  Future<void> _load() async {
    try {
      final b = await context.read<AppState>().kavita.seriesCoverBytes(widget.seriesId);
      if (mounted) setState(() => _bytes = b);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.c2,
      child: _bytes != null
          ? Image.memory(_bytes!, fit: BoxFit.cover, width: double.infinity, height: double.infinity)
          : _error
              ? Center(child: Icon(Icons.menu_book, color: AppTheme.t3, size: 24))
              : const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
    );
  }
}

class _KavitaChapterCover extends StatefulWidget {
  final int chapterId;
  const _KavitaChapterCover({super.key, required this.chapterId});
  @override
  State<_KavitaChapterCover> createState() => _KavitaChapterCoverState();
}

class _KavitaChapterCoverState extends State<_KavitaChapterCover> {
  Uint8List? _bytes;
  bool _error = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final b = await context.read<AppState>().kavita.chapterCoverBytes(widget.chapterId);
      if (mounted) setState(() => _bytes = b);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.c2,
      child: _bytes != null
          ? Image.memory(_bytes!, fit: BoxFit.cover, width: double.infinity, height: double.infinity)
          : _error
              ? Center(child: Icon(Icons.image_not_supported, color: AppTheme.t3, size: 18))
              : const Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
    );
  }
}

// ── Config Kavita + tamajon ──

class KavitaConfigScreen extends StatefulWidget {
  const KavitaConfigScreen({super.key});
  @override
  State<KavitaConfigScreen> createState() => _KavitaConfigScreenState();
}

class _KavitaConfigScreenState extends State<KavitaConfigScreen> {
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _tamajonCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _urlCtrl.text = state.kavita.serverUrl;
    _keyCtrl.text = state.kavita.apiKey;
    _tamajonCtrl.text = state.nautiljon.baseUrl;
  }

  @override
  void dispose() {
    _urlCtrl.dispose(); _keyCtrl.dispose(); _tamajonCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _urlCtrl.text.trim();
    final key = _keyCtrl.text.trim();
    if (url.isEmpty || key.isEmpty) {
      setState(() => _error = 'URL et clé API requises');
      return;
    }
    setState(() { _loading = true; _error = null; });
    final state = context.read<AppState>();
    await state.kavita.setConfig(url.startsWith('http') ? url : 'http://$url', key);
    final tamajon = _tamajonCtrl.text.trim();
    await state.nautiljon.setBaseUrl(tamajon.isEmpty ? kDefaultTamajonUrl : tamajon);
    try {
      await state.kavita.libraries();
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<void> _remove() async {
    await context.read<AppState>().kavita.clearConfig();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final configured = context.watch<AppState>().kavita.isConfigured;
    return Scaffold(
      backgroundColor: AppTheme.d,
      appBar: AppBar(backgroundColor: AppTheme.bg, title: Text('Config Kavita', style: TextStyle(color: AppTheme.t1)), iconTheme: IconThemeData(color: AppTheme.t1)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Serveur Kavita', style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(controller: _urlCtrl, decoration: const InputDecoration(hintText: 'http://adresse:port'), style: TextStyle(color: AppTheme.t1), keyboardType: TextInputType.url),
          const SizedBox(height: 14),
          Text('Clé API Kavita', style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Kavita -> Compte -> Clés API', style: TextStyle(color: AppTheme.t3, fontSize: 10)),
          const SizedBox(height: 6),
          TextField(controller: _keyCtrl, decoration: const InputDecoration(hintText: 'Clé API'), style: TextStyle(color: AppTheme.t1)),
          const SizedBox(height: 20),
          Text('Base Nautiljon (tamajon)', style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Pour le matching -- utilisée directement, sans serveur TamaShelf', style: TextStyle(color: AppTheme.t3, fontSize: 10)),
          const SizedBox(height: 6),
          TextField(controller: _tamajonCtrl, decoration: InputDecoration(hintText: kDefaultTamajonUrl), style: TextStyle(color: AppTheme.t1), keyboardType: TextInputType.url),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: TextStyle(color: AppTheme.ros, fontSize: 12)),
          ],
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _loading ? null : _save,
            child: _loading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Enregistrer'),
          ),
          if (configured) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _loading ? null : _remove,
              style: OutlinedButton.styleFrom(foregroundColor: AppTheme.ros, side: BorderSide(color: AppTheme.ros)),
              child: const Text('Supprimer la config Kavita'),
            ),
          ],
        ]),
      ),
    );
  }
}

// ── Détail d'une série : infos + association Nautiljon + chapitres ──

class KavitaSeriesDetailScreen extends StatefulWidget {
  final int seriesId;
  final String seriesName;
  const KavitaSeriesDetailScreen({super.key, required this.seriesId, required this.seriesName});
  @override
  State<KavitaSeriesDetailScreen> createState() => _KavitaSeriesDetailScreenState();
}

class _KavitaSeriesDetailScreenState extends State<KavitaSeriesDetailScreen> {
  List<Map<String, dynamic>> _chapters = [];
  bool _loading = true;
  Map<String, dynamic>? _details;
  bool _loadingDetails = false;
  bool _showSearch = false;
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadMatchDetails();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final vols = await context.read<AppState>().kavita.volumes(widget.seriesId);
      final chapters = <Map<String, dynamic>>[];
      for (final v in vols) {
        for (final c in (v['chapters'] as List? ?? [])) {
          chapters.add({'volume': v, 'chapter': Map<String, dynamic>.from(c as Map)});
        }
      }
      if (mounted) setState(() { _chapters = chapters; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur : $e'), backgroundColor: AppTheme.ros));
    }
  }

  Future<void> _loadMatchDetails() async {
    final naut = context.read<AppState>().nautiljon;
    final match = naut.matchFor(widget.seriesId);
    if (match == null) return;
    setState(() => _loadingDetails = true);
    final details = await naut.mangaDetails(match['nautiljon_url'] as String);
    if (mounted) setState(() { _details = details; _loadingDetails = false; });
  }

  Future<void> _search() async {
    if (_searchCtrl.text.trim().isEmpty) return;
    setState(() => _searching = true);
    final r = await context.read<AppState>().nautiljon.search(_searchCtrl.text.trim());
    if (mounted) setState(() { _searchResults = r; _searching = false; });
  }

  Future<void> _pick(Map<String, dynamic> r) async {
    final naut = context.read<AppState>().nautiljon;
    await naut.saveMatch(widget.seriesId,
        nautiljonUrl: r['url'] as String, title: (r['title'] ?? '').toString(), cover: (r['cover_url'] ?? '').toString(), matchedBy: 'manual');
    if (mounted) {
      setState(() { _showSearch = false; _searchResults = []; });
      _loadMatchDetails();
    }
  }

  Future<void> _unmatch() async {
    await context.read<AppState>().nautiljon.deleteMatch(widget.seriesId);
    if (mounted) setState(() => _details = null);
  }

  @override
  Widget build(BuildContext context) {
    final naut = context.watch<AppState>().nautiljon;
    final match = naut.matchFor(widget.seriesId);
    return Scaffold(
      backgroundColor: AppTheme.d,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        iconTheme: IconThemeData(color: AppTheme.t1),
        title: Text(widget.seriesName, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.t1, fontSize: 15)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 90, height: 128, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _KavitaCover(seriesId: widget.seriesId))),
            const SizedBox(width: 12),
            Expanded(
              child: match == null
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Pas encore associée à Nautiljon', style: TextStyle(color: AppTheme.t2, fontSize: 12)),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(onPressed: () => setState(() => _showSearch = true), icon: const Icon(Icons.search, size: 16), label: const Text('Associer')),
                    ])
                  : _loadingDetails
                      ? const SizedBox(height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_details?['title']?.toString() ?? match['title']?.toString() ?? '', style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontSize: 14)),
                          if ((_details?['type'] ?? '').toString().isNotEmpty)
                            Text(_details!['type'].toString(), style: TextStyle(color: AppTheme.t3, fontSize: 11)),
                          if ((_details?['author'] ?? '').toString().isNotEmpty)
                            Text('✍️ ${_details!['author']}', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
                          if ((_details?['status'] ?? '').toString().isNotEmpty)
                            Text(_details!['status'].toString(), style: TextStyle(color: AppTheme.t3, fontSize: 11)),
                          const SizedBox(height: 8),
                          Row(children: [
                            TextButton(onPressed: () => setState(() => _showSearch = true), child: const Text('Modifier')),
                            TextButton(onPressed: _unmatch, style: TextButton.styleFrom(foregroundColor: AppTheme.ros), child: const Text('Dissocier')),
                          ]),
                        ]),
            ),
          ]),
          if ((_details?['synopsis'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_details!['synopsis'].toString(), style: TextStyle(color: AppTheme.t2, fontSize: 12)),
          ],
          if (_showSearch) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppTheme.c1, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.brd)),
              child: Column(children: [
                Row(children: [
                  Expanded(child: TextField(
                    controller: _searchCtrl,
                    decoration: const InputDecoration(hintText: 'Rechercher sur Nautiljon...', isDense: true),
                    style: TextStyle(color: AppTheme.t1, fontSize: 12),
                    onSubmitted: (_) => _search(),
                  )),
                  IconButton(
                    onPressed: _searching ? null : _search,
                    icon: _searching ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(Icons.search, color: AppTheme.t2),
                  ),
                ]),
                ..._searchResults.map((r) => ListTile(
                      dense: true,
                      leading: SizedBox(
                        width: 36, height: 50,
                        child: (r['cover_url'] as String? ?? '').isEmpty
                            ? Icon(Icons.book, color: AppTheme.t3)
                            : Image.network((r['cover_url'] as String), headers: kNautiljonImageHeaders, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Icon(Icons.book, color: AppTheme.t3)),
                      ),
                      title: Text(r['title']?.toString() ?? '?', style: TextStyle(color: AppTheme.t1, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => _pick(r),
                    )),
              ]),
            ),
          ],
          const SizedBox(height: 18),
          Text('Chapitres', style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 8),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_chapters.isEmpty)
            Text('Aucun volume/chapitre.', style: TextStyle(color: AppTheme.t3, fontSize: 12))
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 100, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.6),
              itemCount: _chapters.length,
              itemBuilder: (ctx, i) => _chapterTile(ctx, i),
            ),
        ],
      ),
    );
  }

  Widget _chapterTile(BuildContext context, int i) {
    final item = _chapters[i];
    final v = item['volume'] as Map<String, dynamic>;
    final c = item['chapter'] as Map<String, dynamic>;
    final vNum = (v['number'] as num?)?.toInt() ?? 0;
    final cNum = c['number'];
    // Kavita utilise -100000 pour "pas de numéro de chapitre applicable"
    // (volume à chapitre unique).
    final noChapNum = '$cNum' == '-100000';
    final chapterId = c['id'] as int;
    final label = vNum > 0
        ? (noChapNum ? 'Volume $vNum' : 'Volume $vNum — Ch. $cNum')
        : (noChapNum ? (c['title']?.toString().isNotEmpty == true ? c['title'].toString() : 'Chapitre') : 'Chapitre $cNum');
    return GestureDetector(
      onTap: () => openKavitaChapterFresh(context,
          seriesId: widget.seriesId, seriesName: widget.seriesName, chapterId: chapterId, fallbackPages: (c['pages'] as num?)?.toInt() ?? 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(6), child: _KavitaChapterCover(chapterId: chapterId))),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: AppTheme.t2, fontSize: 10), maxLines: 2, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}

// ── File de suggestions après un matching auto ──

class KavitaReviewQueueScreen extends StatefulWidget {
  final List<KavitaMatchSuggestion> queue;
  const KavitaReviewQueueScreen({super.key, required this.queue});
  @override
  State<KavitaReviewQueueScreen> createState() => _KavitaReviewQueueScreenState();
}

class _KavitaReviewQueueScreenState extends State<KavitaReviewQueueScreen> {
  int _index = 0;
  bool _busy = false;

  Future<void> _accept(KavitaMatchCandidate c) async {
    setState(() => _busy = true);
    await context.read<AppState>().nautiljon.saveMatch(widget.queue[_index].seriesId,
        nautiljonUrl: c.url, title: c.title, cover: c.cover, matchedBy: 'manual');
    _advance();
  }

  void _reject() => _advance();

  void _advance() {
    if (!mounted) return;
    if (_index < widget.queue.length - 1) {
      setState(() { _busy = false; _index++; });
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.queue.isEmpty) return const SizedBox.shrink();
    final item = widget.queue[_index];
    return Scaffold(
      backgroundColor: AppTheme.d,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        iconTheme: IconThemeData(color: AppTheme.t1),
        title: Text('Suggestions (${_index + 1}/${widget.queue.length})', style: TextStyle(color: AppTheme.t1, fontSize: 14)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler'))],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.seriesName, style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 4),
                Text('Choisis la bonne fiche Nautiljon, ou refuse', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
                const SizedBox(height: 14),
                Expanded(
                  child: GridView.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.6),
                    itemCount: item.candidates.length,
                    itemBuilder: (ctx, i) {
                      final c = item.candidates[i];
                      return GestureDetector(
                        onTap: () => _accept(c),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                color: AppTheme.c2,
                                child: c.cover.isEmpty
                                    ? Center(child: Icon(Icons.book, color: AppTheme.t3))
                                    : Image.network(c.cover, headers: kNautiljonImageHeaders, fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Center(child: Icon(Icons.book, color: AppTheme.t3))),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(c.title, style: TextStyle(color: AppTheme.t1, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
                        ]),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _reject,
                    style: OutlinedButton.styleFrom(foregroundColor: AppTheme.ros, side: BorderSide(color: AppTheme.ros)),
                    child: const Text('Refuser'),
                  ),
                ),
              ]),
            ),
    );
  }
}

// ── Association manuelle, une série non associée à la fois ──

class KavitaMatchAllScreen extends StatefulWidget {
  final List<Map<String, dynamic>> seriesList;
  const KavitaMatchAllScreen({super.key, required this.seriesList});
  @override
  State<KavitaMatchAllScreen> createState() => _KavitaMatchAllScreenState();
}

class _KavitaMatchAllScreenState extends State<KavitaMatchAllScreen> {
  int _index = 0;
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _prefillAndSearch();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _prefillAndSearch() {
    if (_index >= widget.seriesList.length) return;
    _ctrl.text = widget.seriesList[_index]['name']?.toString() ?? '';
    _search();
  }

  Future<void> _search() async {
    if (_ctrl.text.trim().isEmpty) return;
    setState(() => _searching = true);
    final r = await context.read<AppState>().nautiljon.search(_ctrl.text.trim());
    if (mounted) setState(() { _results = r; _searching = false; });
  }

  Future<void> _pick(Map<String, dynamic> r) async {
    final sid = widget.seriesList[_index]['id'] as int;
    await context.read<AppState>().nautiljon.saveMatch(sid,
        nautiljonUrl: r['url'] as String, title: (r['title'] ?? '').toString(), cover: (r['cover_url'] ?? '').toString(), matchedBy: 'manual');
    _advance();
  }

  void _skip() => _advance();

  void _advance() {
    if (!mounted) return;
    if (_index < widget.seriesList.length - 1) {
      setState(() { _results = []; _index++; });
      _prefillAndSearch();
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.seriesList.isEmpty) {
      return Scaffold(
        backgroundColor: AppTheme.d,
        appBar: AppBar(backgroundColor: AppTheme.bg, title: const Text('Associer')),
        body: Center(child: Text('Toutes les séries sont déjà associées.', style: TextStyle(color: AppTheme.t3))),
      );
    }
    final s = widget.seriesList[_index];
    return Scaffold(
      backgroundColor: AppTheme.d,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        iconTheme: IconThemeData(color: AppTheme.t1),
        title: Text('Associer (${_index + 1}/${widget.seriesList.length})', style: TextStyle(color: AppTheme.t1, fontSize: 14)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler'))],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s['name']?.toString() ?? '?', style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: TextField(
              controller: _ctrl,
              decoration: const InputDecoration(hintText: 'Rechercher sur Nautiljon...', isDense: true),
              style: TextStyle(color: AppTheme.t1, fontSize: 13),
              onSubmitted: (_) => _search(),
            )),
            IconButton(
              onPressed: _searching ? null : _search,
              icon: _searching ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(Icons.search, color: AppTheme.t2),
            ),
          ]),
          const SizedBox(height: 10),
          Expanded(
            child: _results.isEmpty
                ? Center(child: Text(_searching ? 'Recherche...' : 'Aucun résultat', style: TextStyle(color: AppTheme.t3)))
                : GridView.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.6),
                    itemCount: _results.length,
                    itemBuilder: (ctx, i) {
                      final r = _results[i];
                      final cov = (r['cover_url'] as String? ?? '');
                      return GestureDetector(
                        onTap: () => _pick(r),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                color: AppTheme.c2,
                                child: cov.isEmpty
                                    ? Center(child: Icon(Icons.book, color: AppTheme.t3))
                                    : Image.network(cov, headers: kNautiljonImageHeaders, fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Center(child: Icon(Icons.book, color: AppTheme.t3))),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(r['title']?.toString() ?? '?', style: TextStyle(color: AppTheme.t1, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
                        ]),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: OutlinedButton(onPressed: _skip, child: const Text('Passer'))),
        ]),
      ),
    );
  }
}
