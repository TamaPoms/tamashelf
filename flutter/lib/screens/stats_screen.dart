import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../theme.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  Map<String, dynamic>? _stats;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final stats = await state.db.getStats();
    if (mounted) setState(() { _stats = stats; _loading = false; });
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
              Icon(Icons.bar_chart, color: AppTheme.ac, size: 22),
              const SizedBox(width: 10),
              Text('Statistiques', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.t1)),
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
              : _stats == null || _stats!.isEmpty
                  ? Center(child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bar_chart, color: AppTheme.t3, size: 48),
                        const SizedBox(height: 12),
                        Text('Pas encore de statistiques', style: TextStyle(color: AppTheme.t3, fontSize: 14)),
                        const SizedBox(height: 4),
                        Text('Lisez des mangas pour voir vos stats !', style: TextStyle(color: AppTheme.t3, fontSize: 12)),
                      ],
                    ))
                  : RefreshIndicator(
                      onRefresh: _load,
                      color: AppTheme.ac,
                      child: ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          _buildSummaryCards(),
                          const SizedBox(height: 16),
                          _buildDailyChart(),
                          const SizedBox(height: 16),
                          _buildTopGenres(),
                        ],
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildSummaryCards() {
    final totalPages = (_stats?['total_pages'] as num?)?.toInt() ?? 0;
    final totalVolumes = (_stats?['total_volumes'] as num?)?.toInt() ?? 0;
    final totalSeconds = (_stats?['total_seconds'] as num?)?.toInt() ?? 0;
    final activeDays = (_stats?['active_days'] as num?)?.toInt() ?? 0;
    final inProgress = (_stats?['in_progress'] as num?)?.toInt() ?? 0;

    final hours = totalSeconds ~/ 3600;
    final mins = (totalSeconds % 3600) ~/ 60;
    final timeStr = hours > 0 ? '${hours}h ${mins}m' : '${mins}m';

    final items = [
      _StatItem('📄', 'Pages lues', _formatNumber(totalPages)),
      _StatItem('📖', 'Volumes lus', '$totalVolumes'),
      _StatItem('⏱️', 'Temps de lecture', timeStr),
      _StatItem('📅', 'Jours actifs', '$activeDays'),
      _StatItem('📚', 'En cours', '$inProgress'),
    ];

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.6,
      children: items.map((item) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.c1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.brd, width: 0.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(item.icon, style: const TextStyle(fontSize: 22)),
            const SizedBox(height: 4),
            Text(item.value, style: TextStyle(color: AppTheme.t1, fontSize: 20, fontWeight: FontWeight.w800)),
            Text(item.label, style: TextStyle(color: AppTheme.t3, fontSize: 10)),
          ],
        ),
      )).toList(),
    );
  }

  Widget _buildDailyChart() {
    final daily = (_stats?['daily'] as List?) ?? [];
    if (daily.isEmpty) return const SizedBox.shrink();

    final maxPages = daily.fold<int>(1, (m, d) {
      final p = ((d as Map)['pages_read'] as num?)?.toInt() ?? 0;
      return p > m ? p : m;
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('📈', style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            Text('30 derniers jours', style: TextStyle(color: AppTheme.t1, fontSize: 14, fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          height: 120,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.c1,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.brd, width: 0.5),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: daily.map((d) {
              final pages = ((d as Map)['pages_read'] as num?)?.toInt() ?? 0;
              final pct = pages / maxPages;
              return Expanded(
                child: Tooltip(
                  message: '${d['date']}: $pages pages',
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 0.5),
                    decoration: BoxDecoration(
                      color: pages > 0 ? AppTheme.ac : AppTheme.brd.withValues(alpha: 0.3),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(2),
                        topRight: Radius.circular(2),
                      ),
                    ),
                    height: max(2, pct * 100),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildTopGenres() {
    final genres = (_stats?['top_genres'] as List?) ?? [];
    if (genres.isEmpty) return const SizedBox.shrink();

    final genreColors = [
      AppTheme.ac, AppTheme.grn, AppTheme.amb, AppTheme.ros, AppTheme.cyn,
      MangaColors.accent, MangaColors.secondary,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('🏷️', style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            Text('Genres preferes', style: TextStyle(color: AppTheme.t1, fontSize: 14, fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: genres.asMap().entries.map((entry) {
            final g = entry.value as List;
            final name = g[0].toString();
            final count = g[1];
            final color = genreColors[entry.key % genreColors.length];
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Text(
                '$name ($count)',
                style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  String _formatNumber(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

class _StatItem {
  final String icon;
  final String label;
  final String value;
  const _StatItem(this.icon, this.label, this.value);
}
