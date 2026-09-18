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
import '../services/kavita_download_service.dart';
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
  final state = context.read<AppState>();
  final kavita = state.kavita;
  final kdl = state.kavitaDownloads;
  await Navigator.push(context, MaterialPageRoute(
    builder: (_) => ReaderScreen(
      title: seriesName,
      volume: _kavitaVolume(seriesId, chapterId, totalPages),
      online: true,
      onlineTotalPages: totalPages,
      startPage: startPage,
      onlinePageLoader: (page) async {
        // Chapitre téléchargé (voir services/kavita_download_service.dart) :
        // on lit sur disque, aucun accès réseau -- lecture hors-ligne.
        final local = await kdl.localPageBytes(chapterId, page);
        if (local != null) return local;
        return kavita.pageBytes(chapterId, page);
      },
      progressMangaUrl: 'kavita:series:$seriesId',
      progressVolumeId: 'kavita:chapter:$chapterId',
      enableNextVolume: false,
    ),
  ));
}

// Déclenche la mise en cache des pages côté Kavita (chapter-info) avant
// d'ouvrir le lecteur -- sans cet appel préalable la première lecture d'un
// chapitre renvoie des pages vides/noires (voir kavita_service.dart). Sauf
// si le chapitre est déjà téléchargé : on évite alors tout appel réseau
// (nombre de pages repris du manifeste local) pour une vraie lecture
// hors-ligne.
Future<void> openKavitaChapterFresh(
  BuildContext context, {
  required int seriesId,
  required String seriesName,
  required int chapterId,
  required int fallbackPages,
  int startPage = 0,
}) async {
  final state = context.read<AppState>();
  final downloaded = await state.kavitaDownloads.info(chapterId);
  if (downloaded != null) {
    final pages = (downloaded['totalPages'] as num?)?.toInt() ?? fallbackPages;
    if (!context.mounted) return;
    await _openKavitaChapter(context,
        seriesId: seriesId, seriesName: seriesName, chapterId: chapterId, totalPages: pages, startPage: startPage);
    return;
  }
  try {
    final info = await state.kavita.chapterInfo(chapterId);
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
  Map<String, List<String>> _tagFilters = {};
  bool _showTagPanel = false;
  bool _refreshingTags = false;
  String _refreshTagsStatus = '';

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
    // Ne pas repasser sur les séries déjà associées -- autoMatch() les
    // ignore de toute façon en interne, mais les lui passer quand même
    // gonflait inutilement le compteur de progression (et le temps
    // d'itération) avec des milliers d'entrées déjà traitées.
    final unmatched = _seriesList.where((s) => _naut.matchFor(s['id'] as int) == null).toList();
    if (unmatched.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Toutes les séries sont déjà associées.')));
      return;
    }
    setState(() { _autoMatching = true; _autoMatchStatus = ''; });
    try {
      final result = await _naut.autoMatch(unmatched, onProgress: (done, total) {
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

  // Associations sauvegardées avant l'ajout des tags (metadata) -- repasse
  // dessus pour aller les chercher sans tout ré-associer à la main.
  Future<void> _refreshTags() async {
    if (_refreshingTags) return;
    setState(() { _refreshingTags = true; _refreshTagsStatus = ''; });
    try {
      final updated = await _naut.refreshMissingTags(onProgress: (done, total) {
        if (mounted) setState(() => _refreshTagsStatus = '$done/$total');
      });
      if (!mounted) return;
      setState(() => _refreshingTags = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(updated > 0 ? '$updated association(s) mise(s) à jour avec leurs tags.' : 'Toutes les associations ont déjà leurs tags.'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _refreshingTags = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur : $e'), backgroundColor: AppTheme.ros));
    }
  }

  Future<void> _resumeChapter({required String mangaUrl, required String volumeId, required String title, required int startPage}) async {
    final seriesId = int.tryParse(mangaUrl.replaceFirst('kavita:series:', '')) ?? 0;
    final chapterId = int.tryParse(volumeId.replaceFirst('kavita:chapter:', '')) ?? 0;
    if (seriesId == 0 || chapterId == 0) return;
    await openKavitaChapterFresh(context, seriesId: seriesId, seriesName: title, chapterId: chapterId, fallbackPages: 0, startPage: startPage);
    if (mounted) setState(() {});
  }

  void _toggleTag(String category, String tag) {
    setState(() {
      final list = _tagFilters[category] ?? [];
      if (list.contains(tag)) {
        _tagFilters = {..._tagFilters, category: list.where((t) => t != tag).toList()};
      } else {
        _tagFilters = {..._tagFilters, category: [...list, tag]};
      }
    });
  }

  int get _activeTagCount => _tagFilters.values.fold(0, (sum, v) => sum + v.length);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.d,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: Text('Kavita', style: TextStyle(color: AppTheme.t1)),
        iconTheme: IconThemeData(color: AppTheme.t1),
        actions: [
          IconButton(
            icon: _refreshingTags
                ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.t2))
                : Icon(Icons.sync, color: AppTheme.t2),
            tooltip: _refreshingTags ? 'Rafraîchissement… $_refreshTagsStatus' : 'Rafraîchir les tags des associations existantes',
            onPressed: _refreshingTags ? null : _refreshTags,
          ),
          IconButton(
            icon: Icon(Icons.download_done, color: AppTheme.t2),
            tooltip: 'Téléchargements',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KavitaDownloadsScreen())),
          ),
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
    final filtered = _loadingSeries
        ? const <Map<String, dynamic>>[]
        : _seriesList.where((s) {
            final sid = s['id'] as int;
            final name = (s['name'] as String? ?? '');
            if (q.isNotEmpty && !name.toLowerCase().contains(q)) return false;
            final matched = _naut.matchFor(sid) != null;
            if (_matchFilter == 'matched' && !matched) return false;
            if (_matchFilter == 'unmatched' && matched) return false;
            if (!_naut.matchHasTags(sid, _tagFilters)) return false;
            return true;
          }).toList();
    final availableTags = _naut.allTags();

    // IMPORTANT : la grille de séries doit rester une sliver "paresseuse"
    // (SliverGrid dans le même CustomScrollView, pas un GridView.builder
    // shrinkWrap imbriqué dans un ListView) -- avec 4000+ séries, un
    // GridView shrinkWrap construit TOUTES les tuiles (et donc lance TOUS
    // les téléchargements de covers) d'un coup pour calculer sa hauteur,
    // ce qui bloquait/plantait l'appli. Ici seules les tuiles visibles
    // (+ la zone de cache habituelle de Flutter) sont construites.
    return RefreshIndicator(
      onRefresh: _loadSeries,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            sliver: SliverToBoxAdapter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  ChoiceChip(label: const Text('Toutes'), selected: _matchFilter == null, onSelected: (_) => setState(() => _matchFilter = null)),
                  ChoiceChip(label: const Text('✓ Associées'), selected: _matchFilter == 'matched', onSelected: (_) => setState(() => _matchFilter = _matchFilter == 'matched' ? null : 'matched')),
                  ChoiceChip(label: const Text('✗ Non associées'), selected: _matchFilter == 'unmatched', onSelected: (_) => setState(() => _matchFilter = _matchFilter == 'unmatched' ? null : 'unmatched')),
                  GestureDetector(
                    onTap: () => setState(() => _showTagPanel = !_showTagPanel),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: _showTagPanel ? AppTheme.ac : AppTheme.inp,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _showTagPanel ? AppTheme.ac : AppTheme.brd, width: 0.5),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.local_offer_outlined, size: 14, color: _showTagPanel ? Colors.white : AppTheme.t2),
                        if (_activeTagCount > 0) ...[
                          const SizedBox(width: 4),
                          Text('$_activeTagCount', style: TextStyle(color: _showTagPanel ? Colors.white : AppTheme.t2, fontSize: 11, fontWeight: FontWeight.w700)),
                        ],
                      ]),
                    ),
                  ),
                ]),
                if (_showTagPanel) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: AppTheme.c1, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.brd, width: 0.5)),
                    child: availableTags.isEmpty
                        ? Text(
                            'Pas encore de tags -- associe des séries à Nautiljon (matching auto ou manuel) pour les voir apparaître ici.',
                            style: TextStyle(color: AppTheme.t3, fontSize: 11),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: availableTags.entries.map((cat) {
                              final tagsSorted = cat.value.toList()..sort();
                              final selected = _tagFilters[cat.key] ?? [];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(cat.key, style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 5, runSpacing: 5,
                                    children: tagsSorted.take(30).map((tag) {
                                      final isOn = selected.contains(tag);
                                      final col = MangaColors.tagColor(tag);
                                      return GestureDetector(
                                        onTap: () => _toggleTag(cat.key, tag),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: isOn ? col : Colors.transparent,
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: col.withValues(alpha: isOn ? 1 : 0.5)),
                                          ),
                                          child: Text(tag, style: TextStyle(color: isOn ? Colors.white : col, fontSize: 11)),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ]),
                              );
                            }).toList(),
                          ),
                  ),
                ],
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
                if (_loadingSeries) ...[
                  LinearProgressIndicator(color: AppTheme.ac, backgroundColor: AppTheme.brd),
                  const SizedBox(height: 8),
                  Text('Chargement des séries…', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
                  const SizedBox(height: 20),
                ] else if (filtered.isEmpty)
                  Padding(padding: const EdgeInsets.all(30), child: Center(child: Text('Aucune série', style: TextStyle(color: AppTheme.t3)))),
              ]),
            ),
          ),
          if (!_loadingSeries && filtered.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 120, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.6),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) {
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
                  childCount: filtered.length,
                ),
              ),
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
  Set<int> _downloadedIds = {};
  bool _selectMode = false;
  final Set<int> _selected = {};
  bool _downloadBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadMatchDetails();
    _refreshDownloaded();
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
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final r = await context.read<AppState>().nautiljon.searchRanked(q);
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

  Future<void> _refreshDownloaded() async {
    final ids = await context.read<AppState>().kavitaDownloads.downloadedIds();
    if (mounted) setState(() => _downloadedIds = ids);
  }

  String _chapterLabel(Map<String, dynamic> v, Map<String, dynamic> c) {
    final vNum = (v['number'] as num?)?.toInt() ?? 0;
    final cNum = c['number'];
    final noChapNum = '$cNum' == '-100000';
    return vNum > 0
        ? (noChapNum ? 'Volume $vNum' : 'Volume $vNum — Ch. $cNum')
        : (noChapNum ? (c['title']?.toString().isNotEmpty == true ? c['title'].toString() : 'Chapitre') : 'Chapitre $cNum');
  }

  void _toggleSelectMode() {
    setState(() { _selectMode = !_selectMode; _selected.clear(); });
  }

  void _toggleSelected(int chapterId) {
    setState(() {
      if (_selected.contains(chapterId)) { _selected.remove(chapterId); } else { _selected.add(chapterId); }
    });
  }

  Future<void> _downloadOne(int chapterId) async {
    final item = _chapters.firstWhere((it) => (it['chapter'] as Map<String, dynamic>)['id'] == chapterId);
    await _runDownloads([item]);
  }

  Future<void> _downloadSelected() async {
    final items = _chapters.where((it) => _selected.contains((it['chapter'] as Map<String, dynamic>)['id'] as int)).toList();
    setState(() { _selectMode = false; _selected.clear(); });
    await _runDownloads(items);
  }

  Future<void> _runDownloads(List<Map<String, dynamic>> items) async {
    final kdl = context.read<AppState>().kavitaDownloads;
    final kavita = context.read<AppState>().kavita;
    final toDownload = <Map<String, dynamic>>[];
    for (final item in items) {
      final c = item['chapter'] as Map<String, dynamic>;
      final chapterId = c['id'] as int;
      if (!_downloadedIds.contains(chapterId)) toDownload.add(item);
    }
    if (toDownload.isEmpty) return;
    _downloadBusy = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => Consumer<AppState>(
        builder: (c2, state, _) {
          final active = toDownload
              .map((it) => (it['chapter'] as Map<String, dynamic>)['id'] as int)
              .map((id) => state.kavitaDownloads.activeDownloads[id])
              .whereType<KavitaDownloadInfo>()
              .toList();
          final finished = !_downloadBusy && active.isEmpty;
          return AlertDialog(
            backgroundColor: AppTheme.bg,
            title: Text(finished ? 'Téléchargement terminé' : 'Téléchargement…', style: TextStyle(color: AppTheme.t1, fontSize: 15)),
            content: SizedBox(
              width: 280,
              child: finished
                  ? Text('${toDownload.length} chapitre(s) traité(s).', style: TextStyle(color: AppTheme.t2, fontSize: 12))
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: active.map((d) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(d.label, style: TextStyle(color: AppTheme.t2, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 3),
                              LinearProgressIndicator(value: d.progress, backgroundColor: AppTheme.brd, color: AppTheme.ac),
                              if (d.hasError) Text(d.error ?? 'Erreur', style: TextStyle(color: AppTheme.ros, fontSize: 10)),
                            ]),
                          )).toList(),
                    ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('Fermer'))],
          );
        },
      ),
    );

    for (final item in toDownload) {
      final v = item['volume'] as Map<String, dynamic>;
      final c = item['chapter'] as Map<String, dynamic>;
      final chapterId = c['id'] as int;
      final label = _chapterLabel(v, c);
      try {
        final chapInfo = await kavita.chapterInfo(chapterId);
        final pages = (chapInfo['pages'] as num?)?.toInt() ?? (c['pages'] as num?)?.toInt() ?? 0;
        await kdl.downloadChapter(
          chapterId: chapterId,
          seriesId: widget.seriesId,
          seriesName: widget.seriesName,
          label: label,
          totalPages: pages,
        );
      } catch (_) {
        // KavitaDownloadInfo.hasError couvre déjà l'affichage -- on continue
        // avec les chapitres suivants de la sélection.
      }
    }
    _downloadBusy = false;
    await _refreshDownloaded();
    context.read<AppState>().notifyAllListeners(); // fait passer le dialogue de progression en "terminé"
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
        actions: [
          if (_chapters.isNotEmpty)
            IconButton(
              tooltip: _selectMode ? 'Annuler la sélection' : 'Télécharger plusieurs chapitres',
              icon: Icon(_selectMode ? Icons.close : Icons.download_for_offline_outlined, color: AppTheme.t2),
              onPressed: _toggleSelectMode,
            ),
        ],
      ),
      bottomNavigationBar: (_selectMode && _selected.isNotEmpty)
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _downloadSelected,
                    icon: const Icon(Icons.download, size: 18),
                    label: Text('Télécharger (${_selected.length})'),
                  ),
                ),
              ),
            )
          : null,
      body: CustomScrollView(
        slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          sliver: SliverToBoxAdapter(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                if (_searchResults.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _searchResults.length,
                      itemBuilder: (ctx, i) {
                        final r = _searchResults[i];
                        return ListTile(
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
                        );
                      },
                    ),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: 18),
          Text('Chapitres', style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(padding: EdgeInsets.only(bottom: 20), child: Center(child: CircularProgressIndicator()))
          else if (_chapters.isEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 20), child: Text('Aucun volume/chapitre.', style: TextStyle(color: AppTheme.t3, fontSize: 12))),
            ]),
          ),
        ),
        // Sliver "paresseuse" (voir la même remarque sur _buildBrowser dans
        // KavitaScreen) -- certaines séries/webtoons ont plusieurs centaines
        // de chapitres, un GridView shrinkWrap les construirait tous d'un
        // coup.
        if (!_loading && _chapters.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 100, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.6),
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _chapterTile(ctx, i),
                childCount: _chapters.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chapterTile(BuildContext context, int i) {
    final item = _chapters[i];
    final v = item['volume'] as Map<String, dynamic>;
    final c = item['chapter'] as Map<String, dynamic>;
    final chapterId = c['id'] as int;
    final label = _chapterLabel(v, c);
    final downloaded = _downloadedIds.contains(chapterId);
    final selected = _selected.contains(chapterId);
    return GestureDetector(
      onTap: () {
        if (_selectMode) { _toggleSelected(chapterId); return; }
        openKavitaChapterFresh(context,
            seriesId: widget.seriesId, seriesName: widget.seriesName, chapterId: chapterId, fallbackPages: (c['pages'] as num?)?.toInt() ?? 0);
      },
      onLongPress: () {
        if (!_selectMode) setState(() => _selectMode = true);
        _toggleSelected(chapterId);
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(6), child: _KavitaChapterCover(chapterId: chapterId))),
            if (_selectMode)
              Positioned(
                top: 4, left: 4,
                child: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: selected ? AppTheme.ac : Colors.white, size: 18,
                    shadows: const [Shadow(color: Colors.black54, blurRadius: 4)]),
              )
            else if (downloaded)
              Positioned(
                top: 4, left: 4,
                child: Icon(Icons.download_done, color: AppTheme.grn, size: 16, shadows: const [Shadow(color: Colors.black54, blurRadius: 4)]),
              )
            else
              Positioned(
                top: 2, right: 2,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  icon: const Icon(Icons.download, color: Colors.white, size: 16, shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
                  onPressed: () => _downloadOne(chapterId),
                ),
              ),
          ]),
        ),
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
          // CustomScrollView + SliverGrid plutôt qu'un GridView shrinkWrap :
          // les suggestions ne sont plus plafonnées (voir autoMatch dans
          // nautiljon_service.dart, le bon résultat était parfois hors du
          // top 6), donc potentiellement plusieurs dizaines de candidats --
          // autant rester sur une grille "paresseuse" par principe (même
          // remarque que _buildBrowser dans KavitaScreen).
          : CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(
                          width: 70, height: 100,
                          child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _KavitaCover(key: ValueKey('rev_${item.seriesId}'), seriesId: item.seriesId)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(item.seriesName, style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontSize: 16)),
                            const SizedBox(height: 4),
                            Text('Série Kavita', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
                            const SizedBox(height: 10),
                            Text('Choisis la bonne fiche Nautiljon ci-dessous (${item.candidates.length}), ou refuse.', style: TextStyle(color: AppTheme.t2, fontSize: 12)),
                          ]),
                        ),
                      ]),
                      const SizedBox(height: 14),
                    ]),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.6),
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) {
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
                      childCount: item.candidates.length,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  sliver: SliverToBoxAdapter(
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _reject,
                        style: OutlinedButton.styleFrom(foregroundColor: AppTheme.ros, side: BorderSide(color: AppTheme.ros)),
                        child: const Text('Refuser'),
                      ),
                    ),
                  ),
                ),
              ],
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
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final r = await context.read<AppState>().nautiljon.searchRanked(q);
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
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 60, height: 86,
              child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _KavitaCover(key: ValueKey('mall_${s['id']}'), seriesId: s['id'] as int)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(s['name']?.toString() ?? '?', style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontSize: 16))),
          ]),
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

// ── Gestion des chapitres Kavita téléchargés (hors-ligne) ──

class KavitaDownloadsScreen extends StatefulWidget {
  const KavitaDownloadsScreen({super.key});
  @override
  State<KavitaDownloadsScreen> createState() => _KavitaDownloadsScreenState();
}

class _KavitaDownloadsScreenState extends State<KavitaDownloadsScreen> {
  List<Map<String, dynamic>> _items = [];
  int _totalSize = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final kdl = context.read<AppState>().kavitaDownloads;
    final items = await kdl.listDownloads();
    final size = await kdl.totalSize();
    if (mounted) setState(() { _items = items; _totalSize = size; _loading = false; });
  }

  Future<void> _delete(int chapterId) async {
    await context.read<AppState>().kavitaDownloads.deleteChapter(chapterId);
    _load();
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes o';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} Ko';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} Mo';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} Go';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.d,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        iconTheme: IconThemeData(color: AppTheme.t1),
        title: Text('Téléchargements Kavita', style: TextStyle(color: AppTheme.t1, fontSize: 15)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('${_items.length} chapitre(s) · ${_formatSize(_totalSize)}', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
                ),
                Consumer<AppState>(
                  builder: (ctx, state, _) {
                    final active = state.kavitaDownloads.activeDownloads.values.toList();
                    if (active.isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: active.map((d) => Container(
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(color: AppTheme.c1, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.ac.withValues(alpha: 0.3))),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(d.label, style: TextStyle(color: AppTheme.t1, fontSize: 12), overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 6),
                              LinearProgressIndicator(value: d.progress, backgroundColor: AppTheme.brd, color: AppTheme.ac),
                            ]),
                          )).toList(),
                    );
                  },
                ),
                Expanded(
                  child: _items.isEmpty
                      ? Center(child: Text('Aucun chapitre Kavita téléchargé.', style: TextStyle(color: AppTheme.t3)))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            padding: const EdgeInsets.all(8),
                            itemCount: _items.length,
                            itemBuilder: (ctx, i) {
                              final it = _items[i];
                              final chapterId = it['chapterId'] as int;
                              return Container(
                                margin: const EdgeInsets.only(bottom: 4),
                                decoration: BoxDecoration(color: AppTheme.c1, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.brd, width: 0.5)),
                                child: ListTile(
                                  leading: Icon(Icons.download_done, color: AppTheme.grn, size: 24),
                                  title: Text(it['seriesName']?.toString() ?? '?', style: TextStyle(color: AppTheme.t1, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text('${it['label'] ?? ''} · ${_formatSize((it['sizeBytes'] as num? ?? 0).toInt())}', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
                                  trailing: IconButton(icon: Icon(Icons.delete_outline, color: AppTheme.ros, size: 20), onPressed: () => _delete(chapterId)),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}
