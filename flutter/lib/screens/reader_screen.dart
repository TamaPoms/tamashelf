import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../app_state.dart';
import '../models/manga.dart';
import '../theme.dart';

class ReaderScreen extends StatefulWidget {
  final String title;
  final Volume volume;
  // Local mode
  final String? localPath;
  // Online mode
  final bool online;
  final int? onlineTotalPages;
  // Resume position
  final int startPage;
  // Source de pages alternative pour un mode "online" qui n'est pas la
  // bibliothèque CBZ du serveur TamaShelf (ex: Kavita, voir kavita_screen.dart) --
  // si fourni, remplace l'appel /api/cbz/read/... normalement utilisé en ligne.
  final Future<Uint8List?> Function(int page)? onlinePageLoader;
  // Clés de progression à utiliser à la place de volume.cbzFolder/filepath
  // (mêmes besoins : une source hors bibliothèque locale a ses propres clés).
  final String? progressMangaUrl;
  final String? progressVolumeId;
  // La proposition "tome suivant" s'appuie sur state.db.getVolumes (bibliothèque
  // locale) -- sans objet hors CBZ local.
  final bool enableNextVolume;

  const ReaderScreen({
    super.key,
    required this.title,
    required this.volume,
    this.localPath,
    this.online = false,
    this.onlineTotalPages,
    this.startPage = 0,
    this.onlinePageLoader,
    this.progressMangaUrl,
    this.progressVolumeId,
    this.enableNextVolume = true,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  // Local pages
  List<String> _localPages = [];
  // Online cache
  final Map<int, Uint8List> _onlineCache = {};
  
  int _totalPages = 0;
  int _currentPage = 0;
  bool _loading = true;
  bool _barVisible = false;
  bool _rtl = true; // manga : lecture droite → gauche par défaut
  bool _webtoon = false;
  bool _doublePage = false;
  bool _showThumbnails = false;
  bool _pageLoading = false;
  final ScrollController _scrollCtrl = ScrollController();
  final ScrollController _thumbScrollCtrl = ScrollController();
  final FocusNode _focusNode = FocusNode();
  final TransformationController _zoomCtrl = TransformationController();
  StreamSubscription? _volumeKeySub;
  static const _volumeChannel = EventChannel('fr.mangashelf/volume_keys');
  // Next volume for auto-advance
  List<Volume>? _allVolumes;
  Volume? _nextVolume;
  // Webtoon: une clé par page pour retrouver sa position à l'écran pendant
  // le scroll (pour suivre la page courante et détecter la fin du tome).
  List<GlobalKey> _webtoonKeys = [];
  bool _webtoonScrollUpdateScheduled = false;
  bool _nextVolumePromptShown = false;
  // Mode page à page : option pour scinder une planche double (scannée en
  // une seule image large) en deux pages successives.
  bool _splitWide = false;
  int _subPage = 0; // 0 = première moitié, 1 = seconde (page large + option active seulement)
  final Map<int, Size> _pageSizes = {}; // dimensions naturelles des pages déjà résolues
  // Une seule tentative de détection auto du mode webtoon par ouverture du
  // lecteur (voir _maybeAutoEnableWebtoon).
  bool _autoWebtoonChecked = false;

  bool get _isOnline => widget.online && widget.localPath == null;

  @override
  void initState() {
    super.initState();
    _enterFullscreen();
    _loadPages();
    _scrollCtrl.addListener(_onWebtoonScroll);
    _barVisible = true;
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _barVisible = false);
    });
    // Listen to native volume key events
    _volumeKeySub = _volumeChannel.receiveBroadcastStream().listen((event) {
      if (event == 'volume_down') {
        if (_webtoon) {
          _scrollCtrl.animateTo(
            _scrollCtrl.offset + MediaQuery.of(context).size.height * 0.85,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        } else {
          _nextPage();
        }
      } else if (event == 'volume_up') {
        if (_webtoon) {
          _scrollCtrl.animateTo(
            (_scrollCtrl.offset - MediaQuery.of(context).size.height * 0.85).clamp(0, double.infinity),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        } else {
          _prevPage();
        }
      }
    }, onError: (e) {
      print('Volume key stream error: $e');
    });
  }

  void _enterFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    WakelockPlus.enable();
  }

  void _exitFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.disable();
  }

  Future<void> _loadPages() async {
    final state = context.read<AppState>();

    if (_isOnline) {
      // Online: get total pages from server or volume data
      _totalPages = widget.onlineTotalPages ?? widget.volume.totalPages;
      if (_totalPages == 0 && widget.onlinePageLoader == null) {
        // Fetch info from server (bibliothèque CBZ TamaShelf uniquement --
        // une source alternative avec onlinePageLoader fournit déjà onlineTotalPages)
        try {
          final resp = await http.get(
            Uri.parse('${state.db.serverUrl}/api/cbz/info/${widget.volume.filepath}'),
            headers: state.db.authHeaders,
          ).timeout(const Duration(seconds: 10));
          if (resp.statusCode == 200) {
            final data = resp.body;
            final match = RegExp(r'"total_pages"\s*:\s*(\d+)').firstMatch(data);
            if (match != null) _totalPages = int.parse(match.group(1)!);
          }
        } catch (e) {
          print('Online info error: $e');
        }
      }
      // Preload first page
      await _loadOnlinePage(widget.startPage);
    } else {
      // Local: extract pages from CBZ
      final pages = await state.downloads.extractPages(widget.localPath!);
      _localPages = pages;
      _totalPages = pages.length;
    }

    _webtoonKeys = List.generate(_totalPages, (_) => GlobalKey());

    // Restore saved position
    final saved = state.progress.getProgress(
      widget.progressMangaUrl ?? widget.volume.cbzFolder,
      widget.progressVolumeId ?? widget.volume.filepath,
    );
    final startPage = widget.startPage > 0
        ? widget.startPage
        : (saved != null && saved.currentPage < _totalPages) ? saved.currentPage : 0;

    if (mounted) setState(() { _loading = false; _currentPage = startPage; });
    _focusNode.requestFocus();

    // Preload nearby pages for online
    if (_isOnline) _preloadNearby();

    // Find next volume for auto-advance
    _findNextVolume();
  }

  Future<Uint8List?> _loadOnlinePage(int page) async {
    if (_onlineCache.containsKey(page)) return _onlineCache[page];
    if (widget.onlinePageLoader != null) {
      try {
        final bytes = await widget.onlinePageLoader!(page);
        if (bytes != null) _onlineCache[page] = bytes;
        return bytes;
      } catch (e) {
        print('Load page $page error: $e');
        return null;
      }
    }
    final state = context.read<AppState>();
    try {
      final url = '${state.db.serverUrl}/api/cbz/read/${widget.volume.filepath}?page=$page';
      final resp = await http.get(
        Uri.parse(url),
        headers: state.db.authHeaders,
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        _onlineCache[page] = resp.bodyBytes;
        return resp.bodyBytes;
      }
    } catch (e) {
      print('Load page $page error: $e');
    }
    return null;
  }

  void _preloadNearby() {
    // Preload 2 pages ahead
    for (int i = 1; i <= 2; i++) {
      final next = _currentPage + i;
      if (next < _totalPages && !_onlineCache.containsKey(next)) {
        _loadOnlinePage(next);
      }
    }
  }

  void _goToPage(int page) {
    final p = page.clamp(0, _totalPages - 1);
    if (p == _currentPage) return;
    _zoomCtrl.value = Matrix4.identity();
    setState(() { _currentPage = p; _subPage = 0; });
    _saveProgress();
    if (_isOnline) _preloadNearby();
  }

  void _saveProgress() {
    if (_totalPages == 0) return;
    final state = context.read<AppState>();
    state.progress.updateProgress(
      mangaUrl: widget.progressMangaUrl ?? widget.volume.cbzFolder,
      volumeId: widget.progressVolumeId ?? widget.volume.filepath,
      currentPage: _currentPage,
      totalPages: _totalPages,
      title: widget.title,
    );
  }

  bool get _splitActive => !_doublePage && _splitWide;

  void _nextPage() {
    if (_splitActive && _isWidePage(_currentPage) && _subPage == 0) {
      setState(() => _subPage = 1);
      return;
    }
    if (_currentPage >= _totalPages - 1 && _nextVolume != null) {
      _proposeNextVolume();
      return;
    }
    _goToPage(_currentPage + (_doublePage ? 2 : 1));
  }

  void _prevPage() {
    if (_splitActive && _isWidePage(_currentPage) && _subPage == 1) {
      setState(() => _subPage = 0);
      return;
    }
    final target = (_currentPage - (_doublePage ? 2 : 1)).clamp(0, _totalPages - 1);
    final changed = target != _currentPage;
    _goToPage(target);
    // En revenant en arrière sur une planche double, on arrive par sa
    // seconde moitié (celle qui touche la page suivante).
    if (changed && _splitActive && _isWidePage(target)) {
      setState(() => _subPage = 1);
    }
  }

  // Une page est "large" (probable planche double scannée en une image)
  // quand ses dimensions naturelles, une fois connues, ont un ratio
  // largeur/hauteur nettement supérieur à celui d'une page simple.
  bool _isWidePage(int page) {
    final size = _pageSizes[page];
    if (size == null) return false;
    return size.width > size.height * 1.2;
  }

  // Résout et mémorise les dimensions naturelles d'une page (une fois) pour
  // savoir si elle est "large" ; sans effet si déjà connue ou pas encore
  // disponible (page en ligne pas encore chargée).
  void _ensurePageSize(int page) {
    if (_pageSizes.containsKey(page)) return;
    final ImageProvider provider;
    if (_isOnline) {
      final bytes = _onlineCache[page];
      if (bytes == null) return;
      provider = MemoryImage(bytes);
    } else {
      if (page < 0 || page >= _localPages.length) return;
      provider = FileImage(File(_localPages[page]));
    }
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      if (!mounted) return;
      final size = Size(info.image.width.toDouble(), info.image.height.toDouble());
      setState(() => _pageSizes[page] = size);
      _maybeAutoEnableWebtoon(page, size);
    }, onError: (error, stack) {
      stream.removeListener(listener);
    });
    stream.addListener(listener);
  }

  // Aucune métadonnée de mode de lecture côté Android (contrairement au
  // site) : une fois la page affichée connue, si elle est bien plus haute
  // que large (planche webtoon en bande verticale plutôt qu'une page de
  // manga classique), on bascule automatiquement en mode défilement. Une
  // seule tentative par ouverture du lecteur.
  void _maybeAutoEnableWebtoon(int page, Size size) {
    if (_autoWebtoonChecked || _webtoon || page != _currentPage) return;
    _autoWebtoonChecked = true;
    if (size.height > size.width * 2.5) {
      setState(() => _webtoon = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onWebtoonScroll());
    }
  }

  // En mode webtoon, la page "courante" ne change pas via _goToPage/_nextPage
  // (pas de tap/swipe de page à page) : on la déduit du scroll, en retrouvant
  // quelle page est affichée en haut de l'écran, et on détecte la fin du
  // tome pour proposer le suivant — jetée au frame suivant (throttle façon
  // requestAnimationFrame) pour ne pas recalculer à chaque pixel scrollé.
  void _onWebtoonScroll() {
    if (!_webtoon || !_scrollCtrl.hasClients || _webtoonScrollUpdateScheduled) return;
    _webtoonScrollUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _webtoonScrollUpdateScheduled = false;
      if (!mounted || !_webtoon) return;
      _updateCurrentPageFromScroll();
      _checkWebtoonEnd();
    });
  }

  void _updateCurrentPageFromScroll() {
    if (_webtoonKeys.isEmpty) return;
    const topThreshold = 100.0;
    int? bestIdx;
    double bestDist = double.infinity;
    for (var i = 0; i < _webtoonKeys.length; i++) {
      final renderObject = _webtoonKeys[i].currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) continue;
      final top = renderObject.localToGlobal(Offset.zero).dy;
      final dist = (top - topThreshold).abs();
      if (dist < bestDist) { bestDist = dist; bestIdx = i; }
    }
    if (bestIdx != null && bestIdx != _currentPage) {
      setState(() => _currentPage = bestIdx!);
      _saveProgress();
      if (_isOnline) _preloadNearby();
    }
  }

  void _checkWebtoonEnd() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    final atBottom = pos.maxScrollExtent <= 0 || pos.pixels >= pos.maxScrollExtent - 40;
    if (!atBottom) {
      _nextVolumePromptShown = false;
      return;
    }
    if (!_nextVolumePromptShown && _nextVolume != null) {
      _nextVolumePromptShown = true;
      _proposeNextVolume();
    }
  }

  Future<void> _findNextVolume() async {
    if (!widget.enableNextVolume) return;
    try {
      final state = context.read<AppState>();
      final volumes = await state.db.getVolumes(widget.volume.cbzFolder);
      _allVolumes = volumes;
      final currentNum = widget.volume.volumeNum;
      if (currentNum == null) return;
      for (final v in volumes) {
        if (v.volumeNum != null && v.volumeNum! > currentNum && v.volumeType == widget.volume.volumeType) {
          _nextVolume = v;
          break;
        }
      }
    } catch (_) {}
  }

  Future<void> _proposeNextVolume() async {
    if (_nextVolume == null || !mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg,
        title: Text('Fin du volume', style: TextStyle(color: AppTheme.t1, fontSize: 16)),
        content: Text('Lire ${_nextVolume!.displayName} ?', style: TextStyle(color: AppTheme.t2)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'close'),
            child: Text('Fermer', style: TextStyle(color: AppTheme.t3)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'next'),
            icon: const Icon(Icons.skip_next, size: 16),
            label: Text(_nextVolume!.displayName),
          ),
        ],
      ),
    );
    if (choice == 'next' && mounted) {
      _saveProgress();
      final state = context.read<AppState>();
      final localPath = await state.downloads.getLocalPath(_nextVolume!);
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(
        builder: (_) => ReaderScreen(
          title: widget.title.replaceFirst(widget.volume.displayName, _nextVolume!.displayName),
          volume: _nextVolume!,
          localPath: localPath,
          online: localPath == null,
        ),
      ));
    } else if (choice == 'close' && mounted) {
      _finish();
    }
  }

  void _handleTap(TapUpDetails details) {
    final w = MediaQuery.of(context).size.width;
    final h = MediaQuery.of(context).size.height;
    final x = details.globalPosition.dx / w;
    final y = details.globalPosition.dy / h;

    if (x > 0.25 && x < 0.75 && y > 0.2 && y < 0.8) {
      setState(() => _barVisible = !_barVisible);
      return;
    }

    if (_webtoon) return;

    if (x <= 0.25) {
      _rtl ? _nextPage() : _prevPage();
    } else if (x >= 0.75) {
      _rtl ? _prevPage() : _nextPage();
    }
  }

  double? _swipeStartX;

  void _handleHorizontalDragStart(DragStartDetails d) {
    _swipeStartX = d.globalPosition.dx;
  }

  void _handleHorizontalDragEnd(DragEndDetails d) {
    if (_swipeStartX == null || _webtoon) return;
    final dx = d.velocity.pixelsPerSecond.dx;
    if (dx.abs() < 100) return;

    if (dx < 0) {
      _rtl ? _prevPage() : _nextPage();
    } else {
      _rtl ? _nextPage() : _prevPage();
    }
    _swipeStartX = null;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;

    // Volume keys on Android: use physicalKey
    final isVolDown = event.logicalKey == LogicalKeyboardKey.audioVolumeDown ||
        event.physicalKey == PhysicalKeyboardKey.audioVolumeDown;
    final isVolUp = event.logicalKey == LogicalKeyboardKey.audioVolumeUp ||
        event.physicalKey == PhysicalKeyboardKey.audioVolumeUp;

    if (isVolDown) {
      if (_webtoon) {
        _scrollCtrl.animateTo(
          _scrollCtrl.offset + MediaQuery.of(context).size.height * 0.85,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        _nextPage();
      }
      return KeyEventResult.handled;
    }
    if (isVolUp) {
      if (_webtoon) {
        _scrollCtrl.animateTo(
          (_scrollCtrl.offset - MediaQuery.of(context).size.height * 0.85).clamp(0, double.infinity),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        _prevPage();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _finish() async {
    _saveProgress();
    _exitFullscreen();
    if (!mounted) return;

    // Only propose delete if local file
    if (!_isOnline && widget.localPath != null) {
      final delete = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.bg,
          title: Text('Lecture terminee', style: TextStyle(color: AppTheme.t1)),
          content: Text('Supprimer le fichier telecharge ?', style: TextStyle(color: AppTheme.t2)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Garder', style: TextStyle(color: AppTheme.t3)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.ros),
              child: const Text('Supprimer'),
            ),
          ],
        ),
      );
      if (mounted) Navigator.pop(context, delete ?? false);
    } else {
      if (mounted) Navigator.pop(context, false);
    }
  }

  @override
  void dispose() {
    _saveProgress();
    _volumeKeySub?.cancel();
    _exitFullscreen();
    _scrollCtrl.removeListener(_onWebtoonScroll);
    _scrollCtrl.dispose();
    _thumbScrollCtrl.dispose();
    _zoomCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Reader content
            GestureDetector(
              onTapUp: _handleTap,
              onHorizontalDragStart: _webtoon ? null : _handleHorizontalDragStart,
              onHorizontalDragEnd: _webtoon ? null : _handleHorizontalDragEnd,
              child: _webtoon ? _buildWebtoon() : _buildPaged(),
            ),

            // Top bar
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              top: _barVisible ? 0 : -120,
              left: 0, right: 0,
              child: Container(
                padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
                decoration: const BoxDecoration(color: Color(0xDD000000)),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white, size: 22),
                      onPressed: _finish,
                    ),
                    Expanded(
                      child: Text(widget.title,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis),
                    ),
                    // Online indicator
                    if (_isOnline)
                      Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.cyn,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('EN LIGNE', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700)),
                      ),
                    Text('${_currentPage + 1}/$_totalPages',
                      style: const TextStyle(color: Colors.white60, fontSize: 12, fontFamily: 'monospace')),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(_webtoon ? Icons.view_agenda : Icons.view_day, color: Colors.white70, size: 20),
                      onPressed: () => setState(() {
                        _webtoon = !_webtoon;
                        _doublePage = false;
                        _subPage = 0;
                        _nextVolumePromptShown = false;
                        if (_webtoon) {
                          WidgetsBinding.instance.addPostFrameCallback((_) => _onWebtoonScroll());
                        }
                      }),
                    ),
                    if (!_webtoon) ...[
                      IconButton(
                        icon: Icon(_doublePage ? Icons.chrome_reader_mode : Icons.chrome_reader_mode_outlined, color: _doublePage ? AppTheme.ac : Colors.white70, size: 20),
                        onPressed: () => setState(() { _doublePage = !_doublePage; _subPage = 0; }),
                        tooltip: 'Double page',
                      ),
                      if (!_doublePage)
                        IconButton(
                          icon: Icon(_splitWide ? Icons.splitscreen : Icons.splitscreen_outlined, color: _splitWide ? AppTheme.ac : Colors.white70, size: 20),
                          onPressed: () => setState(() { _splitWide = !_splitWide; _subPage = 0; }),
                          tooltip: 'Scinder les planches doubles',
                        ),
                    ],
                    IconButton(
                      icon: Icon(_rtl ? Icons.arrow_back : Icons.arrow_forward, color: Colors.white70, size: 20),
                      onPressed: () => setState(() => _rtl = !_rtl),
                    ),
                    IconButton(
                      icon: Icon(Icons.zoom_in, color: Colors.white70, size: 20),
                      onPressed: () => _zoomCtrl.value = Matrix4.identity(),
                      tooltip: 'Reset zoom',
                    ),
                    IconButton(
                      icon: Icon(_showThumbnails ? Icons.view_comfy : Icons.view_comfy_outlined,
                        color: _showThumbnails ? AppTheme.ac : Colors.white70, size: 20),
                      onPressed: () => setState(() => _showThumbnails = !_showThumbnails),
                      tooltip: 'Miniatures',
                    ),
                  ],
                ),
              ),
            ),

            // Bottom bar
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              bottom: _barVisible ? 0 : -140,
              left: 0, right: 0,
              child: Container(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 8,
                  left: 16, right: 16, top: 8,
                ),
                color: const Color(0xDD000000),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        trackHeight: 3,
                        activeTrackColor: AppTheme.ac,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: AppTheme.ac,
                      ),
                      child: Slider(
                        value: _currentPage.toDouble(),
                        min: 0,
                        max: (_totalPages - 1).toDouble().clamp(0, double.infinity),
                        onChanged: (v) => _goToPage(v.round()),
                      ),
                    ),
                    Text(
                      'Page ${_currentPage + 1} / $_totalPages${_doublePage && _currentPage + 1 < _totalPages ? " - ${_currentPage + 2}" : ""}',
                      style: const TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    if (_nextVolume != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Suivant : ${_nextVolume!.displayName}',
                          style: TextStyle(color: AppTheme.ac.withValues(alpha: 0.7), fontSize: 10),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Thumbnails strip
            if (_showThumbnails && _barVisible)
              Positioned(
                bottom: MediaQuery.of(context).padding.bottom + 100,
                left: 0, right: 0,
                child: Container(
                  height: 80,
                  color: const Color(0xDD000000),
                  child: ListView.builder(
                    controller: _thumbScrollCtrl,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: _totalPages,
                    itemBuilder: (ctx, i) {
                      final isActive = i == _currentPage;
                      return GestureDetector(
                        onTap: () => _goToPage(i),
                        child: Container(
                          width: 48,
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: isActive ? AppTheme.ac : Colors.white24,
                              width: isActive ? 2 : 0.5,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: _buildThumbnail(i),
                              ),
                              Positioned(
                                bottom: 0, left: 0, right: 0,
                                child: Container(
                                  color: Colors.black54,
                                  padding: const EdgeInsets.symmetric(vertical: 1),
                                  child: Text(
                                    '${i + 1}',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white70, fontSize: 8),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaged() {
    if (_totalPages == 0) return Center(child: Text('Aucune page', style: TextStyle(color: Colors.white54)));

    return InteractiveViewer(
      transformationController: _zoomCtrl,
      minScale: 1.0,
      maxScale: 4.0,
      child: Center(
        child: _doublePage ? _buildDoublePageView() : _buildSinglePageView(),
      ),
    );
  }

  Widget _buildSinglePageView() {
    _ensurePageSize(_currentPage); // asynchrone, met à jour _pageSizes et redéclenche un build

    final wide = _splitActive && _isWidePage(_currentPage);
    if (!wide) {
      if (_isOnline) return _buildOnlinePage(_currentPage);
      return Image.file(
        File(_localPages[_currentPage]),
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
      );
    }

    // Planche double : l'image occupe toute la hauteur disponible à sa
    // taille naturelle (pas de width:infinity ici, Align a besoin de
    // mesurer sa largeur réelle pour n'en garder que la moitié).
    final height = MediaQuery.of(context).size.height;
    final image = _isOnline
        ? _buildOnlinePage(_currentPage, naturalHeight: height)
        : Image.file(File(_localPages[_currentPage]), fit: BoxFit.contain, height: height);
    // _subPage suit l'ordre de LECTURE (0 = première moitié lue, 1 = seconde),
    // indépendant de l'écran : en RTL on lit la moitié droite en premier.
    final showLeftHalf = _rtl ? _subPage == 1 : _subPage == 0;
    return ClipRect(
      child: Align(
        alignment: showLeftHalf ? Alignment.centerLeft : Alignment.centerRight,
        widthFactor: 0.5,
        child: image,
      ),
    );
  }

  Widget _buildDoublePageView() {
    final leftPage = _currentPage;
    final rightPage = _currentPage + 1 < _totalPages ? _currentPage + 1 : null;
    Widget pageWidget(int page) => _isOnline
        ? _buildOnlinePage(page)
        : Image.file(File(_localPages[page]), fit: BoxFit.contain);

    // En RTL (manga), la page la plus ancienne (celle qu'on vient d'atteindre)
    // se lit en premier donc à droite : on inverse l'ordre d'affichage.
    final int showFirst;
    final int? showSecond;
    if (_rtl && rightPage != null) {
      showFirst = rightPage;
      showSecond = leftPage;
    } else {
      showFirst = leftPage;
      showSecond = rightPage;
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(child: pageWidget(showFirst)),
        if (showSecond != null) Expanded(child: pageWidget(showSecond)),
      ],
    );
  }

  Widget _buildThumbnail(int page) {
    if (_isOnline) {
      final cached = _onlineCache[page];
      if (cached != null) {
        return Image.memory(cached, fit: BoxFit.cover);
      }
      return Center(child: Text('${page + 1}', style: const TextStyle(color: Colors.white38, fontSize: 10)));
    }
    if (page < _localPages.length) {
      return Image.file(File(_localPages[page]), fit: BoxFit.cover);
    }
    return Center(child: Text('${page + 1}', style: const TextStyle(color: Colors.white38, fontSize: 10)));
  }

  // `naturalHeight` : rendu utilisé pour le découpage en demi-planche
  // (_buildSinglePageView + Align/widthFactor), qui a besoin de connaître la
  // largeur réellement occupée par l'image plutôt qu'un `width: infinity`
  // qui remplirait tout l'espace disponible sans rien laisser à mesurer.
  Widget _buildOnlinePage(int page, {double? naturalHeight}) {
    final cached = _onlineCache[page];
    if (cached != null) {
      final image = Image.memory(
        cached,
        fit: BoxFit.contain,
        width: naturalHeight == null ? double.infinity : null,
        height: naturalHeight ?? double.infinity,
      );
      return naturalHeight != null ? image : Center(child: image);
    }

    // Loading
    return FutureBuilder<Uint8List?>(
      future: _loadOnlinePage(page),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          final placeholder = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppTheme.ac),
              SizedBox(height: 12),
              Text('Chargement...', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          );
          return naturalHeight != null
              ? SizedBox(height: naturalHeight, child: Center(child: placeholder))
              : Center(child: placeholder);
        }
        if (snap.hasData && snap.data != null) {
          final image = Image.memory(
            snap.data!,
            fit: BoxFit.contain,
            width: naturalHeight == null ? double.infinity : null,
            height: naturalHeight ?? double.infinity,
          );
          return naturalHeight != null ? image : Center(child: image);
        }
        final placeholder = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off, color: Colors.white38, size: 48),
            SizedBox(height: 8),
            Text('Impossible de charger', style: TextStyle(color: Colors.white38)),
          ],
        );
        return naturalHeight != null
            ? SizedBox(height: naturalHeight, child: Center(child: placeholder))
            : Center(child: placeholder);
      },
    );
  }

  Widget _buildWebtoon() {
    if (_isOnline) {
      return ListView.builder(
        controller: _scrollCtrl,
        itemCount: _totalPages,
        itemBuilder: (ctx, i) => KeyedSubtree(
          key: _webtoonKeys[i],
          child: _buildOnlineWebtoonPage(i),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      itemCount: _localPages.length,
      itemBuilder: (ctx, i) => KeyedSubtree(
        key: _webtoonKeys[i],
        child: Image.file(
          File(_localPages[i]),
          fit: BoxFit.fitWidth,
          width: double.infinity,
        ),
      ),
    );
  }

  // Unlike _buildOnlinePage, a ListView item has unbounded height along the
  // scroll axis, so `height: double.infinity` (used there) breaks layout
  // and renders as a black page — placeholders here use a fixed height instead.
  Widget _buildOnlineWebtoonPage(int page) {
    final cached = _onlineCache[page];
    if (cached != null) {
      return Image.memory(
        cached,
        fit: BoxFit.fitWidth,
        width: double.infinity,
      );
    }

    return FutureBuilder<Uint8List?>(
      future: _loadOnlinePage(page),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return SizedBox(
            height: 200,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppTheme.ac),
                  SizedBox(height: 12),
                  Text('Chargement...', style: TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
          );
        }
        if (snap.hasData && snap.data != null) {
          return Image.memory(
            snap.data!,
            fit: BoxFit.fitWidth,
            width: double.infinity,
          );
        }
        return SizedBox(
          height: 200,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi_off, color: Colors.white38, size: 48),
                SizedBox(height: 8),
                Text('Impossible de charger', style: TextStyle(color: Colors.white38)),
              ],
            ),
          ),
        );
      },
    );
  }
}
