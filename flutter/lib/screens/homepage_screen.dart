import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../theme.dart';
import '../models/manga.dart';
import 'manga_detail_screen.dart';
import 'reader_screen.dart';

class HomepageScreen extends StatefulWidget {
  const HomepageScreen({super.key});

  @override
  State<HomepageScreen> createState() => _HomepageScreenState();
}

class _HomepageScreenState extends State<HomepageScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final data = await state.db.getHomepage();
    if (mounted) setState(() { _data = data; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (ctx, state, _) => Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: AppTheme.bg,
            child: Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(color: AppTheme.ac, borderRadius: BorderRadius.circular(8)),
                  child: Center(child: Text('鬼', style: TextStyle(fontSize: 20, color: AppTheme.d, fontWeight: FontWeight.w800))),
                ),
                const SizedBox(width: 10),
                Text('TamaShelf', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.t1)),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.refresh, color: AppTheme.t2, size: 22),
                  onPressed: () { setState(() => _loading = true); _load(); },
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: AppTheme.ac))
                : _data == null || _data!.isEmpty
                    ? _buildEmpty()
                    : RefreshIndicator(
                        onRefresh: _load,
                        color: AppTheme.ac,
                        child: ListView(
                          padding: const EdgeInsets.all(12),
                          children: [
                            if (_hasProgress) _buildProgressSection(state),
                            if (_hasRecent) _buildRecentSection(state),
                            if (_hasTopRated) _buildTopRatedSection(state),
                            if (_hasRecommendations) _buildRecommendationsSection(state),
                            if (!_hasProgress && !_hasRecent)
                              _buildEmpty(),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  bool get _hasProgress => (_data?['progress'] as List?)?.isNotEmpty == true;
  bool get _hasRecent => (_data?['recent'] as List?)?.isNotEmpty == true;
  bool get _hasTopRated => (_data?['top_rated'] as List?)?.isNotEmpty == true;
  bool get _hasRecommendations => (_data?['recommendations'] as List?)?.isNotEmpty == true;

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.library_books, color: AppTheme.t3, size: 48),
          const SizedBox(height: 12),
          Text('Bienvenue !', style: TextStyle(color: AppTheme.t1, fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Synchronisez et lisez des mangas.', style: TextStyle(color: AppTheme.t3, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _sectionHeader(String icon, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Text(title, style: TextStyle(color: AppTheme.t1, fontSize: 15, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildProgressSection(AppState state) {
    final items = (_data!['progress'] as List?) ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('📖', 'Reprendre la lecture'),
        SizedBox(
          height: 190,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            itemBuilder: (ctx, i) {
              final p = Map<String, dynamic>.from(items[i] as Map);
              final pct = (p['total_pages'] ?? 1) > 0
                  ? ((p['current_page'] ?? 0) / (p['total_pages'] ?? 1) * 100).round()
                  : 0;
              return GestureDetector(
                onTap: () => _resumeReading(state, p),
                child: Container(
                  width: 110,
                  margin: const EdgeInsets.only(right: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Stack(
                        children: [
                          Container(
                            width: 110, height: 142,
                            decoration: BoxDecoration(
                              color: AppTheme.c2,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppTheme.brd, width: 0.5),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: _CoverFromServer(
                                serverUrl: state.db.serverUrl,
                                folder: p['manga_url']?.toString() ?? '',
                                headers: state.db.authHeaders,
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 0, left: 0, right: 0,
                            child: Container(
                              height: 4,
                              decoration: BoxDecoration(
                                color: AppTheme.brd,
                                borderRadius: const BorderRadius.only(
                                  bottomLeft: Radius.circular(8),
                                  bottomRight: Radius.circular(8),
                                ),
                              ),
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: pct / 100,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: AppTheme.ac,
                                    borderRadius: const BorderRadius.only(
                                      bottomLeft: Radius.circular(8),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        p['title']?.toString() ?? p['manga_url']?.toString() ?? '',
                        style: TextStyle(color: AppTheme.t1, fontSize: 10, fontWeight: FontWeight.w600),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                      ),
                      Text('$pct%', style: TextStyle(color: AppTheme.t3, fontSize: 9)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildRecentSection(AppState state) {
    final items = (_data!['recent'] as List?) ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('🆕', 'Derniers ajouts'),
        _mangaScroll(state, items),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildTopRatedSection(AppState state) {
    final items = (_data!['top_rated'] as List?) ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('⭐', 'Mes favoris'),
        _mangaScroll(state, items),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildRecommendationsSection(AppState state) {
    final items = (_data!['recommendations'] as List?) ?? [];
    final genre = _data!['top_genre']?.toString() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('💡', 'Recommandes${genre.isNotEmpty ? ' ($genre)' : ''}'),
        _mangaScroll(state, items),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _mangaScroll(AppState state, List items) {
    return SizedBox(
      height: 175,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final m = Map<String, dynamic>.from(items[i] as Map);
          return GestureDetector(
            onTap: () => _openManga(state, m),
            child: Container(
              width: 100,
              margin: const EdgeInsets.only(right: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 100, height: 142,
                    decoration: BoxDecoration(
                      color: AppTheme.c2,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.brd, width: 0.5),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _CoverFromServer(
                        serverUrl: state.db.serverUrl,
                        folder: m['cbz_folder']?.toString() ?? '',
                        headers: state.db.authHeaders,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    m['title']?.toString() ?? '',
                    style: TextStyle(color: AppTheme.t1, fontSize: 10, fontWeight: FontWeight.w600),
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openManga(AppState state, Map<String, dynamic> m) async {
    final id = m['id'] as int?;
    if (id == null) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => MangaDetailScreen(mangaId: id)));
  }

  Future<void> _resumeReading(AppState state, Map<String, dynamic> p) async {
    final volumeId = p['volume_id']?.toString() ?? '';
    final mangaUrl = p['manga_url']?.toString() ?? '';
    if (volumeId.isEmpty) return;
    final volumes = await state.db.getVolumes(mangaUrl);
    Volume? vol;
    for (final v in volumes) {
      if (v.filepath == volumeId) { vol = v; break; }
    }
    if (vol == null && volumes.isNotEmpty) {
      vol = volumes.first;
    }
    if (vol == null || !mounted) return;
    final localPath = await state.downloads.getLocalPath(vol);
    final title = p['title']?.toString() ?? mangaUrl;
    final startPage = (p['current_page'] as int?) ?? 0;
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => ReaderScreen(
        title: title,
        volume: vol!,
        localPath: localPath,
        online: localPath == null,
        onlineTotalPages: (p['total_pages'] as int?) ?? 0,
        startPage: startPage,
      ),
    ));
  }
}

class _CoverFromServer extends StatelessWidget {
  final String serverUrl;
  final String folder;
  final Map<String, String> headers;

  const _CoverFromServer({required this.serverUrl, required this.folder, required this.headers});

  @override
  Widget build(BuildContext context) {
    if (serverUrl.isEmpty || folder.isEmpty) {
      return Center(child: Icon(Icons.menu_book, color: AppTheme.t3, size: 28));
    }
    return Image.network(
      '$serverUrl/api/cbz/folder-cover/${Uri.encodeComponent(folder)}',
      headers: headers,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, __, ___) => Center(child: Icon(Icons.menu_book, color: AppTheme.t3, size: 28)),
    );
  }
}
