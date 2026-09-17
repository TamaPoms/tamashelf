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

  const ReaderScreen({
    super.key,
    required this.title,
    required this.volume,
    this.localPath,
    this.online = false,
    this.onlineTotalPages,
    this.startPage = 0,
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
  bool _rtl = false;
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

  bool get _isOnline => widget.online && widget.localPath == null;

  @override
  void initState() {
    super.initState();
    _enterFullscreen();
    _loadPages();
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
      if (_totalPages == 0) {
        // Fetch info from server
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

    // Restore saved position
    final saved = state.progress.getProgress(widget.volume.cbzFolder, widget.volume.filepath);
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
    setState(() => _currentPage = p);
    _saveProgress();
    if (_isOnline) _preloadNearby();
  }

  void _saveProgress() {
    if (_totalPages == 0) return;
    final state = context.read<AppState>();
    state.progress.updateProgress(
      mangaUrl: widget.volume.cbzFolder,
      volumeId: widget.volume.filepath,
      currentPage: _currentPage,
      totalPages: _totalPages,
      title: widget.title,
    );
  }

  void _nextPage() {
    if (_currentPage >= _totalPages - 1 && _nextVolume != null) {
      _proposeNextVolume();
      return;
    }
    _goToPage(_currentPage + (_doublePage ? 2 : 1));
  }
  void _prevPage() => _goToPage(_currentPage - (_doublePage ? 2 : 1));

  Future<void> _findNextVolume() async {
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
                      onPressed: () => setState(() { _webtoon = !_webtoon; _doublePage = false; }),
                    ),
                    if (!_webtoon)
                      IconButton(
                        icon: Icon(_doublePage ? Icons.chrome_reader_mode : Icons.chrome_reader_mode_outlined, color: _doublePage ? AppTheme.ac : Colors.white70, size: 20),
                        onPressed: () => setState(() => _doublePage = !_doublePage),
                        tooltip: 'Double page',
                      ),
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
    if (_isOnline) return _buildOnlinePage(_currentPage);
    return Image.file(
      File(_localPages[_currentPage]),
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
    );
  }

  Widget _buildDoublePageView() {
    final leftPage = _currentPage;
    final rightPage = _currentPage + 1 < _totalPages ? _currentPage + 1 : null;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          child: _isOnline
              ? _buildOnlinePage(leftPage)
              : Image.file(File(_localPages[leftPage]), fit: BoxFit.contain),
        ),
        if (rightPage != null)
          Expanded(
            child: _isOnline
                ? _buildOnlinePage(rightPage)
                : Image.file(File(_localPages[rightPage]), fit: BoxFit.contain),
          ),
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

  Widget _buildOnlinePage(int page) {
    final cached = _onlineCache[page];
    if (cached != null) {
      return Center(
        child: Image.memory(
          cached,
          fit: BoxFit.contain,
          width: double.infinity,
          height: double.infinity,
        ),
      );
    }

    // Loading
    return FutureBuilder<Uint8List?>(
      future: _loadOnlinePage(page),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppTheme.ac),
                SizedBox(height: 12),
                Text('Chargement...', style: TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          );
        }
        if (snap.hasData && snap.data != null) {
          return Center(
            child: Image.memory(
              snap.data!,
              fit: BoxFit.contain,
              width: double.infinity,
              height: double.infinity,
            ),
          );
        }
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off, color: Colors.white38, size: 48),
              SizedBox(height: 8),
              Text('Impossible de charger', style: TextStyle(color: Colors.white38)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWebtoon() {
    if (_isOnline) {
      return ListView.builder(
        controller: _scrollCtrl,
        itemCount: _totalPages,
        itemBuilder: (ctx, i) => _buildOnlineWebtoonPage(i),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      itemCount: _localPages.length,
      itemBuilder: (ctx, i) => Image.file(
        File(_localPages[i]),
        fit: BoxFit.fitWidth,
        width: double.infinity,
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
