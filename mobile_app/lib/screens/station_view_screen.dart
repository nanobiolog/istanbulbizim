import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';

import '../models/rail_models.dart';
import '../models/transit_models.dart';
import '../services/rail_engine.dart' show istanbulClock;
import '../services/transit_provider.dart';
import '../services/walking_directions_service.dart';
import '../theme/app_theme.dart';
import 'ar_navigation_screen.dart';
import 'map3d_screen.dart';

/// One station, every line calling there: live platform diagrams, official next departures per
/// direction, disruption notices, and walking directions (map, 3D or AR).
class StationViewScreen extends StatefulWidget {
  final MetroStation station;

  const StationViewScreen({super.key, required this.station});

  @override
  State<StationViewScreen> createState() => _StationViewScreenState();
}

class _StationViewScreenState extends State<StationViewScreen> {
  final _walk = WalkingDirectionsService();
  final Map<String, List<RailDeparture>> _official = {};
  WalkRoute? _route;
  bool _routing = false;
  Timer? _refresh;

  late final TransitProvider _p = context.read<TransitProvider>();
  late final List<({String line, int index, MetroStation station})> _lines = _p.linesAtStation(widget.station);

  @override
  void initState() {
    super.initState();
    _loadOfficial();
    _refresh = Timer.periodic(const Duration(minutes: 2), (_) => _loadOfficial());
    if (_p.userLocation != null) _buildRoute();
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _loadOfficial() async {
    for (final l in _lines) {
      final deps = await _p.officialDepartures(l.line, l.station.name);
      if (!mounted) return;
      if (deps != null && deps.isNotEmpty) setState(() => _official[l.line] = deps);
    }
  }

  Future<void> _buildRoute() async {
    setState(() => _routing = true);
    final me = _p.userLocation ?? await _p.locateUser();
    if (me == null) {
      if (mounted) setState(() => _routing = false);
      return;
    }
    final r = await _walk.route(me, LatLng(widget.station.lat, widget.station.lon));
    if (mounted) {
      setState(() {
        _route = r;
        _routing = false;
      });
    }
  }

  List<RailDeparture> _departures(String line, int index, String dir) {
    final now = DateTime.now().subtract(const Duration(seconds: 20));
    final official = _official[line];
    final src = (official != null && official.isNotEmpty) ? official : _p.departuresAt(line, index, perDirection: 5);
    return src.where((d) => d.dir == dir && d.at.isAfter(now)).take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<TransitProvider>(); // schedules / status / location changes
    final st = widget.station;
    final me = _p.userLocation;
    final distM = me == null ? null : const Distance().as(LengthUnit.Meter, me, LatLng(st.lat, st.lon));

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF070B14),
        foregroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(st.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
            Text(
              distM == null ? 'İstasyon görünümü' : '${WalkingDirectionsService.formatDistance(distM)} uzaklıkta',
              style: const TextStyle(color: AppTheme.textMutedDark, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '3D görünüm',
            icon: const Icon(Icons.threed_rotation_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Map3DScreen(center: LatLng(st.lat, st.lon), focusStation: st, zoom: 16.4, route: _route),
            )),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final l in _lines)
                GestureDetector(
                  onTap: () {
                    _p.selectLine(l.line);
                    Navigator.of(context).pop();
                  },
                  child: _badge(l.line),
                ),
            ],
          ),
          const SizedBox(height: 12),
          for (final l in _lines)
            for (final s in _p.railStatusFor(l.line)) _statusBanner(l.line, s),
          // trains on the platform diagrams move once a second (the map's vehicle tick may be paused)
          for (final l in _lines)
            ValueListenableBuilder<int>(valueListenable: _p.clock, builder: (_, _, _) => _lineSection(l.line, l.index)),
          const SizedBox(height: 8),
          _directionsSection(),
        ],
      ),
    );
  }

  Widget _badge(String line) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: _p.getMetroLineColor(line), borderRadius: BorderRadius.circular(7)),
        child: Text(line == 'B1' ? 'MARMARAY' : line,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
      );

  Widget _statusBanner(String line, RailStatusItem s) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFEF4444).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFFCA5A5), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text('$line • ${s.message}', style: const TextStyle(color: Color(0xFFFECACA), fontSize: 12.5, height: 1.35)),
            ),
          ],
        ),
      );

  Widget _lineSection(String line, int index) {
    final stations = _p.metroStations[line] ?? const <MetroStation>[];
    if (stations.isEmpty) return const SizedBox.shrink();
    final color = _p.getMetroLineColor(line);
    final sched = _p.railSchedule(line);
    final trains = _p.metroTrains.where((t) => t.lineCode == line).toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _badge(line),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sched == null
                      ? ''
                      : (sched.official ? 'Resmî Metro İstanbul tarifesi' : sched.source),
                  style: TextStyle(
                    color: sched?.official == true ? AppTheme.statusLive : const Color(0xFFFCD34D),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final dir in const ['G', 'D'])
            if ((dir == 'G' && index < stations.length - 1) || (dir == 'D' && index > 0))
              _platform(line, stations, index, dir, color, trains),
        ],
      ),
    );
  }

  Widget _platform(String line, List<MetroStation> stations, int index, String dir, Color color, List<MetroTrainVehicle> trains) {
    final terminus = dir == 'G' ? stations.last.name : stations.first.name;
    final deps = _departures(line, index, dir);
    final lo = math.max(0, index - 2), hi = math.min(stations.length - 1, index + 2);
    final window = [for (var i = lo; i <= hi; i++) i];
    final dots = <({double x, bool atStation})>[];
    for (final t in trains) {
      if (t.dirCode != dir) continue;
      final fromIdx = _indexOf(stations, t.prevStationName);
      if (fromIdx < 0) continue;
      final x = t.state == 'AT_STATION' ? fromIdx.toDouble() : fromIdx + (dir == 'G' ? t.progress : -t.progress);
      if (x >= lo - 0.5 && x <= hi + 0.5) dots.add((x: x, atStation: t.state == 'AT_STATION'));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(dir == 'G' ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded, color: color, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text('$terminus yönü peronu',
                    style: const TextStyle(color: AppTheme.textLight, fontWeight: FontWeight.w800, fontSize: 14)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 58,
            width: double.infinity,
            child: CustomPaint(
              painter: _PlatformStripPainter(
                names: [for (final i in window) stations[i].name],
                lo: lo,
                hi: hi,
                here: index,
                forward: dir == 'G',
                color: color,
                trains: dots,
              ),
            ),
          ),
          const SizedBox(height: 6),
          ValueListenableBuilder<int>(
            valueListenable: _p.clock,
            builder: (_, _, _) {
              if (deps.isEmpty) {
                return const Text('Şu an planlı sefer yok', style: TextStyle(color: AppTheme.textMutedDark, fontSize: 12));
              }
              return Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (var k = 0; k < deps.length; k++) _depChip(deps[k], k == 0, deps[k].headsign != terminus),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  static int _indexOf(List<MetroStation> s, String name) => s.indexWhere((x) => x.name == name);

  Widget _depChip(RailDeparture d, bool first, bool shortTurn) {
    final sec = math.max(0, d.at.difference(DateTime.now()).inSeconds);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: first ? Colors.white : Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: first ? 1 : 0.25)),
      ),
      child: Text(
        '${sec <= 30 ? 'Peronda' : BusVehicle.formatEta(sec)} • ${istanbulClock(d.at)}${shortTurn ? ' • ${d.headsign}' : ''}',
        style: TextStyle(
          color: first ? AppTheme.accentBlack : Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 12,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _directionsSection() {
    final st = widget.station;
    final r = _route;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.cardBorderDark),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.directions_walk_rounded, color: Color(0xFF38BDF8)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r == null
                      ? 'İstasyona Yol Tarifi'
                      : '${WalkingDirectionsService.formatDistance(r.distanceM)} • ${WalkingDirectionsService.formatWalk(r.durationSec)}',
                  style: const TextStyle(color: AppTheme.textLight, fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              if (_routing) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          if (r != null && !r.routed)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Yaya rotası alınamadı — kuş uçuşu yön gösteriliyor.',
                  style: TextStyle(color: Color(0xFFFCD34D), fontSize: 11)),
            ),
          const SizedBox(height: 10),
          if (r != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                height: 190,
                child: FlutterMap(
                  options: MapOptions(
                    initialCameraFit: CameraFit.bounds(
                      bounds: LatLngBounds.fromPoints(r.points),
                      padding: const EdgeInsets.all(28),
                    ),
                    interactionOptions: const InteractionOptions(flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: _p.tileUrl,
                      subdomains: const ['a', 'b', 'c', 'd'],
                      userAgentPackageName: 'com.istanbulbizim.mobile_app',
                    ),
                    PolylineLayer(polylines: [
                      Polyline(points: r.points, strokeWidth: 5, color: const Color(0xFF38BDF8), pattern: StrokePattern.dotted()),
                    ]),
                    MarkerLayer(markers: [
                      Marker(
                        point: r.points.first,
                        width: 18,
                        height: 18,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF007AFF),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                          ),
                        ),
                      ),
                      Marker(
                        point: LatLng(st.lat, st.lon),
                        width: 28,
                        height: 28,
                        child: Container(
                          decoration: BoxDecoration(color: _p.getMetroLineColor(st.lineCode), shape: BoxShape.circle),
                          child: const Icon(Icons.subway_rounded, color: Colors.white, size: 16),
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            for (final s in r.steps.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(_stepIcon(s), color: Colors.white70, size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(s.instruction, style: const TextStyle(color: AppTheme.textLight, fontSize: 13))),
                    if (s.distanceM > 0)
                      Text(WalkingDirectionsService.formatDistance(s.distanceM),
                          style: const TextStyle(color: AppTheme.textMutedDark, fontSize: 12)),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _button(
                  icon: Icons.view_in_ar_rounded,
                  label: 'AR ile Git',
                  primary: true,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ArNavigationScreen(
                      targetName: st.name,
                      target: LatLng(st.lat, st.lon),
                      targetLine: st.lineCode,
                      route: _route,
                    ),
                  )),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _button(
                  icon: r == null ? Icons.route_rounded : Icons.threed_rotation_rounded,
                  label: r == null ? 'Rota Oluştur' : '3D Rota',
                  onTap: r == null
                      ? _buildRoute
                      : () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => Map3DScreen(center: r.points.first, zoom: 16.2, tilt: 58, route: r),
                          )),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static IconData _stepIcon(WalkStep s) {
    if (s.type == 'arrive') return Icons.flag_rounded;
    if (s.type == 'depart') return Icons.directions_walk_rounded;
    if (s.type == 'roundabout' || s.type == 'rotary') return Icons.roundabout_right_rounded;
    if (s.modifier.contains('left')) return Icons.turn_left_rounded;
    if (s.modifier.contains('right')) return Icons.turn_right_rounded;
    if (s.modifier == 'uturn') return Icons.u_turn_left_rounded;
    return Icons.straight_rounded;
  }

  Widget _button({required IconData icon, required String label, required VoidCallback onTap, bool primary = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: primary ? Colors.white : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: primary ? 1 : 0.25)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: primary ? AppTheme.accentBlack : Colors.white),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: primary ? AppTheme.accentBlack : Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Schematic platform: neighbouring stations on a track, this station highlighted,
/// trains of this direction drawn where the timetable puts them right now.
class _PlatformStripPainter extends CustomPainter {
  final List<String> names;
  final int lo;
  final int hi;
  final int here;
  final bool forward;
  final Color color;
  final List<({double x, bool atStation})> trains;

  _PlatformStripPainter({
    required this.names,
    required this.lo,
    required this.hi,
    required this.here,
    required this.forward,
    required this.color,
    required this.trains,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 22.0;
    final y = 16.0;
    final span = math.max(1, hi - lo);
    double xOf(double idx) => pad + (idx - lo) / span * (size.width - 2 * pad);

    final track = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(pad - 14, y), Offset(size.width - pad + 14, y), track);

    // Direction chevrons along the track.
    final chev = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    for (var x = pad; x < size.width - pad; x += 26) {
      final p = Path();
      final s = forward ? 1.0 : -1.0;
      p.moveTo(x - 3 * s, y - 4);
      p.lineTo(x + 2 * s, y);
      p.lineTo(x - 3 * s, y + 4);
      canvas.drawPath(p, chev);
    }

    for (var k = 0; k < names.length; k++) {
      final idx = lo + k;
      final cx = xOf(idx.toDouble());
      final isHere = idx == here;
      canvas.drawCircle(Offset(cx, y), isHere ? 8 : 5.5, Paint()..color = Colors.white);
      canvas.drawCircle(
          Offset(cx, y),
          isHere ? 8 : 5.5,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = isHere ? 3.2 : 2.2);
      final tp = TextPainter(
        text: TextSpan(
          text: names[k],
          style: TextStyle(
            color: isHere ? Colors.white : Colors.white60,
            fontSize: isHere ? 10.5 : 9,
            fontWeight: isHere ? FontWeight.w900 : FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 2,
        textAlign: TextAlign.center,
        ellipsis: '…',
      )..layout(maxWidth: (size.width - 2 * pad) / math.max(1, names.length - 1) + 8);
      tp.paint(canvas, Offset((cx - tp.width / 2).clamp(0, size.width - tp.width), y + 12));
    }

    for (final t in trains) {
      final cx = xOf(t.x);
      final r = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, y), width: 26, height: 12), const Radius.circular(6));
      canvas.drawRRect(r, Paint()..color = color);
      canvas.drawRRect(
          r,
          Paint()
            ..color = t.atStation ? const Color(0xFFFEF08A) : Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6);
      final head = Path();
      final s = forward ? 1.0 : -1.0;
      head.moveTo(cx + 9 * s, y - 3);
      head.lineTo(cx + 13 * s, y);
      head.lineTo(cx + 9 * s, y + 3);
      head.close();
      canvas.drawPath(head, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _PlatformStripPainter old) => true;
}
