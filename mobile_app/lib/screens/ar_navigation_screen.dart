import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../models/rail_models.dart';
import '../models/transit_models.dart';
import '../services/ar_heading.dart';
import '../services/rail_engine.dart' show bearingDeg, haversineM, istanbulClock;
import '../services/transit_provider.dart';
import '../services/walking_directions_service.dart';
import '../theme/app_theme.dart';

/// Location-based AR wayfinding: the camera feed with a ground arrow toward the next point of the
/// walking route, the destination pinned where it really is, nearby stations / stops as labels,
/// turn-by-turn text and live departures. Needs only GPS + compass, so it runs on every phone
/// (no ARCore / ARKit requirement).
class ArNavigationScreen extends StatefulWidget {
  final String targetName;
  final LatLng target;
  final String? targetLine; // rail line code when the destination is a station
  final BusStop? targetStop; // when the destination is a bus stop
  final WalkRoute? route;

  const ArNavigationScreen({
    super.key,
    required this.targetName,
    required this.target,
    this.targetLine,
    this.targetStop,
    this.route,
  });

  @override
  State<ArNavigationScreen> createState() => _ArNavigationScreenState();
}

class _ArNavigationScreenState extends State<ArNavigationScreen> with WidgetsBindingObserver {
  static const _proj = ArProjection();

  final _walk = WalkingDirectionsService();
  late final HeadingEstimator _heading = HeadingEstimator(calibrateHardIron: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
  late final TransitProvider _p = context.read<TransitProvider>();

  CameraController? _camera;
  String? _cameraError;
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  StreamSubscription<Position>? _posSub;
  Timer? _frame;
  Timer? _arrivalsTimer;

  LatLng? _me;
  double _accuracy = 0;
  WalkRoute? _route;
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);
  bool _routing = false;
  bool _sensorsOk = true;
  List<StopArrival> _busArrivals = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _route = widget.route;
    _me = _p.userLocation;
    _startCamera();
    _startSensors();
    _startLocation();
    // Repaint the overlay at ~30 fps from the latest sensor state.
    _frame = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (mounted) setState(() {});
    });
    if (widget.targetStop != null) {
      _loadBusArrivals();
      _arrivalsTimer = Timer.periodic(const Duration(seconds: 20), (_) => _loadBusArrivals());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _frame?.cancel();
    _arrivalsTimer?.cancel();
    _accSub?.cancel();
    _magSub?.cancel();
    _posSub?.cancel();
    _camera?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      cam.dispose();
      _camera = null;
    } else if (state == AppLifecycleState.resumed) {
      _startCamera();
    }
  }

  Future<void> _startCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw CameraException('none', 'Kamera bulunamadı');
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.high, enableAudio: false);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _camera = c;
        _cameraError = null;
      });
    } on CameraException catch (e) {
      if (mounted) {
        setState(() => _cameraError = e.code == 'CameraAccessDenied' || e.code == 'CameraAccessDeniedWithoutPrompt'
            ? 'Kamera izni verilmedi — pusula modunda devam ediliyor.'
            : 'Kamera açılamadı — pusula modunda devam ediliyor.');
      }
    } catch (_) {
      if (mounted) setState(() => _cameraError = 'Kamera açılamadı — pusula modunda devam ediliyor.');
    }
  }

  void _startSensors() {
    try {
      _accSub = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
        (e) => _heading.addAccelerometer(e.x, e.y, e.z),
        onError: (_) => _sensorsOk = false,
        cancelOnError: true,
      );
      _magSub = magnetometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
        (e) => _heading.addMagnetometer(e.x, e.y, e.z),
        onError: (_) => _sensorsOk = false,
        cancelOnError: true,
      );
    } catch (_) {
      _sensorsOk = false;
    }
  }

  Future<void> _startLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) return;
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 1),
      ).listen((pos) {
        _me = LatLng(pos.latitude, pos.longitude);
        _accuracy = pos.accuracy;
        if (pos.heading >= 0 && pos.speed > 0) _heading.applyCourse(pos.heading, pos.speed);
        _maybeReroute();
      }, onError: (_) {});
      if (_me != null) _maybeReroute();
    } catch (_) {}
  }

  Future<void> _maybeReroute() async {
    final me = _me;
    if (me == null || _routing) return;
    final r = _route;
    final off = r == null ? double.infinity : WalkingDirectionsService.progress(r, me).offRouteM;
    final stale = DateTime.now().difference(_lastReroute) > const Duration(seconds: 20);
    if (r != null && (off < 35 || !stale)) return;
    _routing = true;
    _lastReroute = DateTime.now();
    try {
      final nr = await _walk.route(me, widget.target);
      if (mounted) setState(() => _route = nr);
    } finally {
      _routing = false;
    }
  }

  Future<void> _loadBusArrivals() async {
    final stop = widget.targetStop;
    if (stop == null) return;
    final res = await _p.loadStopArrivals(stop);
    if (mounted) setState(() => _busArrivals = res);
  }

  List<RailDeparture> _railDepartures() {
    final line = widget.targetLine;
    if (line == null) return const [];
    final stations = _p.metroStations[line] ?? const <MetroStation>[];
    final idx = stations.indexWhere((s) => s.name == widget.targetName);
    if (idx < 0) return const [];
    return _p.departuresAt(line, idx, perDirection: 2);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final pad = MediaQuery.of(context).padding;
    final me = _me;
    final heading = _heading.heading;
    final route = _route;
    final prog = (me != null && route != null) ? WalkingDirectionsService.progress(route, me) : null;
    final remaining = prog?.remainingM ?? (me == null ? null : haversineM(me.latitude, me.longitude, widget.target.latitude, widget.target.longitude));
    final arrived = remaining != null && remaining < 20;
    final lookTarget = prog?.lookahead ?? widget.target;
    final arrowBearing = me == null ? null : bearingDeg(me.latitude, me.longitude, lookTarget.latitude, lookTarget.longitude);
    final targetBearing = me == null ? null : bearingDeg(me.latitude, me.longitude, widget.target.latitude, widget.target.longitude);
    final horizon = _proj.horizonY(_heading.pitch, size.height);
    final step = (route != null && prog != null && prog.nextStepIndex < route.steps.length) ? route.steps[prog.nextStepIndex] : null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Camera feed (or a dark sky/ground backdrop in compass mode)
          if (_camera != null && _camera!.value.isInitialized)
            ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: size.width,
                  height: size.width * _camera!.value.aspectRatio,
                  child: CameraPreview(_camera!),
                ),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: const [Color(0xFF0B1730), Color(0xFF111827), Color(0xFF1F2937)],
                  stops: [0, (horizon / size.height).clamp(0.05, 0.95), 1],
                ),
              ),
            ),

          // 2. Nearby stations / stops floating at their real bearing
          if (me != null && heading != null) ..._nearbyLabels(me, heading, horizon, size),

          // 3. Destination pin
          if (me != null && heading != null && targetBearing != null)
            _destinationPin(targetBearing, heading, horizon, size, remaining ?? 0, arrived),

          // 4. Ground arrow toward the next route point
          if (arrowBearing != null && heading != null && !arrived)
            Positioned(
              left: 0,
              right: 0,
              bottom: size.height * 0.2,
              child: Center(child: _GroundArrow(angleDeg: ArProjection.relative(arrowBearing, heading))),
            ),

          // 5. Top HUD: destination, distance, next instruction
          Positioned(
            top: pad.top + 8,
            left: 12,
            right: 12,
            child: _topHud(remaining, route, step, prog),
          ),

          // 6. Bottom: departures / arrivals + status
          Positioned(
            left: 12,
            right: 12,
            bottom: pad.bottom + 12,
            child: _bottomPanel(arrived, heading),
          ),
        ],
      ),
    );
  }

  Widget _topHud(double? remaining, WalkRoute? route, WalkStep? step, RouteProgress? prog) {
    final lineColor = widget.targetLine != null ? _p.getMetroLineColor(widget.targetLine!) : const Color(0xFF38BDF8);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 14, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: lineColor, borderRadius: BorderRadius.circular(8)),
                child: Icon(widget.targetStop != null ? Icons.directions_bus_rounded : Icons.subway_rounded, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.targetName,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16),
                        overflow: TextOverflow.ellipsis),
                    Text(
                      remaining == null
                          ? 'Konum bekleniyor…'
                          : '${WalkingDirectionsService.formatDistance(remaining)} • ${WalkingDirectionsService.formatWalk(remaining / WalkingDirectionsService.walkSpeedMs)}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (step != null && prog != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(width: 10),
                const Icon(Icons.turn_slight_right_rounded, color: Color(0xFF38BDF8), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${WalkingDirectionsService.formatDistance(prog.toNextStepM)} sonra: ${step.instruction}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          if (route != null && !route.routed)
            const Padding(
              padding: EdgeInsets.only(left: 10, top: 4),
              child: Text('Yaya rotası alınamadı — kuş uçuşu yön gösteriliyor.',
                  style: TextStyle(color: Color(0xFFFCD34D), fontSize: 11)),
            ),
        ],
      ),
    );
  }

  Widget _bottomPanel(bool arrived, double? heading) {
    final notes = <String>[
      ?_cameraError,
      if (!_sensorsOk || heading == null) 'Pusula sensörü okunamıyor — ok yönü kullanılamaz.',
      if (_sensorsOk && heading != null && (!_heading.hardIronReady || _heading.jitter > 12))
        'Pusulayı kalibre etmek için telefonu havada ∞ çizerek çevirin.',
      if (_accuracy > 30) 'GPS doğruluğu düşük (±${_accuracy.round()} m) — açık alana çıkın.',
    ];
    final rail = _railDepartures();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (arrived)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppTheme.statusLive, borderRadius: BorderRadius.circular(16)),
            child: Text(
              widget.targetStop != null ? 'Durağa vardınız 🎉' : 'İstasyona vardınız 🎉 Girişi ve peron yönünü tabelalardan takip edin.',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14),
            ),
          ),
        if (rail.isNotEmpty || _busArrivals.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: ValueListenableBuilder<int>(
              valueListenable: _p.clock,
              builder: (_, _, _) => Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final d in rail.take(4))
                    _chip('${d.line == 'B1' ? 'MARMARAY' : d.line} ➔ ${d.headsign}',
                        '${BusVehicle.formatEta(math.max(0, d.at.difference(DateTime.now()).inSeconds))} • ${istanbulClock(d.at)}',
                        _p.getMetroLineColor(d.line)),
                  for (final a in _busArrivals.take(4))
                    _chip('${a.line} ➔ ${a.headsign}',
                        BusVehicle.formatEta(math.max(0, a.etaAt.difference(DateTime.now()).inSeconds)), AppTheme.lineColor(a.line)),
                ],
              ),
            ),
          ),
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(10)),
              child: Text(n, style: const TextStyle(color: Color(0xFFFCD34D), fontSize: 11.5, fontWeight: FontWeight.w600)),
            ),
          ),
      ],
    );
  }

  Widget _chip(String title, String value, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.8)),
        ),
        child: Text('$title  $value',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
      );

  Widget _destinationPin(double bearing, double heading, double horizon, Size size, double dist, bool arrived) {
    final x = _proj.x(bearing, heading, size.width);
    if (x == null) {
      // Off screen: an edge hint telling which way to turn.
      final rel = ArProjection.relative(bearing, heading);
      final left = rel < 0;
      return Positioned(
        top: horizon - 28,
        left: left ? 8 : null,
        right: left ? null : 8,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: const Color(0xFF38BDF8), borderRadius: BorderRadius.circular(14)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (left) const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 18),
              Text(' ${rel.abs().round()}° ${left ? 'sola' : 'sağa'} dönün ',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
              if (!left) const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 18),
            ],
          ),
        ),
      );
    }
    // Farther targets sit closer to the horizon; scale shrinks with distance.
    final scale = (1.25 - math.log(math.max(dist, 10)) / math.ln10 * 0.22).clamp(0.6, 1.1);
    return Positioned(
      left: x - 70,
      top: horizon - 120 * scale - 30,
      width: 140,
      child: Transform.scale(
        scale: scale,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: arrived ? AppTheme.statusLive : Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12)],
              ),
              child: Column(
                children: [
                  Text(widget.targetName,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: arrived ? Colors.white : AppTheme.accentBlack, fontWeight: FontWeight.w900, fontSize: 13)),
                  Text(WalkingDirectionsService.formatDistance(dist),
                      style: TextStyle(color: arrived ? Colors.white : AppTheme.textSecondary, fontWeight: FontWeight.w700, fontSize: 12)),
                ],
              ),
            ),
            CustomPaint(size: const Size(18, 12), painter: _PinTailPainter(arrived ? AppTheme.statusLive : Colors.white)),
          ],
        ),
      ),
    );
  }

  List<Widget> _nearbyLabels(LatLng me, double heading, double horizon, Size size) {
    final out = <Widget>[];
    final items = <({String name, double bearing, double dist, Color color, IconData icon})>[];
    for (final s in _p.nearestStations(me, limit: 6, maxM: 1200)) {
      if (s.station.name == widget.targetName) continue;
      items.add((
        name: s.station.name,
        bearing: bearingDeg(me.latitude, me.longitude, s.station.lat, s.station.lon),
        dist: s.distM,
        color: _p.getMetroLineColor(s.station.lineCode),
        icon: Icons.subway_rounded,
      ));
    }
    for (final s in _p.nearestBusStops(me, limit: 5, maxM: 350)) {
      if (widget.targetStop?.code == s.stop.code) continue;
      items.add((
        name: s.stop.name,
        bearing: bearingDeg(me.latitude, me.longitude, s.stop.lat, s.stop.lon),
        dist: s.distM,
        color: Colors.white,
        icon: Icons.directions_bus_rounded,
      ));
    }
    items.sort((a, b) => b.dist.compareTo(a.dist)); // far first, near on top
    final placed = <Rect>[];
    for (final it in items) {
      final x = _proj.x(it.bearing, heading, size.width);
      if (x == null) continue;
      var y = horizon - 40 - (1 - (it.dist / 1200).clamp(0.0, 1.0)) * 30;
      var rect = Rect.fromCenter(center: Offset(x, y), width: 150, height: 34);
      while (placed.any((r) => r.overlaps(rect)) && y > 80) {
        y -= 38;
        rect = rect.shift(const Offset(0, -38));
      }
      placed.add(rect);
      out.add(Positioned(
        left: x - 75,
        top: y - 17,
        width: 150,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: it.color.withValues(alpha: 0.9), width: 1.4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(it.icon, size: 13, color: it.color == Colors.white ? Colors.white : it.color),
                const SizedBox(width: 5),
                Flexible(
                  child: Text('${it.name} • ${WalkingDirectionsService.formatDistance(it.dist)}',
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
      ));
    }
    return out;
  }
}

/// Chevron arrow lying on the ground plane, rotated toward the next route point.
class _GroundArrow extends StatelessWidget {
  final double angleDeg;

  const _GroundArrow({required this.angleDeg});

  @override
  Widget build(BuildContext context) {
    final m = Matrix4.identity()
      ..setEntry(3, 2, 0.0015)
      ..rotateX(1.05)
      ..rotateZ(angleDeg * math.pi / 180);
    return Transform(
      alignment: Alignment.center,
      transform: m,
      child: CustomPaint(size: const Size(150, 190), painter: _ArrowPainter()),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final p = Path()
      ..moveTo(s.width / 2, 0)
      ..lineTo(s.width, s.height * 0.48)
      ..lineTo(s.width * 0.68, s.height * 0.48)
      ..lineTo(s.width * 0.68, s.height)
      ..lineTo(s.width * 0.32, s.height)
      ..lineTo(s.width * 0.32, s.height * 0.48)
      ..lineTo(0, s.height * 0.48)
      ..close();
    canvas.drawShadow(p, Colors.black, 10, true);
    canvas.drawPath(
      p,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF38BDF8), Color(0xFF0EA5E9)],
        ).createShader(Offset.zero & s),
    );
    canvas.drawPath(
      p,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PinTailPainter extends CustomPainter {
  final Color color;
  _PinTailPainter(this.color);

  @override
  void paint(Canvas canvas, Size s) {
    final p = Path()
      ..moveTo(0, 0)
      ..lineTo(s.width, 0)
      ..lineTo(s.width / 2, s.height)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PinTailPainter old) => old.color != color;
}
