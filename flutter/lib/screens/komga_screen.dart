// Écran Komga — parcours/lecture d'un serveur Komga externe, INDÉPENDANT
// d'un serveur TamaShelf (voir services/komga_service.dart et
// services/nautiljon_service.dart : config, associations et progression
// sont mémorisées localement sur le téléphone). Miroir de kavita_screen.dart
// (même fonctionnalités : recherche + filtre associé/non-associé + filtre
// par tag, matching auto avec file de suggestions, association manuelle une
// par une, lecture avec reprise, téléchargement hors-ligne) -- SEUL le
// matching Nautiljon est partagé entre les deux (NautiljonService, voir
// nautiljon_service.dart). Différences avec Kavita : identifiants en String
// (UUID, pas des entiers), auth par simple clé API sans échange de jeton,
// pas de notion volume/chapitre séparée (juste des "livres" à plat), et le
// nombre de pages est déjà connu à la liste (media.pagesCount) -- pas
// besoin d'un appel réseau supplémentaire avant d'ouvrir le lecteur.
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../models/manga.dart';
import '../services/komga_service.dart';
import '../services/komga_download_service.dart';
import '../services/nautiljon_service.dart';
import '../theme.dart';
import 'reader_screen.dart';

// Statut Komga (SeriesMetadataUpdateDto.status) : ENDED/ONGOING/ABANDONED/
// HIATUS, une chaîne (contrairement à Kavita, sérialisé en entier). Mapping
// approximatif depuis le champ "Statut" (texte libre en français) de
// Nautiljon ; renvoie null si aucun mot-clé reconnu (le champ n'est alors
// pas touché).
String? _komgaStatus(String statut) {
  final s = statut.toLowerCase();
  if (s.contains('pause') || s.contains('hiatus')) return 'HIATUS';
  if (s.contains('arrêt') || s.contains('abandon')) return 'ABANDONED';
  if (s.contains('terminé') || s.contains('fini') || s.contains('complet')) return 'ENDED';
  if (s.contains('cours') || s.contains('publication')) return 'ONGOING';
  return null;
}

// Envoie le résumé/genres/thèmes/éditeur/statut de la fiche Nautiljon
// associée vers Komga -- l'API Komga patch uniquement les champs fournis
// (pas besoin de récupérer la fiche existante d'abord, contrairement à
// Kavita), verrouillés pour qu'un futur scan Komga ne les efface pas.
// Retourne un message d'erreur, ou null si tout s'est bien passé.
Future<String?> pushNautiljonToKomga(BuildContext context, {required String seriesId, required Map<String, dynamic> details}) async {
  final state = context.read<AppState>();
  try {
    final patch = <String, dynamic>{};

    final synopsis = (details['synopsis'] ?? '').toString().trim();
    if (synopsis.isNotEmpty) {
      patch['summary'] = synopsis;
      patch['summaryLock'] = true;
    }
    final genres = splitTagList((details['genres'] ?? '').toString());
    if (genres.isNotEmpty) {
      patch['genres'] = genres;
      patch['genresLock'] = true;
    }
    final themes = splitTagList((details['themes'] ?? '').toString());
    if (themes.isNotEmpty) {
      patch['tags'] = themes;
      patch['tagsLock'] = true;
    }
    final publisher = (details['publisher'] ?? '').toString().trim();
    if (publisher.isNotEmpty) {
      patch['publisher'] = publisher;
      patch['publisherLock'] = true;
    }
    final status = _komgaStatus((details['status'] ?? '').toString());
    if (status != null) {
      patch['status'] = status;
      patch['statusLock'] = true;
    }
    if (patch.isEmpty) return 'Rien à envoyer (fiche Nautiljon vide)';

    await state.komga.updateSeriesMetadata(seriesId, patch);
    return null;
  } catch (e) {
    return '$e';
  }
}

// Associe chaque tome Nautiljon (par numéro) au livre Komga du même numéro
// (Komga n'a pas de notion volume/chapitre séparée -- un livre = un tome),
// et pousse titre/résumé dessus. Renvoie (envoyés, sans correspondance).
Future<(int, int)> pushNautVolumesToKomga(
  BuildContext context, {
  required List<Map<String, dynamic>> books,
  required List<Map<String, dynamic>> nautVolumes,
}) async {
  final state = context.read<AppState>();
  var sent = 0;
  var unmatched = 0;
  for (final nv in nautVolumes) {
    final volNum = num.tryParse((nv['number'] ?? '').toString().trim());
    if (volNum == null) { unmatched++; continue; }
    final matches = books.where((b) {
      final bNum = b['number'] as num?;
      return bNum != null && bNum == volNum;
    }).toList();
    if (matches.isEmpty) { unmatched++; continue; }
    final title = (nv['title'] ?? '').toString().trim();
    final synopsis = (nv['synopsis'] ?? '').toString().trim();
    if (title.isEmpty && synopsis.isEmpty) continue;
    for (final b in matches) {
      final bookId = b['id'] as String;
      final patch = <String, dynamic>{};
      if (title.isNotEmpty) { patch['title'] = title; patch['titleLock'] = true; }
      if (synopsis.isNotEmpty) { patch['summary'] = synopsis; patch['summaryLock'] = true; }
      try {
        await state.komga.updateBookMetadata(bookId, patch);
        sent++;
      } catch (_) {
        // On continue avec les tomes suivants même si l'un échoue.
      }
    }
  }
  return (sent, unmatched);
}

Volume _komgaVolume(String seriesId, String bookId, int totalPages) => Volume(
      id: bookId.hashCode,
      cbzFolder: 'komga:series:$seriesId',
      libraryId: 0,
      filename: 'komga_book_$bookId',
      filepath: 'komga:book:$bookId',
      totalPages: totalPages,
    );

// Contrairement à Kavita, aucun appel réseau préalable n'est nécessaire :
// le nombre de pages est déjà connu (media.pagesCount, récupéré avec la
// liste des livres) ou repris du manifeste local si le livre est
// téléchargé -- lecture hors-ligne sans aucun accès réseau dans ce cas.
Future<void> openKomgaBook(
  BuildContext context, {
  required String seriesId,
  required String seriesName,
  required String bookId,
  required int totalPages,
  int startPage = 0,
}) async {
  final state = context.read<AppState>();
  final komga = state.komga;
  final kdl = state.komgaDownloads;
  await Navigator.push(context, MaterialPageRoute(
    builder: (_) => ReaderScreen(
      title: seriesName,
      volume: _komgaVolume(seriesId, bookId, totalPages),
      online: true,
      onlineTotalPages: totalPages,
      startPage: startPage,
      onlinePageLoader: (page) async {
        final local = await kdl.localPageBytes(bookId, page);
        if (local != null) return local;
        return komga.pageBytes(bookId, page);
      },
      onlineProgressPusher: (page) async {
        try { await komga.pushProgress(bookId, page); } catch (_) {}
      },
      progressMangaUrl: 'komga:series:$seriesId',
      progressVolumeId: 'komga:book:$bookId',
      enableNextVolume: false,
    ),
  ));
}

class KomgaScreen extends StatefulWidget {
  const KomgaScreen({super.key});
  @override
  State<KomgaScreen> createState() => _KomgaScreenState();
}

class _KomgaScreenState extends State<KomgaScreen> {
  bool _checking = true;
  bool _available = false;
  String? _error;
  List<Map<String, dynamic>> _libraries = [];
  String? _libId;
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
  bool _pushingAll = false;
  String _pushAllStatus = '';
  bool _pushingAllVolumes = false;
  String _pushAllVolumesStatus = '';

  KomgaService get _komga => context.read<AppState>().komga;
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
    if (!_komga.isConfigured) {
      setState(() { _checking = false; _available = false; });
      return;
    }
    try {
      final libs = await _komga.libraries();
      if (!mounted) return;
      setState(() {
        _libraries = libs;
        _libId = libs.isNotEmpty ? libs.first['id'] as String : null;
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
    setState(() { _loadingSeries = true; _error = null; });
    try {
      final list = await _komga.seriesInLibrary(_libId!);
      list.sort((a, b) => komgaSeriesTitle(a).toLowerCase().compareTo(komgaSeriesTitle(b).toLowerCase()));
      if (!mounted) return;
      setState(() { _seriesList = list; _loadingSeries = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadingSeries = false; _error = '$e'; });
    }
  }

  Future<void> _openConfig() async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const KomgaConfigScreen()));
    if (saved == true) _check();
  }

  Future<void> _runAutoMatch() async {
    if (_libId == null || _autoMatching) return;
    final unmatched = _seriesList.where((s) => _naut.matchFor('komga', s['id'] as String) == null).toList();
    if (unmatched.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Toutes les séries sont déjà associées.')));
      return;
    }
    setState(() { _autoMatching = true; _autoMatchStatus = ''; });
    try {
      // komgaSeriesTitle (metadata.title si renseigné, sinon name) plutôt
      // que le champ brut 'name' -- autoMatch() lit s['name'].
      final withName = unmatched.map((s) => {...s, 'name': komgaSeriesTitle(s)}).toList();
      final result = await _naut.autoMatch('komga', withName, onProgress: (done, total) {
        if (mounted) setState(() => _autoMatchStatus = '$done/$total');
      });
      if (!mounted) return;
      setState(() => _autoMatching = false);
      var msg = '${result.autoMatched} associée(s) automatiquement';
      if (result.notFound > 0) msg += ', ${result.notFound} sans résultat exact';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      if (result.suggestions.isNotEmpty) {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => KomgaReviewQueueScreen(queue: result.suggestions)));
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _autoMatching = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur : $e'), backgroundColor: AppTheme.ros));
    }
  }

  Future<void> _openMatchAll() async {
    final unmatched = _seriesList.where((s) => _naut.matchFor('komga', s['id'] as String) == null).toList();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => KomgaMatchAllScreen(seriesList: unmatched)));
    if (mounted) setState(() {});
  }

  Future<void> _refreshTags() async {
    if (_refreshingTags) return;
    // "Tout forcer" -- indispensable après une mise à jour de l'appli qui
    // change la façon dont les tags sont extraits (ex. genres/thèmes
    // désormais réunis depuis plusieurs clés Nautiljon au lieu d'une seule) :
    // sans ça, une association qui a DÉJÀ des tags (même incomplets/anciens)
    // n'est jamais retouchée par le rafraîchissement normal.
    final force = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg,
        title: Text('Rafraîchir les tags', style: TextStyle(color: AppTheme.t1, fontSize: 15)),
        content: Text(
          'Associations sans aucun tag uniquement, ou tout recalculer (utile après une mise à jour de l\'appli, même si des tags existent déjà) ?',
          style: TextStyle(color: AppTheme.t2, fontSize: 12),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Sans tag uniquement')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Tout recalculer')),
        ],
      ),
    );
    if (force == null || !mounted) return;
    setState(() { _refreshingTags = true; _refreshTagsStatus = ''; });
    try {
      final updated = await _naut.refreshMissingTags(force: force, onProgress: (done, total) {
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

  // Envoie les infos Nautiljon de TOUTES les séries associées vers Komga en
  // une fois (voir pushNautiljonToKomga) -- une fiche à la fois, avec
  // progression.
  Future<void> _pushAllToServer() async {
    if (_pushingAll) return;
    final matched = _seriesList.where((s) => _naut.matchFor('komga', s['id'] as String) != null).toList();
    if (matched.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Aucune série associée à envoyer.')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg,
        title: Text('Tout envoyer vers Komga ?', style: TextStyle(color: AppTheme.t1, fontSize: 15)),
        content: Text(
          'Le résumé, les genres, les thèmes, l\'éditeur et le statut Nautiljon vont être écrits (et verrouillés) dans les ${matched.length} série(s) associée(s). Peut prendre un moment.',
          style: TextStyle(color: AppTheme.t2, fontSize: 12),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Envoyer')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() { _pushingAll = true; _pushAllStatus = '0/${matched.length}'; });
    var ok = 0;
    var failed = 0;
    for (var i = 0; i < matched.length; i++) {
      final sid = matched[i]['id'] as String;
      final match = _naut.matchFor('komga', sid)!;
      final details = await _naut.mangaDetails(match['nautiljon_url'] as String);
      if (details != null) {
        final error = await pushNautiljonToKomga(context, seriesId: sid, details: details);
        if (error == null) { ok++; } else { failed++; }
      } else {
        failed++;
      }
      if (mounted) setState(() => _pushAllStatus = '${i + 1}/${matched.length}');
    }
    if (!mounted) return;
    setState(() => _pushingAll = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$ok envoyée(s)${failed > 0 ? ', $failed en erreur' : ''}.'),
      backgroundColor: failed > 0 ? AppTheme.ros : AppTheme.grn,
    ));
  }

  // Pour chaque série associée : charge ses livres Komga + ses tomes
  // Nautiljon (édition choisie via pickEdition), puis pousse titre/résumé
  // tome par tome (voir pushNautVolumesToKomga). Potentiellement long sur
  // une grosse bibliothèque, d'où la confirmation et la progression.
  Future<void> _pushAllVolumesToServer() async {
    if (_pushingAllVolumes) return;
    final matched = _seriesList.where((s) => _naut.matchFor('komga', s['id'] as String) != null).toList();
    if (matched.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Aucune série associée à envoyer.')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg,
        title: Text('Tout envoyer vers Komga (tomes) ?', style: TextStyle(color: AppTheme.t1, fontSize: 15)),
        content: Text(
          'Charge les tomes Nautiljon des ${matched.length} série(s) associée(s) et envoie titre/résumé de chaque tome sur le livre Komga correspondant. Peut prendre plusieurs minutes.',
          style: TextStyle(color: AppTheme.t2, fontSize: 12),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Envoyer')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final state = context.read<AppState>();
    setState(() { _pushingAllVolumes = true; _pushAllVolumesStatus = '0/${matched.length}'; });
    var totalSent = 0;
    var seriesFailed = 0;
    for (var i = 0; i < matched.length; i++) {
      final sid = matched[i]['id'] as String;
      final seriesName = komgaSeriesTitle(matched[i]);
      final match = _naut.matchFor('komga', sid)!;
      try {
        final books = await state.komga.booksInSeries(sid);
        final editions = await _naut.mangaEditions(match['nautiljon_url'] as String);
        final edition = pickEdition(editions, seriesName);
        final nautVolumes = ((edition?['volumes'] as List?) ?? []).map((v) => Map<String, dynamic>.from(v as Map)).toList();
        if (!mounted) return;
        final (sent, _) = await pushNautVolumesToKomga(context, books: books, nautVolumes: nautVolumes);
        totalSent += sent;
      } catch (_) {
        seriesFailed++;
      }
      if (mounted) setState(() => _pushAllVolumesStatus = '${i + 1}/${matched.length}');
    }
    if (!mounted) return;
    setState(() => _pushingAllVolumes = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$totalSent tome(s) envoyé(s)${seriesFailed > 0 ? ', $seriesFailed série(s) en erreur' : ''}.'),
      backgroundColor: seriesFailed > 0 ? AppTheme.ros : AppTheme.grn,
    ));
  }

  Future<void> _resumeBook({required String mangaUrl, required String volumeId, required String title, required int startPage, required int totalPages}) async {
    final seriesId = mangaUrl.replaceFirst('komga:series:', '');
    final bookId = volumeId.replaceFirst('komga:book:', '');
    if (seriesId.isEmpty || bookId.isEmpty || seriesId == mangaUrl || bookId == volumeId) return;
    await openKomgaBook(context, seriesId: seriesId, seriesName: title, bookId: bookId, totalPages: totalPages, startPage: startPage);
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
        title: Text('Komga', style: TextStyle(color: AppTheme.t1)),
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
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KomgaDownloadsScreen())),
          ),
          IconButton(icon: Icon(Icons.settings, color: AppTheme.t2), onPressed: _openConfig),
        ],
      ),
      body: _checking
          ? const Center(child: CircularProgressIndicator())
          : !_komga.isConfigured
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
          Text('Serveur Komga non configuré', style: TextStyle(color: AppTheme.t1, fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            'Indépendant de TamaShelf : renseigne juste l\'adresse de ton serveur Komga et ta clé API.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.t3, fontSize: 12),
          ),
          const SizedBox(height: 18),
          ElevatedButton.icon(onPressed: _openConfig, icon: const Icon(Icons.settings, size: 18), label: const Text('Configurer Komga')),
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
          Text('Serveur Komga injoignable', style: TextStyle(color: AppTheme.t1, fontSize: 15, fontWeight: FontWeight.w600)),
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
    final inProgress = state.progress.inProgress.where((e) => e.volumeId.startsWith('komga:book:')).toList();
    final q = _searchCtrl.text.trim().toLowerCase();
    final filtered = _loadingSeries
        ? const <Map<String, dynamic>>[]
        : _seriesList.where((s) {
            final sid = s['id'] as String;
            final name = komgaSeriesTitle(s);
            if (q.isNotEmpty && !name.toLowerCase().contains(q)) return false;
            final matched = _naut.matchFor('komga', sid) != null;
            if (_matchFilter == 'matched' && !matched) return false;
            if (_matchFilter == 'unmatched' && matched) return false;
            if (!_naut.matchHasTags('komga', sid, _tagFilters)) return false;
            return true;
          }).toList();
    final availableTags = _naut.allTags(source: 'komga');

    // Sliver "paresseuse" -- voir la même remarque dans kavita_screen.dart
    // (_buildBrowser) : un GridView shrinkWrap imbriqué dans un ListView
    // construit toutes les tuiles d'un coup pour calculer sa hauteur, ce
    // qui plante avec des milliers de séries.
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
                      final id = l['id'] as String;
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
                        final seriesId = e.mangaUrl.replaceFirst('komga:series:', '');
                        return GestureDetector(
                          onTap: () => _resumeBook(mangaUrl: e.mangaUrl, volumeId: e.volumeId, title: e.title, startPage: e.currentPage, totalPages: e.totalPages),
                          child: Container(
                            width: 100,
                            margin: const EdgeInsets.only(right: 10),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _KomgaCover(key: ValueKey('prog_$seriesId'), seriesId: seriesId))),
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
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _pushingAll ? null : _pushAllToServer,
                    icon: _pushingAll
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cloud_upload_outlined, size: 16),
                    label: Text(_pushingAll ? 'Envoi… $_pushAllStatus' : 'Envoyer toutes les infos vers Komga', style: const TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _pushingAllVolumes ? null : _pushAllVolumesToServer,
                    icon: _pushingAllVolumes
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.menu_book_outlined, size: 16),
                    label: Text(_pushingAllVolumes ? 'Envoi… $_pushAllVolumesStatus' : 'Envoyer tous les tomes vers Komga', style: const TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(height: 12),
                if (_loadingSeries) ...[
                  LinearProgressIndicator(color: AppTheme.ac, backgroundColor: AppTheme.brd),
                  const SizedBox(height: 8),
                  Text('Chargement des séries…', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
                  const SizedBox(height: 20),
                ] else if (filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(30),
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_error != null ? 'Erreur de chargement' : 'Aucune série', style: TextStyle(color: AppTheme.t3)),
                        if (_error != null) ...[
                          const SizedBox(height: 6),
                          Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: AppTheme.ros, fontSize: 11)),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(onPressed: _loadSeries, icon: const Icon(Icons.refresh, size: 16), label: const Text('Réessayer')),
                        ],
                      ]),
                    ),
                  ),
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
                    final sid = s['id'] as String;
                    final title = komgaSeriesTitle(s);
                    final matched = _naut.matchFor('komga', sid) != null;
                    return GestureDetector(
                      onTap: () async {
                        await Navigator.push(context, MaterialPageRoute(
                          builder: (_) => KomgaSeriesDetailScreen(seriesId: sid, seriesName: title),
                        ));
                        if (mounted) setState(() {});
                      },
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: Stack(children: [
                          Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _KomgaCover(key: ValueKey(sid), seriesId: sid))),
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
                        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.t1, fontSize: 11, fontWeight: FontWeight.w600)),
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

// ── Cover série/livre (mise en cache en mémoire + disque côté
// KomgaService) ──

class _KomgaCover extends StatefulWidget {
  final String seriesId;
  const _KomgaCover({super.key, required this.seriesId});
  @override
  State<_KomgaCover> createState() => _KomgaCoverState();
}

class _KomgaCoverState extends State<_KomgaCover> {
  Uint8List? _bytes;
  bool _error = false;

  @override
  void initState() { super.initState(); _load(); }

  @override
  void didUpdateWidget(covariant _KomgaCover old) {
    super.didUpdateWidget(old);
    if (old.seriesId != widget.seriesId) {
      _bytes = null; _error = false; _load();
    }
  }

  Future<void> _load() async {
    try {
      final b = await context.read<AppState>().komga.seriesCoverBytes(widget.seriesId);
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

class _KomgaBookCover extends StatefulWidget {
  final String bookId;
  const _KomgaBookCover({super.key, required this.bookId});
  @override
  State<_KomgaBookCover> createState() => _KomgaBookCoverState();
}

class _KomgaBookCoverState extends State<_KomgaBookCover> {
  Uint8List? _bytes;
  bool _error = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final b = await context.read<AppState>().komga.bookCoverBytes(widget.bookId);
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

// ── Config Komga + tamajon ──

class KomgaConfigScreen extends StatefulWidget {
  const KomgaConfigScreen({super.key});
  @override
  State<KomgaConfigScreen> createState() => _KomgaConfigScreenState();
}

class _KomgaConfigScreenState extends State<KomgaConfigScreen> {
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _tamajonCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _urlCtrl.text = state.komga.serverUrl;
    _keyCtrl.text = state.komga.apiKey;
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
    await state.komga.setConfig(url.startsWith('http') ? url : 'http://$url', key);
    final tamajon = _tamajonCtrl.text.trim();
    await state.nautiljon.setBaseUrl(tamajon.isEmpty ? kDefaultTamajonUrl : tamajon);
    try {
      await state.komga.libraries();
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<void> _remove() async {
    await context.read<AppState>().komga.clearConfig();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final configured = context.watch<AppState>().komga.isConfigured;
    return Scaffold(
      backgroundColor: AppTheme.d,
      appBar: AppBar(backgroundColor: AppTheme.bg, title: Text('Config Komga', style: TextStyle(color: AppTheme.t1)), iconTheme: IconThemeData(color: AppTheme.t1)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Serveur Komga', style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(controller: _urlCtrl, decoration: const InputDecoration(hintText: 'http://adresse:port'), style: TextStyle(color: AppTheme.t1), keyboardType: TextInputType.url),
          const SizedBox(height: 14),
          Text('Clé API Komga', style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Komga -> Paramètres -> Clés API', style: TextStyle(color: AppTheme.t3, fontSize: 10)),
          const SizedBox(height: 6),
          TextField(controller: _keyCtrl, decoration: const InputDecoration(hintText: 'Clé API'), style: TextStyle(color: AppTheme.t1)),
          const SizedBox(height: 20),
          Text('Base Nautiljon (tamajon)', style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Pour le matching -- utilisée directement, sans serveur TamaShelf. Partagée avec Kavita.', style: TextStyle(color: AppTheme.t3, fontSize: 10)),
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
              child: const Text('Supprimer la config Komga'),
            ),
          ],
        ]),
      ),
    );
  }
}

// ── Détail d'une série : infos + association Nautiljon + livres ──

class KomgaSeriesDetailScreen extends StatefulWidget {
  final String seriesId;
  final String seriesName;
  const KomgaSeriesDetailScreen({super.key, required this.seriesId, required this.seriesName});
  @override
  State<KomgaSeriesDetailScreen> createState() => _KomgaSeriesDetailScreenState();
}

class _KomgaSeriesDetailScreenState extends State<KomgaSeriesDetailScreen> {
  List<Map<String, dynamic>> _books = [];
  bool _loading = true;
  Map<String, dynamic>? _details;
  bool _loadingDetails = false;
  bool _showSearch = false;
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _searching = false;
  Set<String> _downloadedIds = {};
  bool _selectMode = false;
  final Set<String> _selected = {};
  bool _downloadBusy = false;
  bool _pushing = false;
  List<Map<String, dynamic>>? _nautVolumes;
  String? _nautEditionName;
  bool _loadingNautVolumes = false;
  String? _nautVolumesError;
  bool _pushingVolumes = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadMatchDetails();
    _refreshDownloaded();
    _loadCachedVolumes();
  }

  // Reprend les tomes Nautiljon déjà chargés une fois par le passé (voir
  // NautiljonService.cachedVolumes/cacheVolumes) -- évite de retélécharger
  // la liste à chaque ouverture de la fiche série ; le bouton "Recharger"
  // reste disponible pour forcer une mise à jour.
  void _loadCachedVolumes() {
    final naut = context.read<AppState>().nautiljon;
    final cached = naut.cachedVolumes('komga', widget.seriesId);
    if (cached == null) return;
    final volumes = (cached['volumes'] as List?) ?? [];
    setState(() {
      _nautVolumes = volumes.map((v) => Map<String, dynamic>.from(v as Map)).toList();
      _nautEditionName = (cached['edition_name'] ?? '').toString();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final books = await context.read<AppState>().komga.booksInSeries(widget.seriesId);
      if (mounted) setState(() { _books = books; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur : $e'), backgroundColor: AppTheme.ros));
    }
  }

  Future<void> _loadMatchDetails() async {
    final naut = context.read<AppState>().nautiljon;
    final match = naut.matchFor('komga', widget.seriesId);
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
    await naut.saveMatch(
        source: 'komga', seriesId: widget.seriesId,
        nautiljonUrl: r['url'] as String, title: (r['title'] ?? '').toString(), cover: (r['cover_url'] ?? '').toString(), matchedBy: 'manual');
    if (mounted) {
      setState(() { _showSearch = false; _searchResults = []; });
      _loadMatchDetails();
    }
  }

  Future<void> _unmatch() async {
    await context.read<AppState>().nautiljon.deleteMatch('komga', widget.seriesId);
    if (mounted) setState(() { _details = null; _nautVolumes = null; });
  }

  // Récupère les tomes Nautiljon de l'édition correspondant à la série
  // (voir pickEdition). Chargement à la demande (bouton), pas automatique.
  Future<void> _loadNautVolumes() async {
    final naut = context.read<AppState>().nautiljon;
    final match = naut.matchFor('komga', widget.seriesId);
    if (match == null) return;
    setState(() { _loadingNautVolumes = true; _nautVolumesError = null; });
    try {
      final editions = await naut.mangaEditions(match['nautiljon_url'] as String);
      final edition = pickEdition(editions, widget.seriesName);
      if (!mounted) return;
      final volumes = ((edition?['volumes'] as List?) ?? []).map((v) => Map<String, dynamic>.from(v as Map)).toList();
      final editionName = (edition?['name'] ?? '').toString();
      setState(() {
        _nautVolumes = volumes;
        _nautEditionName = editionName;
        _loadingNautVolumes = false;
        // La grille "Livres" (seule à supporter la sélection multiple) se
        // masque dès que des tomes sont chargés -- pas la peine de garder
        // une sélection en cours dont l'UI a disparu.
        if (_nautVolumes!.isNotEmpty) { _selectMode = false; _selected.clear(); }
      });
      await naut.cacheVolumes('komga', widget.seriesId, editionName, volumes);
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadingNautVolumes = false; _nautVolumesError = '$e'; });
    }
  }

  // Livre Komga qui porte le même numéro qu'un tome Nautiljon -- même
  // logique que pushNautVolumesToKomga (par numéro). Utilisé pour que la
  // carte de tome (cover Nautiljon + infos) serve ELLE-MÊME de tuile de
  // lecture, au lieu d'avoir une deuxième vignette (celle de la grille
  // "Livres") pour le même tome.
  Map<String, dynamic>? _bookForVolumeNumber(String numberStr) {
    final volNum = num.tryParse(numberStr.trim());
    if (volNum == null) return null;
    for (final b in _books) {
      final bNum = b['number'] as num?;
      if (bNum != null && bNum == volNum) return b;
    }
    return null;
  }

  Widget _nautVolumeCard(Map<String, dynamic> v) {
    final cover = (v['cover_url'] ?? '').toString();
    final number = (v['number'] ?? '').toString();
    final title = (v['title'] ?? '').toString();
    final synopsis = (v['synopsis'] ?? '').toString();
    final extra = (v['extra'] is Map) ? Map<String, dynamic>.from(v['extra'] as Map) : const <String, dynamic>{};
    final book = _bookForVolumeNumber(number);
    final bookId = book?['id'] as String?;
    final downloaded = bookId != null && _downloadedIds.contains(bookId);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: AppTheme.c1, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.brd, width: 0.5)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: bookId == null
            ? null
            : () => openKomgaBook(context, seriesId: widget.seriesId, seriesName: widget.seriesName, bookId: bookId, totalPages: komgaPagesCount(book!)),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              number.isNotEmpty ? 'Tome $number${title.isNotEmpty ? ' — $title' : ''}' : (title.isNotEmpty ? title : '?'),
              style: TextStyle(color: AppTheme.t1, fontSize: 12, fontWeight: FontWeight.w700),
              maxLines: 2, overflow: TextOverflow.ellipsis,
            ),
            if (bookId == null) ...[
              const SizedBox(height: 2),
              Text('Aucun livre Komga correspondant', style: TextStyle(color: AppTheme.t3, fontSize: 10, fontStyle: FontStyle.italic)),
            ],
            const SizedBox(height: 6),
            // Trois colonnes : cover à gauche, synopsis au milieu, reste
            // des infos (extra, voir NautiljonService.mangaEditions) à
            // droite -- IntrinsicHeight pour que les 3 colonnes s'étendent
            // sur la hauteur du contenu le plus grand (synopsis/infos sans
            // troncature désormais, "tout récupérer").
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 60, height: 86,
                  child: Stack(children: [
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: cover.isEmpty
                            ? Container(color: AppTheme.inp, child: Icon(Icons.book, color: AppTheme.t3))
                            : Image.network(cover, headers: kNautiljonImageHeaders, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(color: AppTheme.inp, child: Icon(Icons.book, color: AppTheme.t3))),
                      ),
                    ),
                    if (bookId != null)
                      Positioned(
                        top: 2, right: 2,
                        child: downloaded
                            ? Icon(Icons.download_done, color: AppTheme.grn, size: 16, shadows: const [Shadow(color: Colors.black54, blurRadius: 4)])
                            : IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                                icon: const Icon(Icons.download, color: Colors.white, size: 16, shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
                                onPressed: () => _downloadOne(bookId),
                              ),
                      ),
                  ]),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: Text(
                    synopsis.isNotEmpty ? synopsis : 'Pas de synopsis.',
                    style: TextStyle(color: AppTheme.t3, fontSize: 11, fontStyle: synopsis.isEmpty ? FontStyle.italic : FontStyle.normal),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: extra.isEmpty
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: extra.entries
                              .map((e) => Padding(
                                    padding: const EdgeInsets.only(bottom: 3),
                                    child: Text('${e.key} : ${e.value}', style: TextStyle(color: AppTheme.t3, fontSize: 9)),
                                  ))
                              .toList(),
                        ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _pushVolumesToServer() async {
    if (_nautVolumes == null || _nautVolumes!.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg,
        title: Text('Envoyer les tomes vers Komga ?', style: TextStyle(color: AppTheme.t1, fontSize: 15)),
        content: Text(
          'Le titre et le résumé de chaque tome Nautiljon vont être écrits sur le livre Komga du même numéro, puis verrouillés.',
          style: TextStyle(color: AppTheme.t2, fontSize: 12),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Envoyer')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _pushingVolumes = true);
    final (sent, unmatched) = await pushNautVolumesToKomga(context, books: _books, nautVolumes: _nautVolumes!);
    if (!mounted) return;
    setState(() => _pushingVolumes = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$sent tome(s) envoyé(s)${unmatched > 0 ? ', $unmatched sans correspondance' : ''}.'),
    ));
  }

  Future<void> _pushToServer() async {
    if (_details == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg,
        title: Text('Envoyer vers Komga ?', style: TextStyle(color: AppTheme.t1, fontSize: 15)),
        content: Text(
          'Le résumé, les genres, les thèmes, l\'éditeur et le statut de la fiche Nautiljon vont être écrits dans Komga, puis verrouillés pour ne pas être effacés par un futur scan. Le reste de la fiche série n\'est pas modifié.',
          style: TextStyle(color: AppTheme.t2, fontSize: 12),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Envoyer')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _pushing = true);
    final error = await pushNautiljonToKomga(context, seriesId: widget.seriesId, details: _details!);
    if (!mounted) return;
    setState(() => _pushing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error == null ? 'Infos envoyées vers Komga.' : 'Erreur : $error'),
      backgroundColor: error == null ? AppTheme.grn : AppTheme.ros,
    ));
  }

  Future<void> _refreshDownloaded() async {
    final ids = await context.read<AppState>().komgaDownloads.downloadedIds();
    if (mounted) setState(() => _downloadedIds = ids);
  }

  List<String> get _seriesTags {
    final genres = (_details?['genres'] ?? '').toString();
    final themes = (_details?['themes'] ?? '').toString();
    final tags = <String>[];
    for (final raw in [genres, themes]) {
      if (raw.isEmpty) continue;
      for (final t in raw.split(RegExp(r'\s*[-,]\s*'))) {
        final trimmed = t.trim();
        if (trimmed.isNotEmpty && !tags.contains(trimmed)) tags.add(trimmed);
      }
    }
    return tags;
  }

  void _toggleSelectMode() {
    setState(() { _selectMode = !_selectMode; _selected.clear(); });
  }

  void _toggleSelected(String bookId) {
    setState(() {
      if (_selected.contains(bookId)) { _selected.remove(bookId); } else { _selected.add(bookId); }
    });
  }

  Future<void> _downloadOne(String bookId) async {
    final item = _books.firstWhere((b) => b['id'] == bookId);
    await _runDownloads([item]);
  }

  Future<void> _downloadSelected() async {
    final items = _books.where((b) => _selected.contains(b['id'] as String)).toList();
    setState(() { _selectMode = false; _selected.clear(); });
    await _runDownloads(items);
  }

  Future<void> _runDownloads(List<Map<String, dynamic>> items) async {
    final kdl = context.read<AppState>().komgaDownloads;
    final toDownload = items.where((b) => !_downloadedIds.contains(b['id'] as String)).toList();
    if (toDownload.isEmpty) return;
    _downloadBusy = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => Consumer<AppState>(
        builder: (c2, state, _) {
          final active = toDownload
              .map((b) => b['id'] as String)
              .map((id) => state.komgaDownloads.activeDownloads[id])
              .whereType<KomgaDownloadInfo>()
              .toList();
          final finished = !_downloadBusy && active.isEmpty;
          return AlertDialog(
            backgroundColor: AppTheme.bg,
            title: Text(finished ? 'Téléchargement terminé' : 'Téléchargement…', style: TextStyle(color: AppTheme.t1, fontSize: 15)),
            content: SizedBox(
              width: 280,
              child: finished
                  ? Text('${toDownload.length} livre(s) traité(s).', style: TextStyle(color: AppTheme.t2, fontSize: 12))
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

    for (final book in toDownload) {
      final bookId = book['id'] as String;
      final label = komgaBookLabel(book);
      final pages = komgaPagesCount(book);
      try {
        await kdl.downloadBook(
          bookId: bookId,
          seriesId: widget.seriesId,
          seriesName: widget.seriesName,
          label: label,
          totalPages: pages,
        );
      } catch (_) {
        // KomgaDownloadInfo.hasError couvre déjà l'affichage -- on continue
        // avec les livres suivants de la sélection.
      }
    }
    _downloadBusy = false;
    await _refreshDownloaded();
    context.read<AppState>().notifyAllListeners(); // fait passer le dialogue de progression en "terminé"
  }

  @override
  Widget build(BuildContext context) {
    final naut = context.watch<AppState>().nautiljon;
    final match = naut.matchFor('komga', widget.seriesId);
    return Scaffold(
      backgroundColor: AppTheme.d,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        iconTheme: IconThemeData(color: AppTheme.t1),
        title: Text(widget.seriesName, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.t1, fontSize: 15)),
        actions: [
          // Sélection multiple : n'a d'effet que sur la grille "Livres",
          // masquée dès que les tomes Nautiljon sont chargés (voir plus
          // bas) -- inutile de la proposer dans ce cas.
          if (_books.isNotEmpty && (_nautVolumes == null || _nautVolumes!.isEmpty))
            IconButton(
              tooltip: _selectMode ? 'Annuler la sélection' : 'Télécharger plusieurs livres',
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
                  SizedBox(width: 90, height: 128, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _KomgaCover(seriesId: widget.seriesId))),
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
                                if ((_details?['artist'] ?? '').toString().isNotEmpty && _details!['artist'] != _details!['author'])
                                  Text('🖌️ ${_details!['artist']}', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
                                if ((_details?['publisher'] ?? '').toString().isNotEmpty)
                                  Text('🏢 ${_details!['publisher']}', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
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
                if (_seriesTags.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6, runSpacing: 6,
                    children: _seriesTags.map((tag) {
                      final color = MangaColors.tagColor(tag);
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
                        ),
                        child: Text(tag, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
                      );
                    }).toList(),
                  ),
                ],
                if ((_details?['synopsis'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(_details!['synopsis'].toString(), style: TextStyle(color: AppTheme.t2, fontSize: 12)),
                ],
                if (match != null && _details != null) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _pushing ? null : _pushToServer,
                    icon: _pushing
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cloud_upload_outlined, size: 16),
                    label: const Text('Envoyer les infos vers Komga'),
                  ),
                ],
                if (match != null) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _loadingNautVolumes ? null : _loadNautVolumes,
                    icon: _loadingNautVolumes
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.menu_book_outlined, size: 16),
                    label: Text(_nautVolumes == null ? 'Matcher les tomes Nautiljon' : 'Recharger les tomes Nautiljon'),
                  ),
                  if (_nautVolumesError != null)
                    Padding(padding: const EdgeInsets.only(top: 6), child: Text(_nautVolumesError!, style: TextStyle(color: AppTheme.ros, fontSize: 11))),
                  if (_nautVolumes != null) ...[
                    const SizedBox(height: 10),
                    if (_nautEditionName != null && _nautEditionName!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('Édition : ${_nautEditionName!}', style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
                      ),
                    if (_nautVolumes!.isEmpty)
                      Text('Aucun tome trouvé sur Nautiljon.', style: TextStyle(color: AppTheme.t3, fontSize: 12))
                    else ...[
                      OutlinedButton.icon(
                        onPressed: _pushingVolumes ? null : _pushVolumesToServer,
                        icon: _pushingVolumes
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.cloud_upload_outlined, size: 16),
                        label: const Text('Envoyer les tomes vers Komga'),
                      ),
                      const SizedBox(height: 10),
                      Column(children: _nautVolumes!.map(_nautVolumeCard).toList()),
                    ],
                  ],
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
                // La grille "Livres" (cover Komga + tap pour lire) fait
                // doublon avec les cartes de tomes Nautiljon juste
                // au-dessus dès qu'elles sont chargées (chacune a aussi sa
                // cover et ouvre le même livre au tap, voir
                // _nautVolumeCard) -- on ne l'affiche donc que tant
                // qu'aucun tome Nautiljon n'est disponible.
                if (_nautVolumes == null || _nautVolumes!.isEmpty) ...[
                  Text('Livres', style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontSize: 14)),
                  const SizedBox(height: 8),
                  if (_loading)
                    const Padding(padding: EdgeInsets.only(bottom: 20), child: Center(child: CircularProgressIndicator()))
                  else if (_books.isEmpty)
                    Padding(padding: const EdgeInsets.only(bottom: 20), child: Text('Aucun livre.', style: TextStyle(color: AppTheme.t3, fontSize: 12))),
                ],
              ]),
            ),
          ),
          // Sliver "paresseuse" -- voir la même remarque dans
          // kavita_screen.dart (chapitres) : certaines séries ont plusieurs
          // centaines de livres. Masquée dès que les tomes Nautiljon sont
          // chargés (voir plus haut) -- même liste, pas la peine de la
          // dupliquer.
          if (!_loading && _books.isNotEmpty && (_nautVolumes == null || _nautVolumes!.isEmpty))
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 100, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.6),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => _bookTile(ctx, i),
                  childCount: _books.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bookTile(BuildContext context, int i) {
    final book = _books[i];
    final bookId = book['id'] as String;
    final label = komgaBookLabel(book);
    final downloaded = _downloadedIds.contains(bookId);
    final selected = _selected.contains(bookId);
    return GestureDetector(
      onTap: () {
        if (_selectMode) { _toggleSelected(bookId); return; }
        openKomgaBook(context, seriesId: widget.seriesId, seriesName: widget.seriesName, bookId: bookId, totalPages: komgaPagesCount(book));
      },
      onLongPress: () {
        if (!_selectMode) setState(() => _selectMode = true);
        _toggleSelected(bookId);
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(6), child: _KomgaBookCover(bookId: bookId))),
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
                  onPressed: () => _downloadOne(bookId),
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

class KomgaReviewQueueScreen extends StatefulWidget {
  final List<KavitaMatchSuggestion> queue;
  const KomgaReviewQueueScreen({super.key, required this.queue});
  @override
  State<KomgaReviewQueueScreen> createState() => _KomgaReviewQueueScreenState();
}

class _KomgaReviewQueueScreenState extends State<KomgaReviewQueueScreen> {
  int _index = 0;
  bool _busy = false;

  Future<void> _accept(KavitaMatchCandidate c) async {
    setState(() => _busy = true);
    await context.read<AppState>().nautiljon.saveMatch(
        source: widget.queue[_index].source, seriesId: widget.queue[_index].seriesId,
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
          : CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(
                          width: 70, height: 100,
                          child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _KomgaCover(key: ValueKey('rev_${item.seriesId}'), seriesId: item.seriesId)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(item.seriesName, style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontSize: 16)),
                            const SizedBox(height: 4),
                            Text('Série Komga', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
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

class KomgaMatchAllScreen extends StatefulWidget {
  final List<Map<String, dynamic>> seriesList;
  const KomgaMatchAllScreen({super.key, required this.seriesList});
  @override
  State<KomgaMatchAllScreen> createState() => _KomgaMatchAllScreenState();
}

class _KomgaMatchAllScreenState extends State<KomgaMatchAllScreen> {
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
    _ctrl.text = komgaSeriesTitle(widget.seriesList[_index]);
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
    final sid = widget.seriesList[_index]['id'] as String;
    await context.read<AppState>().nautiljon.saveMatch(
        source: 'komga', seriesId: sid,
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
    final sid = s['id'] as String;
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
              child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _KomgaCover(key: ValueKey('mall_$sid'), seriesId: sid)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(komgaSeriesTitle(s), style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontSize: 16))),
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

// ── Gestion des livres Komga téléchargés (hors-ligne) ──

class KomgaDownloadsScreen extends StatefulWidget {
  const KomgaDownloadsScreen({super.key});
  @override
  State<KomgaDownloadsScreen> createState() => _KomgaDownloadsScreenState();
}

class _KomgaDownloadsScreenState extends State<KomgaDownloadsScreen> {
  List<Map<String, dynamic>> _items = [];
  int _totalSize = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final kdl = context.read<AppState>().komgaDownloads;
    final items = await kdl.listDownloads();
    final size = await kdl.totalSize();
    if (mounted) setState(() { _items = items; _totalSize = size; _loading = false; });
  }

  Future<void> _delete(String bookId) async {
    await context.read<AppState>().komgaDownloads.deleteBook(bookId);
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
        title: Text('Téléchargements Komga', style: TextStyle(color: AppTheme.t1, fontSize: 15)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('${_items.length} livre(s) · ${_formatSize(_totalSize)}', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
                ),
                Consumer<AppState>(
                  builder: (ctx, state, _) {
                    final active = state.komgaDownloads.activeDownloads.values.toList();
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
                      ? Center(child: Text('Aucun livre Komga téléchargé.', style: TextStyle(color: AppTheme.t3)))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            padding: const EdgeInsets.all(8),
                            itemCount: _items.length,
                            itemBuilder: (ctx, i) {
                              final it = _items[i];
                              final bookId = it['bookId'] as String;
                              return Container(
                                margin: const EdgeInsets.only(bottom: 4),
                                decoration: BoxDecoration(color: AppTheme.c1, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.brd, width: 0.5)),
                                child: ListTile(
                                  leading: Icon(Icons.download_done, color: AppTheme.grn, size: 24),
                                  title: Text(it['seriesName']?.toString() ?? '?', style: TextStyle(color: AppTheme.t1, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text('${it['label'] ?? ''} · ${_formatSize((it['sizeBytes'] as num? ?? 0).toInt())}', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
                                  trailing: IconButton(icon: Icon(Icons.delete_outline, color: AppTheme.ros, size: 20), onPressed: () => _delete(bookId)),
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
