import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/schedule_engine.dart';
import 'engine3d.dart';
import 'station_scene.dart';
import '../services/app_clock.dart';

/// Cut-away 3D view of a station (the "Reveal" mode): street above, concourse, escalators and
/// platforms below, with trains arriving on the real schedule. Drag to orbit, pinch to zoom.
class StationRevealView extends StatefulWidget {
  final StationPlan plan;
  final ScheduleEngine engine;
  final StationStage? focus;
  final bool night;

  const StationRevealView({super.key, required this.plan, required this.engine, this.focus, this.night = false});

  @override
  State<StationRevealView> createState() => _StationRevealViewState();
}

class _StationRevealViewState extends State<StationRevealView> with SingleTickerProviderStateMixin {
  late StationScene _scene;
  late Mesh _train;
  final _renderer = Renderer3D();
  final _cam = Camera3D(fovDeg: 48, centerY: 0.26);
  late final Ticker _ticker;
  int _frame = 0;

  double _yaw = -math.pi / 2 + 0.75, _pitch = 0.62, _dist = 140;
  double _tx = 0, _ty = 0, _tz = 0;
  // animation targets
  double _gYaw = -math.pi / 2 + 0.75, _gPitch = 0.62, _gDist = 140, _gx = 0, _gy = 0, _gz = 0;
  double _scaleStartDist = 140;
  Map<int, StationEvents> _events = const {};
  int _eventsSecond = -1;

  @override
  void initState() {
    super.initState();
    _rebuild();
    _ticker = createTicker((_) => _tick())..start();
  }

  void _rebuild() {
    _scene = StationScene(widget.plan, reveal: true);
    _train = StationScene.trainModelFor(widget.plan);
    _frameDefault();
    _applyFocus(widget.focus, snap: true);
  }

  double _aspect = 0.5; // width / height of the visible area

  void _frameDefault() {
    final p = widget.plan;
    final x0 = p.xStreetTop - 30, x1 = p.platformLength / 2;
    final extent = x1 - x0;
    _gy = (p.yPlatform + 0) / 2;
    _gz = 0;
    _gPitch = 0.52;
    if (_aspect < 1.1) {
      // portrait: look down the length of the station from the street end, diagonally
      _gx = x0 + extent * 0.42;
      _gYaw = 0.5;
      _gDist = math.max(70, extent * 0.5 + p.depth.abs() * 0.7);
    } else {
      final hf = math.atan(math.tan(_cam.fovDeg * math.pi / 360) * _aspect);
      _gx = (x0 + x1) / 2;
      _gYaw = -math.pi / 2 + 0.62;
      _gDist = math.max(70, extent / 2 / math.tan(hf) * 1.05);
    }
  }

  void _applyFocus(StationStage? stage, {bool snap = false}) {
    if (stage == null) {
      _frameDefault();
    } else {
      final layer = widget.plan.layers.where((l) => l.stage == stage).firstOrNull ??
          (stage == StationStage.security ? widget.plan.layers.where((l) => l.stage == StationStage.gates).firstOrNull : null);
      if (layer != null) {
        _gx = layer.x;
        _gy = layer.y;
        _gDist = stage == StationStage.platform ? 75 : (stage == StationStage.escalators ? math.max(50, widget.plan.escalatorRun * 1.2) : 48);
        _gPitch = 0.42;
      }
    }
    if (snap) {
      _tx = _gx;
      _ty = _gy;
      _tz = _gz;
      _dist = _gDist;
      _yaw = _gYaw;
      _pitch = _gPitch;
    }
  }

  @override
  void didUpdateWidget(covariant StationRevealView old) {
    super.didUpdateWidget(old);
    if (old.plan.station.id != widget.plan.station.id || old.plan.line.code != widget.plan.line.code) {
      _rebuild();
    } else if (old.focus != widget.focus) {
      _applyFocus(widget.focus);
    }
  }

  void _tick() {
    const k = 0.12;
    _tx += (_gx - _tx) * k;
    _ty += (_gy - _ty) * k;
    _tz += (_gz - _tz) * k;
    _dist += (_gDist - _dist) * k;
    _yaw += (_gYaw - _yaw) * k;
    _pitch += (_gPitch - _pitch) * k;
    final now = AppClock.now();
    if (now.second != _eventsSecond) {
      _eventsSecond = now.second;
      _events = widget.engine.stationEvents(widget.plan.station, widget.plan.line, now);
    }
    if (mounted) setState(() => _frame++);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _renderer.dispose();
    super.dispose();
  }

  List<Mesh> _meshes() {
    final out = <Mesh>[_scene.staticMesh];
    final t = ScheduleEngine.secondsOfDay(AppClock.now());
    for (final e in _events.values) {
      final o = e.trainOffset(widget.plan.line, t);
      if (o == null) continue;
      final m = StationScene.trainAt(widget.plan, e.direction, o.$1, _train);
      if (m != null) out.add(m);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // the visible part is above the station sheet (~45 % of the height)
    final aspect = size.width / math.max(1, size.height * 0.48);
    if ((aspect < 1.1) != (_aspect < 1.1)) {
      _aspect = aspect;
      _frameDefault();
      _applyFocus(widget.focus);
    }
    _aspect = aspect;
    _cam.orbit(_tx, _ty, _tz, _dist, _yaw, _pitch);
    return GestureDetector(
      onScaleStart: (_) => _scaleStartDist = _gDist,
      onScaleUpdate: (d) {
        if (d.pointerCount >= 2) {
          _gDist = (_scaleStartDist / d.scale).clamp(25.0, 420.0);
        }
        _gYaw += d.focalPointDelta.dx * 0.008;
        _gPitch = (_gPitch + d.focalPointDelta.dy * 0.006).clamp(0.08, 1.35);
      },
      onDoubleTap: () => _applyFocus(null),
      child: Listener(
        onPointerSignal: (e) {
          // mouse wheel zoom on the website
          if (e is PointerScrollEvent) _gDist = (_gDist * (1 + e.scrollDelta.dy * 0.0012)).clamp(25.0, 420.0);
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: ScenePainter(
            renderer: _renderer,
            camera: _cam,
            meshes: _meshes(),
            style: widget.night
                ? const RenderStyle(
                    sky: Color(0xFF0F1A2E), skyBottom: Color(0xFF233249), fog: Color(0xFF1C2A40), fogStart: 260, fogEnd: 1100, ambient: 0.66)
                : const RenderStyle(fogStart: 260, fogEnd: 1100),
            labels: _scene.labels,
            frame: _frame,
          ),
        ),
      ),
    );
  }
}

/// Auto-rotating, draggable 3D model (vehicles in the info sheets).
class ModelViewer3D extends StatefulWidget {
  final Mesh mesh;
  final double height;
  final bool night;
  const ModelViewer3D({super.key, required this.mesh, this.height = 170, this.night = true});

  @override
  State<ModelViewer3D> createState() => _ModelViewer3DState();
}

class _ModelViewer3DState extends State<ModelViewer3D> with SingleTickerProviderStateMixin {
  final _renderer = Renderer3D();
  final _cam = Camera3D(fovDeg: 34);
  late final Ticker _ticker;
  double _yaw = -math.pi / 2 + 0.6, _pitch = 0.22;
  bool _dragging = false;
  int _frame = 0;
  late Mesh _ground;

  @override
  void initState() {
    super.initState();
    _ground = _groundFor(widget.mesh);
    _ticker = createTicker((_) {
      if (!_dragging) _yaw += 0.004;
      if (mounted) setState(() => _frame++);
    })..start();
  }

  Mesh _groundFor(Mesh m) {
    final r = m.radius;
    final g = Mesh();
    const segs = 28;
    for (var i = 0; i < segs; i++) {
      final a0 = i / segs * math.pi * 2, a1 = (i + 1) / segs * math.pi * 2;
      g.tri(0, -0.02, 0, math.cos(a1) * r * 0.75, -0.02, math.sin(a1) * r * 0.35, math.cos(a0) * r * 0.75, -0.02, math.sin(a0) * r * 0.35,
          widget.night ? const Color(0x55000000) : const Color(0x33000000), emissive: true);
    }
    return g;
  }

  @override
  void didUpdateWidget(covariant ModelViewer3D old) {
    super.didUpdateWidget(old);
    if (old.mesh != widget.mesh) _ground = _groundFor(widget.mesh);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.mesh.radius;
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(builder: (context, c) => _view(r, c.maxWidth, widget.height)),
    );
  }

  Widget _view(double r, double w, double h) {
    // horizontal fov from the vertical one; frame the bounding sphere across the width
    final aspect = (w.isFinite && w > 0 ? w : 360) / h;
    final vf = _cam.fovDeg * math.pi / 360;
    final hf = math.atan(math.tan(vf) * aspect);
    final dist = math.max(r / math.sin(math.min(vf, hf)) * 0.62, r / math.tan(hf) * 1.05);
    _cam.orbit(0, r * 0.08, 0, dist, _yaw, _pitch);
    return SizedBox(
      height: h,
      child: GestureDetector(
        onPanStart: (_) => _dragging = true,
        onPanEnd: (_) => _dragging = false,
        onPanCancel: () => _dragging = false,
        onPanUpdate: (d) {
          _yaw += d.delta.dx * 0.012;
          _pitch = (_pitch + d.delta.dy * 0.008).clamp(-0.05, 1.1);
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: ScenePainter(
            renderer: _renderer,
            camera: _cam,
            meshes: [_ground, widget.mesh],
            style: widget.night
                ? const RenderStyle(sky: Color(0xFF0F172A), skyBottom: Color(0xFF1E293B), fog: Color(0xFF1E293B), fogStart: 400, fogEnd: 900, ambient: 0.58)
                : const RenderStyle(sky: Color(0xFFE2E8F0), skyBottom: Color(0xFFF8FAFC), fog: Color(0xFFF1F5F9), fogStart: 400, fogEnd: 900),
            frame: _frame,
          ),
        ),
      ),
    );
  }
}
