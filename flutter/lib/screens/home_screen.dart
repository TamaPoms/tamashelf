import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../app_state.dart';
import '../services/update_service.dart';
import '../theme.dart';
import 'manga_detail_screen.dart';
import 'downloads_screen.dart';
import 'reading_screen.dart';
import 'matching_screen.dart';
import 'user_list_screen.dart';
import 'homepage_screen.dart';
import 'collections_screen.dart';
import 'stats_screen.dart';
import 'kavita_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _navIdx = 0; // 0=home, 1=library, 2=reading, 3=collections, 4=more
  int _moreIdx = -1; // sub-index for "more" tab items
  final _searchCtrl = TextEditingController();
  bool _showSearch = false;
  int _viewMode = 0; // 0=grid, 1=compact, 2=list, 3=coverflow
  bool _keepScreenOn = false;
  String _appVersion = '';
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadKeepScreenOn();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _appVersion = info.version);
  }

  Future<void> _loadKeepScreenOn() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool('keep_screen_on') ?? false;
    setState(() => _keepScreenOn = v);
    if (v) WakelockPlus.enable();
  }

  Future<void> _saveKeepScreenOn(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('keep_screen_on', v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.d,
      body: SafeArea(
        child: Column(
          children: [
            const _UpdateBanner(),
            Expanded(
              child: Consumer<AppState>(
                builder: (ctx, state, _) {
                  final isAdmin = state.db.isAdmin;
                  // Main pages for bottom nav
                  if (_navIdx == 4) {
                    // "More" sub-pages
                    return _buildMorePage(state, isAdmin);
                  }
                  final pages = <Widget>[
                    const HomepageScreen(),
                    _buildLibrary(),
                    const ReadingScreen(),
                    const CollectionsScreen(),
                  ];
                  return IndexedStack(
                    index: _navIdx.clamp(0, pages.length - 1),
                    children: pages,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Consumer<AppState>(
        builder: (ctx, state, _) {
          final items = <BottomNavigationBarItem>[
            const BottomNavigationBarItem(icon: Icon(Icons.home_rounded), label: 'Accueil'),
            const BottomNavigationBarItem(icon: Icon(Icons.library_books), label: 'Bibliotheque'),
            const BottomNavigationBarItem(icon: Icon(Icons.auto_stories), label: 'En cours'),
            const BottomNavigationBarItem(icon: Icon(Icons.folder_special), label: 'Collections'),
            const BottomNavigationBarItem(icon: Icon(Icons.more_horiz), label: 'Plus'),
          ];
          return BottomNavigationBar(
            currentIndex: _navIdx.clamp(0, items.length - 1),
            onTap: (i) async {
              if (i == 2) {
                // Refresh progress on reading tab
              }
              setState(() { _navIdx = i; if (i != 4) _moreIdx = -1; });
            },
            backgroundColor: AppTheme.bg,
            selectedItemColor: AppTheme.ac,
            unselectedItemColor: AppTheme.t3,
            type: BottomNavigationBarType.fixed,
            items: items,
          );
        },
      ),
    );
  }

  Widget _buildMorePage(AppState state, bool isAdmin) {
    if (_moreIdx >= 0) {
      Widget subPage;
      if (_moreIdx == 0) subPage = const UserListScreen(listName: 'to_read', title: 'A lire', icon: Icons.bookmark_add);
      else if (_moreIdx == 1) subPage = const UserListScreen(listName: 'read', title: 'Lu', icon: Icons.check_circle);
      else if (_moreIdx == 2) subPage = const StatsScreen();
      else if (_moreIdx == 3) subPage = const DownloadsScreen();
      else if (_moreIdx == 4 && isAdmin) subPage = const MatchingScreen();
      else if (_moreIdx == 5) subPage = _buildSettings();
      else subPage = const SizedBox.shrink();

      return Column(
        children: [
          Container(
            color: AppTheme.bg,
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back, color: AppTheme.t1, size: 22),
                  onPressed: () => setState(() => _moreIdx = -1),
                ),
                Text('Retour', style: TextStyle(color: AppTheme.t2, fontSize: 13)),
              ],
            ),
          ),
          Expanded(child: subPage),
        ],
      );
    }

    // Show the "More" menu
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          color: AppTheme.bg,
          child: Row(
            children: [
              Icon(Icons.more_horiz, color: AppTheme.ac, size: 22),
              const SizedBox(width: 10),
              Text('Plus', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.t1)),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _moreItem(Icons.bookmark_add, 'A lire', '${state.toReadItems.length}', AppTheme.ac, 0),
              _moreItem(Icons.check_circle, 'Lu', '${state.readItems.length}', AppTheme.grn, 1),
              _moreItem(Icons.bar_chart, 'Statistiques', '', MangaColors.accent, 2),
              _moreItem(Icons.download_done, 'Telecharges', '', AppTheme.cyn, 3),
              if (isAdmin) _moreItem(Icons.link, 'Associer mangas', '', AppTheme.amb, 4),
              _moreItem(Icons.settings, 'Parametres', '', AppTheme.t2, 5),
              _moreItem(Icons.auto_stories_outlined, 'Kavita', '', AppTheme.cyn, 6,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KavitaScreen()))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _moreItem(IconData icon, String label, String badge, Color color, int idx, {VoidCallback? onTap}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: AppTheme.c1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.brd, width: 0.5),
      ),
      child: ListTile(
        leading: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(label, style: TextStyle(color: AppTheme.t1, fontSize: 14, fontWeight: FontWeight.w600)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (badge.isNotEmpty && badge != '0')
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
                child: Text(badge, style: TextStyle(color: AppTheme.d, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, color: AppTheme.t3, size: 20),
          ],
        ),
        onTap: onTap ?? () async {
          if (idx == 0 || idx == 1) await context.read<AppState>().loadLists();
          setState(() => _moreIdx = idx);
        },
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildLibrary() {
    return Consumer<AppState>(
      builder: (ctx, state, _) => Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppTheme.bg,
            child: Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(color: AppTheme.ac, borderRadius: BorderRadius.circular(8)),
                  child: Center(child: Text('鬼', style: TextStyle(fontSize: 20, color: AppTheme.d, fontWeight: FontWeight.w800))),
                ),
                SizedBox(width: 10),
                Text('TamaShelf', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.t1)),
                Spacer(),
                Text('${state.mangaCount}', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
                SizedBox(width: 4),
                // View mode toggle
                IconButton(
                  icon: Icon(
                    _viewMode == 0 ? Icons.grid_view : _viewMode == 1 ? Icons.apps : _viewMode == 2 ? Icons.view_list : Icons.view_carousel,
                    color: AppTheme.t2, size: 20,
                  ),
                  onPressed: () => setState(() => _viewMode = (_viewMode + 1) % 4),
                  tooltip: ['Grille', 'Compact', 'Liste', 'CoverFlow'][_viewMode],
                ),
                IconButton(
                  icon: Icon(_showSearch ? Icons.close : Icons.search, color: AppTheme.t2, size: 22),
                  onPressed: () => setState(() { _showSearch = !_showSearch; if (!_showSearch) { _searchCtrl.clear(); state.setSearch(''); } }),
                ),
                // Filter button
                Stack(
                  children: [
                    IconButton(
                      icon: Icon(Icons.tune, color: AppTheme.t2, size: 22),
                      onPressed: () => _showFilterSheet(context, state),
                    ),
                    if (state.activeFilterCount > 0)
                      Positioned(
                        right: 4, top: 4,
                        child: Container(
                          width: 16, height: 16,
                          decoration: BoxDecoration(color: AppTheme.ac, shape: BoxShape.circle),
                          child: Center(child: Text('${state.activeFilterCount}', style: TextStyle(color: AppTheme.d, fontSize: 9, fontWeight: FontWeight.w700))),
                        ),
                      ),
                  ],
                ),
                // Sync button
                IconButton(
                  icon: state.isSyncing
                    ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.ac))
                    : Icon(Icons.sync, color: AppTheme.t2, size: 22),
                  onPressed: state.isSyncing ? null : () async {
                    final ok = await state.syncDb();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(ok ? '✅ Base mise à jour' : '❌ Échec sync'), backgroundColor: ok ? AppTheme.grn : AppTheme.ros),
                      );
                    }
                  },
                ),
              ],
            ),
          ),

          // Library selector
          if (state.libraries.length > 1)
            Container(
              color: AppTheme.bg,
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _libChip(state, null, 'Toutes', state.libraryFilter == null),
                  ...state.libraries.map((lib) {
                    final id = lib['id'] as int;
                    final name = lib['name'] as String? ?? '?';
                    final count = lib['count'] as int? ?? 0;
                    return _libChip(state, id, '$name ($count)', state.libraryFilter == id);
                  }),
                ],
              ),
            ),

          // Content type filter (Tout / Tomes / Chapitres)
          Container(
            color: AppTheme.bg,
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _contentChip(state, null, 'Tout'),
                _contentChip(state, 'tome', 'Tomes'),
                _contentChip(state, 'chapter', 'Chapitres'),
                _contentChip(state, 'oneshot', 'One-shot'),
              ],
            ),
          ),

          // Search bar
          if (_showSearch) Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppTheme.bg,
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Rechercher...',
                prefixIcon: Icon(Icons.search, color: AppTheme.t3),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 10),
              ),
              style: TextStyle(color: AppTheme.t1, fontSize: 14),
              onChanged: (v) => state.setSearch(v),
            ),
          ),

          // Active filter chips
          if (state.activeFilterCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              color: AppTheme.bg,
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ...state.tagFilters.entries.expand((cat) =>
                            cat.value.map((tag) => Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Chip(
                                label: Text(tag, style: TextStyle(color: AppTheme.d, fontSize: 10)),
                                backgroundColor: AppTheme.ac,
                                deleteIcon: Icon(Icons.close, size: 14, color: AppTheme.d),
                                onDeleted: () => state.toggleTag(cat.key, tag),
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                              ),
                            )),
                          ),
                        ],
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => state.clearTagFilters(),
                    child: Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Text('Effacer', style: TextStyle(color: AppTheme.ros, fontSize: 11)),
                    ),
                  ),
                ],
              ),
            ),

          // Result count when filtered
          if (state.activeFilterCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              color: AppTheme.bg,
              child: Text(
                '${state.mangas.length} resultats',
                style: TextStyle(color: AppTheme.t3, fontSize: 11),
              ),
            ),

          // Alpha filter
          SizedBox(
            height: 28,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                _alphaChip(state, null, 'All'),
                _alphaChip(state, '#', '#'),
                ...List.generate(26, (i) {
                  final l = String.fromCharCode(65 + i);
                  return _alphaChip(state, l, l);
                }),
              ],
            ),
          ),
          const SizedBox(height: 4),

          // Grid
          Expanded(
            child: state.isLoading
              ? const Center(child: CircularProgressIndicator())
              : state.mangas.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Aucun manga', style: TextStyle(color: AppTheme.t3)),
                        if (!state.db.hasLocalDb) ...[
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: () => state.syncDb(),
                            icon: const Icon(Icons.sync),
                            label: const Text('Synchroniser'),
                          ),
                        ],
                      ],
                    ),
                  )
                : _viewMode == 2
                  ? ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: state.mangas.length,
                      itemBuilder: (ctx, i) => _MangaListTile(manga: state.mangas[i]),
                    )
                  : _viewMode == 3
                    ? _CoverFlowView(mangas: state.mangas)
                    : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _viewMode == 0 ? 3 : 5,
                      childAspectRatio: _viewMode == 0 ? 0.55 : 0.52,
                      crossAxisSpacing: _viewMode == 0 ? 8 : 4,
                      mainAxisSpacing: _viewMode == 0 ? 8 : 4,
                    ),
                    itemCount: state.mangas.length,
                    itemBuilder: (ctx, i) => _MangaCard(manga: state.mangas[i], compact: _viewMode == 1),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _showChangePasswordDialog(AppState state) async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? error;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.bg,
          title: Text('Changer le mot de passe', style: TextStyle(color: AppTheme.t1, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: oldCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Ancien mot de passe', isDense: true),
                style: TextStyle(color: AppTheme.t1, fontSize: 14),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: newCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Nouveau mot de passe', isDense: true),
                style: TextStyle(color: AppTheme.t1, fontSize: 14),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: confirmCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Confirmer', isDense: true),
                style: TextStyle(color: AppTheme.t1, fontSize: 14),
              ),
              if (error != null) Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: TextStyle(color: AppTheme.ros, fontSize: 12)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Annuler', style: TextStyle(color: AppTheme.t3)),
            ),
            ElevatedButton(
              onPressed: () async {
                if (newCtrl.text != confirmCtrl.text) {
                  setDialogState(() => error = 'Les mots de passe ne correspondent pas');
                  return;
                }
                if (newCtrl.text.isEmpty) {
                  setDialogState(() => error = 'Le mot de passe ne peut pas etre vide');
                  return;
                }
                final result = await state.db.changePassword(oldCtrl.text, newCtrl.text);
                if (result) {
                  Navigator.pop(ctx, true);
                } else {
                  setDialogState(() => error = state.db.lastError.isNotEmpty ? state.db.lastError : 'Erreur');
                }
              },
              child: const Text('Changer'),
            ),
          ],
        ),
      ),
    );

    oldCtrl.dispose();
    newCtrl.dispose();
    confirmCtrl.dispose();

    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: const Text('Mot de passe change'), backgroundColor: AppTheme.grn),
      );
    }
  }

  void _showFilterSheet(BuildContext context, AppState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _FilterSheet(state: state),
    );
  }

  Widget _alphaChip(AppState state, String? value, String label) {
    final isActive = state.letterFilter == value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: () => state.setLetterFilter(value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isActive ? AppTheme.ac : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isActive ? AppTheme.d : AppTheme.t3,
              fontSize: 11,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _libChip(AppState state, int? id, String label, bool isActive) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
      child: GestureDetector(
        onTap: () => state.setLibrary(id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: isActive ? MangaColors.secondary : AppTheme.c1,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive ? MangaColors.secondary : AppTheme.brd,
              width: isActive ? 1.5 : 0.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.white : AppTheme.t2,
              fontSize: 11,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _contentChip(AppState state, String? type, String label) {
    final isActive = state.contentType == type;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
      child: GestureDetector(
        onTap: () => state.setContentType(type),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: isActive ? MangaColors.accent : AppTheme.c1,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive ? MangaColors.accent : AppTheme.brd,
              width: isActive ? 1.5 : 0.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.white : AppTheme.t2,
              fontSize: 11,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettings() {
    final appTheme = context.watch<AppTheme>();
    return Consumer<AppState>(
      builder: (ctx, state, _) {
        final username = state.db.currentUsername.isEmpty ? 'Compte local' : state.db.currentUsername;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: const LinearGradient(colors: [MangaColors.accent, MangaColors.secondary]),
                  ),
                  child: const Icon(Icons.palette, color: Colors.white, size: 20),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text('Themes & polices', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.t1)),
                ),
              ],
            ),
            SizedBox(height: 8),
            Text('Preferences enregistrees pour : $username', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
            SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.c1,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.brd, width: 0.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.style, color: MangaColors.accent, size: 22),
                      SizedBox(width: 10),
                      Text('Theme', style: TextStyle(color: AppTheme.t1, fontSize: 14, fontWeight: FontWeight.w700)),
                    ],
                  ),
                  SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: appTheme.preset.id,
                    dropdownColor: AppTheme.bg,
                    items: AppTheme.presets.map((preset) => DropdownMenuItem(
                      value: preset.id,
                      child: Text('${preset.label} — ${preset.subtitle}', overflow: TextOverflow.ellipsis),
                    )).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        appTheme.setPresetForUser(state.db.currentUsername, value);
                      }
                    },
                    decoration: InputDecoration(labelText: 'Choix du theme'),
                  ),
                  SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: AppTheme.presets.map((preset) {
                      final active = preset.id == appTheme.preset.id;
                      final p = preset.palette;
                      return InkWell(
                        onTap: () => appTheme.setPresetForUser(state.db.currentUsername, preset.id),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          width: 145,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: active ? MangaColors.accent.withValues(alpha: 0.12) : AppTheme.bg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: active ? MangaColors.accent : AppTheme.brd),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  _themeDot(p.bg),
                                  SizedBox(width: 6),
                                  _themeDot(p.card),
                                  SizedBox(width: 6),
                                  _themeDot(MangaColors.accent),
                                ],
                              ),
                              SizedBox(height: 10),
                              Text(preset.label, style: TextStyle(color: AppTheme.t1, fontSize: 12, fontWeight: FontWeight.w700)),
                              SizedBox(height: 4),
                              Text(preset.subtitle, style: TextStyle(color: AppTheme.t3, fontSize: 10)),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.c1,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.brd, width: 0.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.font_download_rounded, color: MangaColors.accent, size: 22),
                      SizedBox(width: 10),
                      Text('Police', style: TextStyle(color: AppTheme.t1, fontSize: 14, fontWeight: FontWeight.w700)),
                    ],
                  ),
                  SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: appTheme.font.id,
                    dropdownColor: AppTheme.bg,
                    items: AppTheme.fonts.map((font) => DropdownMenuItem(
                      value: font.id,
                      child: Text(font.label, overflow: TextOverflow.ellipsis),
                    )).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        appTheme.setFontForUser(state.db.currentUsername, value);
                      }
                    },
                    decoration: InputDecoration(labelText: 'Choix de la police'),
                  ),
                  SizedBox(height: 12),
                  ...AppTheme.fonts.map((font) {
                    final active = font.id == appTheme.font.id;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: active ? MangaColors.accent.withValues(alpha: 0.12) : AppTheme.bg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: active ? MangaColors.accent : AppTheme.brd),
                      ),
                      child: ListTile(
                        onTap: () => appTheme.setFontForUser(state.db.currentUsername, font.id),
                        leading: Icon(active ? Icons.radio_button_checked : Icons.radio_button_off, color: active ? MangaColors.accent : AppTheme.t3),
                        title: Text(font.label, style: TextStyle(color: AppTheme.t1, fontWeight: FontWeight.w700, fontFamily: font.family)),
                        subtitle: Text(font.preview, style: TextStyle(color: AppTheme.t3, fontSize: 12, fontFamily: font.family)),
                      ),
                    );
                  }),
                ],
              ),
            ),
            SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.c1,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.brd, width: 0.5),
              ),
              child: Row(
                children: [
                  Icon(Icons.phone_android, color: MangaColors.accent, size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Ecran toujours allume', style: TextStyle(color: AppTheme.t1, fontSize: 14, fontWeight: FontWeight.w600)),
                        Text('Empeche la mise en veille', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
                      ],
                    ),
                  ),
                  Switch(
                    value: _keepScreenOn,
                    onChanged: (v) {
                      setState(() => _keepScreenOn = v);
                      if (v) { WakelockPlus.enable(); } else { WakelockPlus.disable(); }
                      _saveKeepScreenOn(v);
                    },
                    activeColor: MangaColors.accent,
                    activeTrackColor: MangaColors.accent.withValues(alpha: 0.3),
                  ),
                ],
              ),
            ),
            SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.c1,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.brd, width: 0.5),
              ),
              child: Row(
                children: [
                  Icon(Icons.auto_stories_outlined, color: MangaColors.accent, size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Raccourci Kavita sur l\'accueil', style: TextStyle(color: AppTheme.t1, fontSize: 14, fontWeight: FontWeight.w600)),
                        Text('Affiche une carte d\'accès rapide vers Kavita', style: TextStyle(color: AppTheme.t3, fontSize: 11)),
                      ],
                    ),
                  ),
                  Switch(
                    value: state.showKavitaShortcut,
                    onChanged: (v) => state.setShowKavitaShortcut(v),
                    activeColor: MangaColors.accent,
                    activeTrackColor: MangaColors.accent.withValues(alpha: 0.3),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _buildAppInfoCard(state),
            const SizedBox(height: 12),
            _settingsTile('Serveur', state.db.serverUrl, Icons.dns),
            _settingsTile('Compte', username, Icons.person),
            _settingsTile('Base locale', state.db.hasLocalDb ? '${state.mangaCount} mangas' : 'Non synchro', Icons.storage),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: state.isSyncing ? null : () => state.syncDb(),
              icon: const Icon(Icons.sync),
              label: Text(state.isSyncing ? 'Synchronisation...' : 'Mettre a jour la base'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _showChangePasswordDialog(state),
              icon: Icon(Icons.lock, color: AppTheme.ac),
              label: Text('Changer le mot de passe', style: TextStyle(color: AppTheme.ac)),
              style: OutlinedButton.styleFrom(side: BorderSide(color: AppTheme.ac)),
            ),
            SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pushReplacementNamed('/setup'),
              icon: Icon(Icons.logout, color: AppTheme.ros),
              label: Text('Changer de serveur', style: TextStyle(color: AppTheme.ros)),
              style: OutlinedButton.styleFrom(side: BorderSide(color: AppTheme.ros)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAppInfoCard(AppState state) {
    final info = state.updateInfo;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.c1,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.brd, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: MangaColors.accent, size: 22),
              const SizedBox(width: 10),
              Text('Application', style: TextStyle(color: AppTheme.t1, fontSize: 14, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _appVersion.isEmpty ? 'Version installee : ...' : 'Version installee : $_appVersion',
            style: TextStyle(color: AppTheme.t2, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            info != null ? 'Nouvelle version disponible : ${info.version}' : 'A jour',
            style: TextStyle(
              color: info != null ? AppTheme.ac : AppTheme.t3,
              fontSize: 12,
              fontWeight: info != null ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (info != null) ...[
                ElevatedButton.icon(
                  onPressed: () => _downloadAndInstallApk(context, info.downloadUrl),
                  icon: const Icon(Icons.system_update_rounded, size: 16),
                  label: const Text('Installer'),
                ),
                const SizedBox(width: 12),
              ],
              _checkingUpdate
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : OutlinedButton.icon(
                      onPressed: () async {
                        setState(() => _checkingUpdate = true);
                        await state.checkForUpdate();
                        if (!mounted) return;
                        setState(() => _checkingUpdate = false);
                        if (state.updateInfo == null) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Deja a jour')));
                        }
                      },
                      icon: Icon(Icons.refresh, color: AppTheme.ac, size: 16),
                      label: Text('Verifier', style: TextStyle(color: AppTheme.ac)),
                      style: OutlinedButton.styleFrom(side: BorderSide(color: AppTheme.ac)),
                    ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _themeDot(Color color) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
    );
  }

  Widget _settingsTile(String title, String value, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.c1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.brd, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.t3, size: 20),
          SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: AppTheme.t3, fontSize: 11, fontWeight: FontWeight.w600)),
              SizedBox(height: 2),
              Text(value, style: TextStyle(color: AppTheme.t1, fontSize: 13), overflow: TextOverflow.ellipsis),
            ],
          )),
        ],
      ),
    );
  }
}

class _MangaCard extends StatelessWidget {
  final dynamic manga;
  final bool compact;
  const _MangaCard({required this.manga, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => MangaDetailScreen(mangaId: manga.id),
      )),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(compact ? 6 : 10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: compact ? 4 : 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cover with gradient overlay
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(compact ? 6 : 10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: AppTheme.c2, child: _CoverImage(mangaId: manga.id, cbzFolder: manga.cbzFolder)),
                    // Bottom gradient for title readability
                    if (!compact)
                      Positioned(
                        bottom: 0, left: 0, right: 0,
                        child: Container(
                          height: 50,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
                            ),
                          ),
                        ),
                      ),
                    // Match status indicator
                    if (manga.matchStatus == 'matched' && !compact)
                      Positioned(
                        top: 4, right: 4,
                        child: Container(
                          width: 8, height: 8,
                          decoration: BoxDecoration(
                            color: MangaColors.success,
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(color: MangaColors.success.withValues(alpha: 0.5), blurRadius: 4)],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(height: compact ? 2 : 5),
            Text(
              manga.title,
              maxLines: compact ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.t1,
                fontSize: compact ? 9 : 11,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MangaListTile extends StatelessWidget {
  final dynamic manga;
  _MangaListTile({required this.manga});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: AppTheme.c1,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.brd, width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.push(context, MaterialPageRoute(
          builder: (_) => MangaDetailScreen(mangaId: manga.id),
        )),
        child: Row(
          children: [
            // Cover thumbnail
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
              child: SizedBox(
                width: 50, height: 70,
                child: Container(
                  color: AppTheme.c2,
                  child: _CoverImage(mangaId: manga.id, cbzFolder: manga.cbzFolder),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Info
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      manga.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppTheme.t1, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 2),
                    Text(
                      manga.cbzFolder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppTheme.t3, fontSize: 10),
                    ),
                    if (manga.matchStatus == 'matched')
                      Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Icon(Icons.check_circle, color: AppTheme.grn, size: 10),
                            SizedBox(width: 3),
                            Text('Associe', style: TextStyle(color: AppTheme.grn, fontSize: 9)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Icon(Icons.chevron_right, color: AppTheme.t3, size: 18),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _CoverFlowView extends StatefulWidget {
  final List<dynamic> mangas;
  const _CoverFlowView({required this.mangas});

  @override
  State<_CoverFlowView> createState() => _CoverFlowViewState();
}

class _CoverFlowViewState extends State<_CoverFlowView> {
  late PageController _pageCtrl;
  double _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController(viewportFraction: 0.45, initialPage: 0);
    _pageCtrl.addListener(() {
      setState(() => _currentPage = _pageCtrl.page ?? 0);
    });
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mangas.isEmpty) {
      return Center(child: Text('Aucun manga', style: TextStyle(color: AppTheme.t3)));
    }

    final idx = _currentPage.round().clamp(0, widget.mangas.length - 1);
    final manga = widget.mangas[idx];

    return Column(
      children: [
        // CoverFlow carousel
        Expanded(
          child: PageView.builder(
            controller: _pageCtrl,
            itemCount: widget.mangas.length,
            itemBuilder: (ctx, i) {
              final diff = (i - _currentPage);
              final scale = (1 - diff.abs() * 0.25).clamp(0.65, 1.0);
              final opacity = (1 - diff.abs() * 0.3).clamp(0.3, 1.0);
              final translateY = diff.abs() * 20.0;

              return TweenAnimationBuilder<double>(
                tween: Tween(begin: scale, end: scale),
                duration: const Duration(milliseconds: 100),
                builder: (ctx, val, child) => Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.001)
                    ..scale(val)
                    ..translate(0.0, translateY),
                  child: Opacity(
                    opacity: opacity,
                    child: child,
                  ),
                ),
                child: GestureDetector(
                  onTap: () {
                    if ((i - _currentPage).abs() < 0.5) {
                      Navigator.push(context, MaterialPageRoute(
                        builder: (_) => MangaDetailScreen(mangaId: widget.mangas[i].id),
                      ));
                    } else {
                      _pageCtrl.animateToPage(i,
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeOutCubic,
                      );
                    }
                  },
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                      child: AspectRatio(
                        aspectRatio: 2 / 3,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              if (diff.abs() < 0.5) BoxShadow(
                                color: MangaColors.accent.withValues(alpha: 0.3),
                                blurRadius: 20,
                                spreadRadius: 2,
                              ) else BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 10,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              color: AppTheme.c2,
                              child: _CoverImage(mangaId: widget.mangas[i].id, cbzFolder: widget.mangas[i].cbzFolder, fit: BoxFit.contain),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // Info panel for selected manga
        Container(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            children: [
              // Title
              Text(
                manga.title,
                style: TextStyle(
                  color: AppTheme.t1,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: 6),
              // Folder
              Text(
                manga.cbzFolder,
                style: TextStyle(color: AppTheme.t3, fontSize: 11),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              // Genre badges
              if (manga.metadata.containsKey('Genres'))
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: (manga.metadata['Genres']?.toString() ?? '')
                    .split(' - ')
                    .where((g) => g.trim().isNotEmpty)
                    .take(4)
                    .map((g) {
                      final color = MangaColors.tagColor(g.trim());
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: color.withValues(alpha: 0.4)),
                        ),
                        child: Text(g.trim(), style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
                      );
                    }).toList(),
                ),
              SizedBox(height: 10),
              // Page indicator
              Text(
                '${idx + 1} / ${widget.mangas.length}',
                style: TextStyle(color: AppTheme.t3, fontSize: 11, fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CoverImage extends StatefulWidget {
  final int mangaId;
  final String cbzFolder;
  final BoxFit fit;
  const _CoverImage({required this.mangaId, required this.cbzFolder, this.fit = BoxFit.cover});

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<_CoverImage> {
  Uint8List? _bytes;
  bool _loaded = false;

  // Global in-memory cache to avoid re-fetching
  static final Map<int, Uint8List> _cache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 1. Check memory cache
    if (_cache.containsKey(widget.mangaId)) {
      if (mounted) setState(() { _bytes = _cache[widget.mangaId]; _loaded = true; });
      return;
    }

    try {
      final state = context.read<AppState>();

      // 2. Try local DB cover_blob
      final bytes = await state.db.getMangaCover(widget.mangaId);
      if (bytes != null && bytes.isNotEmpty) {
        _cache[widget.mangaId] = bytes;
        if (mounted) setState(() { _bytes = bytes; _loaded = true; });
        return;
      }

      // 3. Fallback: fetch from server /api/cbz/folder-cover/{cbzFolder}
      if (state.db.serverUrl.isNotEmpty && state.db.isLoggedIn && widget.cbzFolder.isNotEmpty) {
        final url = '${state.db.serverUrl}/api/cbz/folder-cover/${Uri.encodeComponent(widget.cbzFolder)}';
        final resp = await http.get(
          Uri.parse(url),
          headers: state.db.authHeaders,
        ).timeout(const Duration(seconds: 8));

        if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
          // Resize to save memory (max 300px wide)
          final resized = await _resizeImage(resp.bodyBytes, 300);
          _cache[widget.mangaId] = resized;
          if (mounted) setState(() { _bytes = resized; _loaded = true; });
          return;
        }
      }

      if (mounted) setState(() { _loaded = true; });
    } catch (e) {
      print('CoverImage load error: $e');
      if (mounted) setState(() { _loaded = true; });
    }
  }

  static Future<Uint8List> _resizeImage(Uint8List raw, int maxWidth) async {
    try {
      // Decode image
      final codec = await ui.instantiateImageCodec(
        raw,
        targetWidth: maxWidth,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // Encode to PNG
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData != null) {
        return byteData.buffer.asUint8List();
      }
    } catch (e) {
      print('Resize error: $e');
    }
    return raw; // fallback: return original
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
    if (_bytes != null) return Image.memory(_bytes!, fit: widget.fit, width: double.infinity, height: double.infinity);
    return Center(child: Icon(Icons.book, color: AppTheme.t3, size: 32));
  }
}

class _FilterSheet extends StatefulWidget {
  final AppState state;
  const _FilterSheet({required this.state});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  String _searchTag = '';
  String? _expandedCategory;

  @override
  Widget build(BuildContext context) {
    final tags = widget.state.availableTags;
    final filters = widget.state.tagFilters;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) => Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 8),
            width: 40, height: 4,
            decoration: BoxDecoration(color: AppTheme.brd, borderRadius: BorderRadius.circular(2)),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Icon(Icons.tune, color: AppTheme.ac, size: 20),
                SizedBox(width: 8),
                Text('Filtres', style: TextStyle(color: AppTheme.t1, fontSize: 18, fontWeight: FontWeight.w700)),
                Spacer(),
                if (widget.state.activeFilterCount > 0)
                  TextButton(
                    onPressed: () {
                      widget.state.clearTagFilters();
                      Navigator.pop(context);
                    },
                    child: Text('Tout effacer', style: TextStyle(color: AppTheme.ros, fontSize: 12)),
                  ),
              ],
            ),
          ),

          // Search tags
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Chercher un tag...',
                prefixIcon: Icon(Icons.search, color: AppTheme.t3, size: 18),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              style: TextStyle(color: AppTheme.t1, fontSize: 13),
              onChanged: (v) => setState(() => _searchTag = v.toLowerCase()),
            ),
          ),

          const SizedBox(height: 8),

          // Tag categories
          Expanded(
            child: ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: tags.entries.map((cat) {
                final catName = cat.key;
                final allTags = cat.value.toList()..sort();
                final filteredTags = _searchTag.isEmpty
                    ? allTags
                    : allTags.where((t) => t.toLowerCase().contains(_searchTag)).toList();

                if (filteredTags.isEmpty) return const SizedBox.shrink();

                final selected = filters[catName] ?? [];
                final isExpanded = _expandedCategory == catName;

                // Show first 10 tags when collapsed, all when expanded
                final displayTags = isExpanded ? filteredTags : filteredTags.take(15).toList();
                final hasMore = filteredTags.length > 15;

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.c1,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.brd, width: 0.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Category header
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                        child: Row(
                          children: [
                            Text(
                              catName,
                              style: TextStyle(color: AppTheme.ac, fontSize: 13, fontWeight: FontWeight.w700),
                            ),
                            SizedBox(width: 6),
                            Text(
                              '(${filteredTags.length})',
                              style: TextStyle(color: AppTheme.t3, fontSize: 11),
                            ),
                            if (selected.isNotEmpty) ...[
                              SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: AppTheme.ac,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '${selected.length}',
                                  style: TextStyle(color: AppTheme.d, fontSize: 10, fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                      // Tags wrap
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: displayTags.map((tag) {
                            final isSelected = selected.contains(tag);
                            return GestureDetector(
                              onTap: () {
                                widget.state.toggleTag(catName, tag);
                                setState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: isSelected ? AppTheme.ac : AppTheme.inp,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isSelected ? AppTheme.ac : AppTheme.brd,
                                    width: 0.5,
                                  ),
                                ),
                                child: Text(
                                  tag,
                                  style: TextStyle(
                                    color: isSelected ? AppTheme.d : AppTheme.t2,
                                    fontSize: 12,
                                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),

                      // Show more / less
                      if (hasMore)
                        GestureDetector(
                          onTap: () => setState(() {
                            _expandedCategory = isExpanded ? null : catName;
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              border: Border(top: BorderSide(color: AppTheme.brd, width: 0.5)),
                            ),
                            child: Center(
                              child: Text(
                                isExpanded ? 'Voir moins' : 'Voir tout (${filteredTags.length})',
                                style: TextStyle(color: AppTheme.ac, fontSize: 11, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),

          // Apply button
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 12),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  widget.state.activeFilterCount > 0
                    ? 'Voir ${widget.state.mangas.length} resultats'
                    : 'Fermer',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Télécharge l'APK de mise à jour dans l'appli (barre de progression modale)
// puis l'ouvre pour déclencher l'installateur Android. Si le téléchargement
// ou l'ouverture échoue (pas de permission "sources inconnues", stockage
// plein...), on retombe sur l'ouverture du lien dans le navigateur, comme
// avant. Utilisé à la fois par le bandeau et par l'écran Réglages.
Future<void> _downloadAndInstallApk(BuildContext context, String url) async {
  final progress = ValueNotifier<double>(0);
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.bg,
      title: Text('Telechargement de la mise a jour', style: TextStyle(color: AppTheme.t1, fontSize: 15)),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (ctx, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: value > 0 ? value : null,
                minHeight: 6,
                backgroundColor: AppTheme.ac.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation(AppTheme.ac),
              ),
            ),
            const SizedBox(height: 10),
            Text(value > 0 ? '${(value * 100).toStringAsFixed(0)}%' : 'Connexion...',
                style: TextStyle(color: AppTheme.t3, fontSize: 12)),
          ],
        ),
      ),
    ),
  );

  final path = await UpdateService().downloadApk(url, onProgress: (p) => progress.value = p);
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

  if (path == null) {
    // Échec du téléchargement (réseau, stockage...) : on retombe sur le navigateur.
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    return;
  }
  final result = await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
  if (result.type != ResultType.done) {
    // Ex: permission "installer depuis des sources inconnues" refusée -- on
    // laisse quand même une porte de sortie via le navigateur.
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}

// Bandeau discret affiché en haut de l'écran quand une nouvelle version de
// l'appli est disponible sur GitHub Releases (voir AppState.checkForUpdate).
// La fermeture (X) mémorise la version pour ne pas re-notifier pour la même.
class _UpdateBanner extends StatefulWidget {
  const _UpdateBanner();

  @override
  State<_UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<_UpdateBanner> {
  String? _dismissedVersion;

  @override
  void initState() {
    super.initState();
    _loadDismissed();
  }

  Future<void> _loadDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _dismissedVersion = prefs.getString('dismissed_update_version'));
  }

  Future<void> _dismiss(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dismissed_update_version', version);
    if (!mounted) return;
    setState(() => _dismissedVersion = version);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (ctx, state, _) {
        final info = state.updateInfo;
        if (info == null || info.version == _dismissedVersion) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.ac.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.ac.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              Icon(Icons.system_update_rounded, color: AppTheme.ac, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Nouvelle version ${info.version} disponible',
                  style: TextStyle(color: AppTheme.t1, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: () => _downloadAndInstallApk(context, info.downloadUrl),
                child: const Text('Installer'),
              ),
              IconButton(
                icon: Icon(Icons.close, color: AppTheme.t3, size: 18),
                onPressed: () => _dismiss(info.version),
                tooltip: 'Ignorer cette version',
              ),
            ],
          ),
        );
      },
    );
  }
}
