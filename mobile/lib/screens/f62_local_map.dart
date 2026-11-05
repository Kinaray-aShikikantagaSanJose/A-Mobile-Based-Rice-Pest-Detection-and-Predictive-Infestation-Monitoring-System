import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_router.dart';
import '../services/api_client.dart';
import '../services/gps_service.dart';
import '../theme.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../widgets/motion.dart';
import '../widgets/scan_map.dart';

/// One validated observation on the map (from /analytics/hotspots).
class _Point {
  final int id;
  final String pest;
  final String pestKey;
  final String? level;
  final String barangay;
  final String municipality;
  final double lat;
  final double lng;
  final String createdAt;
  final int? count;
  final String cropStage;

  _Point.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as num).toInt(),
        pest = j['pest'] as String? ?? '',
        pestKey = j['pest_key'] as String? ?? '',
        level = j['level'] as String?,
        barangay = j['barangay'] as String? ?? '',
        municipality = j['municipality'] as String? ?? '',
        lat = (j['lat'] as num).toDouble(),
        lng = (j['lng'] as num).toDouble(),
        createdAt = j['created_at'] as String? ?? '',
        count = (j['count'] as num?)?.toInt(),
        cropStage = j['crop_stage'] as String? ?? '';

  String get place => [barangay, municipality].where((x) => x.isNotEmpty).join(', ');
}

/// One barangay's validated observations: centre, count, highest level.
class _Hotspot {
  final String barangay;
  final String municipality;
  final double lat;
  final double lng;
  final int records;
  final String level;
  final String latest;
  final List<String> pests;

  _Hotspot.fromJson(Map<String, dynamic> j)
      : barangay = j['barangay'] as String? ?? '',
        municipality = j['municipality'] as String? ?? '',
        lat = (j['lat'] as num).toDouble(),
        lng = (j['lng'] as num).toDouble(),
        records = (j['records'] as num?)?.toInt() ?? 0,
        level = j['level'] as String? ?? 'LOW',
        latest = j['latest'] as String? ?? '',
        pests = [for (final p in (j['pests'] as List? ?? const [])) '$p'];
}

const Map<String, String> _pestShort = {
  'brown_planthopper': 'BPH',
  'green_leafhopper': 'GLH',
  'rice_bug': 'Rice bug',
  'rice_stem_borer': 'Stem borer',
  'disease': 'Disease',
};

/// Great-circle distance in km.
double _km(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}

String _distance(double km) => km < 1 ? '${(km * 1000).round()} m away' : '${km.toStringAsFixed(km < 10 ? 1 : 0)} km away';

/// Technicians: validated records near them (their coverage area), as pins
/// coloured by infestation level and one risk circle per barangay.
class F62LocalMap extends StatefulWidget {
  const F62LocalMap({super.key});

  @override
  State<F62LocalMap> createState() => _F62LocalMapState();
}

class _F62LocalMapState extends State<F62LocalMap> {
  static const _periods = [(30, '30 days'), (90, '3 months'), (365, '1 year')];

  int _days = 90;
  String? _level; // null = all
  List<_Point>? _points;
  List<_Hotspot> _hotspots = const [];
  String? _area;
  String? _error;
  String? _savedAt; // set when showing the copy saved on the phone
  bool _loading = false;
  GpsResult _me = const GpsResult(GpsStatus.detecting);

  @override
  void initState() {
    super.initState();
    _load();
    _locate(ask: false);
  }

  String get _cacheKey => 'local_map_$_days';

  Future<void> _load() async {
    setState(() => _loading = true);
    final start = DateTime.now().subtract(Duration(days: _days));
    try {
      final data = await ApiClient.get('/analytics/hotspots', query: {'start': isoDate(start)}) as Map<String, dynamic>;
      _apply(data);
      if (mounted) setState(() => _savedAt = null);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, jsonEncode({'saved_at': DateTime.now().toIso8601String(), 'data': data}));
      } catch (_) {}
    } on ApiException catch (e) {
      final cached = e.isOffline ? await _readCache() : null;
      if (!mounted) return;
      if (cached != null) {
        _apply(cached.$2);
        setState(() {
          _savedAt = cached.$1;
          _error = null;
        });
      } else {
        setState(() => _error = e.isOffline ? 'No signal, and no saved map for this period yet.' : e.message);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<(String, Map<String, dynamic>)?> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (j['saved_at'] as String, j['data'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  void _apply(Map<String, dynamic> data) {
    if (!mounted) return;
    setState(() {
      _area = data['area'] as String?;
      _points = [
        for (final p in (data['points'] as List? ?? const []))
          if ((p as Map)['lat'] != null && p['lng'] != null) _Point.fromJson(p.cast<String, dynamic>()),
      ];
      _hotspots = [
        for (final h in (data['hotspots'] as List? ?? const [])) _Hotspot.fromJson((h as Map).cast<String, dynamic>()),
      ];
      _error = null;
    });
  }

  Future<void> _locate({required bool ask}) async {
    final r = await GpsService.getCurrentPosition(requestPermission: ask);
    if (mounted) setState(() => _me = r);
    if (ask && !r.hasFix && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Could not find your location. Turn on location and try again.')));
    }
  }

  double? _distanceTo(double lat, double lng) => _me.hasFix ? _km(_me.lat!, _me.lng!, lat, lng) : null;

  @override
  Widget build(BuildContext context) {
    final points = (_points ?? const <_Point>[]).where((p) => _level == null || p.level == _level).toList();
    final hotspots = _hotspots.where((h) => _level == null || h.level == _level).toList();
    if (_me.hasFix) {
      hotspots.sort((a, b) => _distanceTo(a.lat, a.lng)!.compareTo(_distanceTo(b.lat, b.lng)!));
    }
    final area = _area == null || _area!.isEmpty ? 'No coverage area set on your account' : _area!;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              title: 'Local map',
              subtitle: area,
              actions: [
                AppCircleButton(
                  icon: Icons.my_location_rounded,
                  tooltip: 'Show where I am',
                  color: _me.hasFix ? AppColors.sky : null,
                  onTap: () => _locate(ask: true),
                ),
              ],
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.hPad, AppSpacing.xs, AppSpacing.hPad, AppSpacing.xl),
                  children: [
                    _Filters(
                      periods: _periods,
                      days: _days,
                      level: _level,
                      onDays: (d) {
                        setState(() => _days = d);
                        _load();
                      },
                      onLevel: (l) => setState(() => _level = l),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (_savedAt != null) ...[
                      InfoBanner(
                        icon: Icons.cloud_off_rounded,
                        color: AppColors.textSecondary,
                        message: 'No signal. Showing the map saved ${formatDateTime(_savedAt)}.',
                        actionLabel: 'Retry',
                        busy: _loading,
                        onAction: _load,
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    if (_error != null && _points == null)
                      AppEmptyState(
                        icon: Icons.cloud_off_rounded,
                        title: 'Can\'t load the map',
                        message: _error!,
                        actionLabel: 'Try again',
                        onAction: _load,
                      )
                    else ...[
                      Stack(
                        children: [
                          ScanMap(
                            markers: [
                              for (final p in points)
                                ScanMarker(
                                  lat: p.lat,
                                  lng: p.lng,
                                  severity: p.level ?? '',
                                  tag: points.length <= 15 ? _pestShort[p.pestKey] : null,
                                ),
                              if (_me.hasFix) ScanMarker(lat: _me.lat!, lng: _me.lng!, isUser: true),
                            ],
                            zones: [
                              for (final h in hotspots)
                                ScanZone(
                                  lat: h.lat,
                                  lng: h.lng,
                                  radiusMeters: (220 + 70 * h.records).clamp(220, 900).toDouble(),
                                  risk: h.level,
                                ),
                            ],
                            height: 330,
                            zoom: 14,
                            interactive: true,
                            emptyMessage: _points == null ? null : 'No validated records with a location in this period.',
                          ),
                          if (_loading)
                            const Positioned(
                              top: 10,
                              right: 10,
                              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      const Wrap(
                        spacing: AppSpacing.md,
                        runSpacing: 4,
                        children: [
                          _Dot(color: AppColors.primary, label: 'Low'),
                          _Dot(color: AppColors.orange, label: 'Medium'),
                          _Dot(color: AppColors.danger, label: 'High'),
                          _Dot(color: AppColors.sky, label: 'You'),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _Totals(points: points, hotspots: hotspots, loaded: _points != null),
                      if (hotspots.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xl),
                        AppSectionHeader(title: _me.hasFix ? 'Hotspots nearest to you' : 'Hotspots'),
                        const SizedBox(height: AppSpacing.md),
                        for (final (i, h) in hotspots.take(8).indexed) ...[
                          FadeSlideIn(index: i, child: _HotspotCard(hotspot: h, distanceKm: _distanceTo(h.lat, h.lng))),
                          const SizedBox(height: AppSpacing.md),
                        ],
                      ],
                      if (points.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.lg),
                        const AppSectionHeader(title: 'Latest validated records'),
                        const SizedBox(height: AppSpacing.md),
                        AppCard(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                          child: Column(
                            children: [
                              for (final (i, p) in points.take(10).indexed) ...[
                                if (i > 0) const Divider(height: 1),
                                _PointRow(point: p, distanceKm: _distanceTo(p.lat, p.lng)),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  final List<(int, String)> periods;
  final int days;
  final String? level;
  final ValueChanged<int> onDays;
  final ValueChanged<String?> onLevel;

  const _Filters({required this.periods, required this.days, required this.level, required this.onDays, required this.onLevel});

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, bool selected, VoidCallback onTap, {Color? color}) => Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: ChoiceChip(
            label: Text(label),
            selected: selected,
            onSelected: (_) => onTap(),
            showCheckmark: false,
            selectedColor: color ?? AppColors.primaryDark,
            labelStyle: TextStyle(
              fontFamily: AppFonts.body,
              color: selected ? AppColors.surface : AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
            avatar: color == null
                ? null
                : Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: selected ? AppColors.surface : color,
                      shape: BoxShape.circle,
                    ),
                  ),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final (d, label) in periods) chip(label, days == d, () => onDays(d)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              chip('All levels', level == null, () => onLevel(null)),
              chip('Low', level == 'LOW', () => onLevel('LOW'), color: AppColors.primary),
              chip('Medium', level == 'MEDIUM', () => onLevel('MEDIUM'), color: AppColors.orange),
              chip('High', level == 'HIGH', () => onLevel('HIGH'), color: AppColors.danger),
            ],
          ),
        ),
      ],
    );
  }
}

class _Totals extends StatelessWidget {
  final List<_Point> points;
  final List<_Hotspot> hotspots;
  final bool loaded;
  const _Totals({required this.points, required this.hotspots, required this.loaded});

  @override
  Widget build(BuildContext context) {
    final high = hotspots.where((h) => h.level == 'HIGH').length;
    final pests = <String, int>{};
    for (final p in points) {
      pests[p.pest] = (pests[p.pest] ?? 0) + 1;
    }
    final top = pests.entries.isEmpty ? null : (pests.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    Widget tile(String label, Widget value, IconData icon, Color color) => Expanded(
          child: AppCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconTile(icon: icon, color: color, size: 32),
                const SizedBox(height: AppSpacing.sm),
                value,
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5)),
              ],
            ),
          ),
        );
    const numStyle = TextStyle(fontFamily: AppFonts.display, fontSize: 20, fontWeight: FontWeight.w800);
    return Row(
      children: [
        tile('Validated', loaded ? CountUp(value: points.length, style: numStyle) : const Text('–', style: numStyle),
            Icons.verified_rounded, AppColors.primary),
        const SizedBox(width: AppSpacing.sm),
        tile('High hotspots', loaded ? CountUp(value: high, style: numStyle) : const Text('–', style: numStyle),
            Icons.local_fire_department_rounded, AppColors.danger),
        const SizedBox(width: AppSpacing.sm),
        tile(
          'Most reported',
          Text(top ?? '–', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, height: 1.7)),
          Icons.bug_report_rounded,
          AppColors.orange,
        ),
      ],
    );
  }
}

class _HotspotCard extends StatelessWidget {
  final _Hotspot hotspot;
  final double? distanceKm;
  const _HotspotCard({required this.hotspot, required this.distanceKm});

  @override
  Widget build(BuildContext context) {
    final h = hotspot;
    final color = levelColor(h.level);
    return AppCard(
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 5, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    IconTile(icon: Icons.location_on_rounded, color: color, size: 42),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(h.barangay, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                          Text(
                            [h.municipality, if (distanceKm != null) _distance(distanceKm!)].join(' · '),
                            style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${plural(h.records, 'record')} · ${h.pests.join(', ')}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.35),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AppChip(label: levelLabel(h.level), color: color),
                        const SizedBox(height: 4),
                        Text(formatRelativeDay(h.latest), style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PointRow extends StatelessWidget {
  final _Point point;
  final double? distanceKm;
  const _PointRow({required this.point, required this.distanceKm});

  @override
  Widget build(BuildContext context) {
    final p = point;
    return InkWell(
      onTap: () => context.push(AppRouter.record, extra: p.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: levelColor(p.level), shape: BoxShape.circle),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.count == null ? p.pest : '${p.pest} · ${plural(p.count!, 'insect')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  Text(
                    [p.place, formatRelativeDay(p.createdAt), if (distanceKm != null) _distance(distanceKm!)]
                        .where((x) => x.isNotEmpty)
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (p.level != null) AppChip(label: levelLabel(p.level), color: levelColor(p.level)),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final String label;
  const _Dot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
        ],
      );
}
