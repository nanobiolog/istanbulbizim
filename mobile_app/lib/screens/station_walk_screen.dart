import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../services/network_repository.dart';
import '../services/schedule_engine.dart';
import '../three_d/engine3d.dart';
import '../three_d/station_scene.dart';
import '../widgets/line_strip.dart';
import '../services/app_clock.dart';

/// First-person walk from the street down to the platform ("Walk inside").
/// Hold the button (or ↑ / W on a keyboard) to walk; the arrow button flips toward the street.
class StationWalkScreen extends StatefulWidget {
  final StationPlan plan;
  final NetworkRepository repo;
  final ScheduleEngine engine;

  const StationWalkScreen({super.key, required this.plan, required this.repo, required this.engine});

  @override
  State<StationWalkScreen> createState() => _StationWalkScreenState();
}

class _StationWalkScreenState extends State<StationWalkScreen> with SingleTickerProviderStateMixin {
  late final StationScene _scene = StationScene(widget.plan);
  late final Mesh _train = StationScene.trainModelFor(widget.plan);
  final _renderer = Renderer3D();
  final _cam = Camera3D(fovDeg: 66);
  final _focus = FocusNode();
  late final Ticker _ticker;

  double _s = 0; // metres along the walk path
  double? _target; // fast-travel target
  bool _holding = false;
  bool _towardTrains = true;
  double _yaw = 0, _pitch = 0, _lookYaw = 0, _lookPitch = 0;
  double _bob = 0;
  Duration _last = Duration.zero;
  int _frame = 0;
  Map<int, StationEvents> _events = const {};
  int _evSecond = -1;
  double _holdProgress = 0;

  @override
  void initState() {
    super.initState();
    final (x, y, z, _, _) = _scene.pointAt(0);
    final (x2, _, z2, _, _) = _scene.pointAt(6);
    _yaw = math.atan2(z2 - z, x2 - x);
    _cam
      ..ex = x
      ..ey = y + 1.65
      ..ez = z;
    _ticker = createTicker(_tick)..start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focus.dispose();
    _renderer.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.016 : ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    final (_, _, _, _, onEsc) = _scene.pointAt(_s);
    if (_target != null) {
      final d = _target! - _s;
      _s += d * math.min(1, dt * 3.2);
      if (d.abs() < 0.3) _target = null;
    } else if (_holding) {
      final speed = onEsc ? 1.6 : 1.45; // escalators move you too
      _s = (_s + (_towardTrains ? 1 : -1) * speed * dt).clamp(0, _scene.pathLength);
      _bob += dt * (onEsc ? 0 : 9.5);
    }
    _holdProgress = _holding ? (_holdProgress + dt * 0.6) % 1 : 0;

    final (x, y, z, _, esc) = _scene.pointAt(_s);
    final look = _towardTrains ? 7.0 : -7.0;
    final (lx, ly, lz, _, _) = _scene.pointAt(_s + look);
    var wantYaw = math.atan2(lz - z, lx - x);
    var wantPitch = math.atan2(ly - y, math.sqrt(math.pow(lx - x, 2) + math.pow(lz - z, 2))) * (esc ? 0.85 : 0.35);
    if (_towardTrains && _s > _scene.pathLength - 3) {
      wantYaw = math.pi / 2; // face the track at the end of the walk
      wantPitch = -0.05;
    }
    var dy = wantYaw - _yaw;
    while (dy > math.pi) {
      dy -= 2 * math.pi;
    }
    while (dy < -math.pi) {
      dy += 2 * math.pi;
    }
    _yaw += dy * math.min(1, dt * 3.5);
    _pitch += (wantPitch - _pitch) * math.min(1, dt * 3.5);
    if (!_dragging) {
      _lookYaw *= math.pow(0.2, dt).toDouble();
      _lookPitch *= math.pow(0.2, dt).toDouble();
    }
    _cam
      ..ex = x
      ..ey = y + 1.65 + (_holding && !esc ? math.sin(_bob) * 0.035 : 0)
      ..ez = z
      ..yaw = _yaw + _lookYaw
      ..pitch = (_pitch + _lookPitch).clamp(-1.2, 1.2);

    final now = AppClock.now();
    if (now.second != _evSecond) {
      _evSecond = now.second;
      _events = widget.engine.stationEvents(widget.plan.station, widget.plan.line, now);
    }
    final t = ScheduleEngine.secondsOfDay(now);
    final settling = (dy.abs() > 0.002) || (_lookYaw.abs() + _lookPitch.abs() > 0.002) || _target != null;
    final active = _holding || _dragging || settling || _events.values.any((e) => e.trainOffset(widget.plan.line, t) != null);
    if ((elapsed - _lastPaint).inMicroseconds < 1e6 / Render3DQuality.fps(active: active)) return;
    _lastPaint = elapsed;
    if (mounted) setState(() => _frame++);
  }

  Duration _lastPaint = Duration.zero;

  bool _dragging = false;

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

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final k = e.logicalKey;
    final fwd = k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.keyW;
    final backK = k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.keyS;
    if (!fwd && !backK) {
      if (k == LogicalKeyboardKey.escape && e is KeyDownEvent) Navigator.of(context).maybePop();
      return KeyEventResult.ignored;
    }
    if (e is KeyDownEvent || e is KeyRepeatEvent) {
      _towardTrains = fwd;
      _holding = true;
      _target = null;
    } else if (e is KeyUpEvent) {
      _holding = false;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final (_, y, _, stage, _) = _scene.pointAt(_s);
    final depth = -y;
    final top = MediaQuery.of(context).padding.top;
    final bottom = MediaQuery.of(context).padding.bottom;
    final stages = StationStage.values.where((st) => _scene.path.any((p) => p.stage == st)).toList();
    final indoor = depth > 0.5 || stage.index >= StationStage.passage.index;
    final maxDepth = math.max(1.0, plan.underground ? plan.depth : 1.0);

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onPanStart: (_) => _dragging = true,
                onPanEnd: (_) => _dragging = false,
                onPanCancel: () => _dragging = false,
                onPanUpdate: (d) {
                  _lookYaw = (_lookYaw + d.delta.dx * 0.006).clamp(-1.6, 1.6);
                  _lookPitch = (_lookPitch - d.delta.dy * 0.005).clamp(-0.8, 0.8);
                },
                child: CustomPaint(
                  painter: ScenePainter(
                    renderer: _renderer,
                    camera: _cam,
                    meshes: _meshes(),
                    style: indoor && plan.underground ? RenderStyle.indoor : const RenderStyle(),
                    frame: _frame,
                  ),
                ),
              ),
            ),

            // ── top bar: close · station / stage · depth ──
            Positioned(
              top: top + 8,
              left: 14,
              right: 14,
              child: Column(children: [
                Row(children: [
                  _roundButton(Icons.close_rounded, () => Navigator.of(context).pop()),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      height: 52,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: Row(children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(color: plan.line.color, shape: BoxShape.circle),
                          child: Icon(stage.icon, color: Colors.white, size: 21),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(plan.station.name.toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Color(0xFF475569), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.1)),
                            Text(_stageTitle(stage),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Color(0xFF0F172A), fontSize: 16, fontWeight: FontWeight.w800)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    height: 52,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(color: const Color(0xFF1D4ED8), borderRadius: BorderRadius.circular(26)),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(depth >= 0 ? Icons.south_rounded : Icons.north_rounded, color: Colors.white, size: 14),
                      Text(depth.abs().round() == 0 ? '0 m' : '${depth > 0 ? '−' : '+'}${depth.abs().round()} m',
                          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 10),
                LineStrip(
                  line: plan.line,
                  station: plan.station,
                  repo: widget.repo,
                  engine: widget.engine,
                  now: AppClock.now(),
                  compact: true,
                ),
              ]),
            ),

            // ── depth gauge ──
            if (plan.underground)
              Positioned(
                left: 14,
                top: MediaQuery.of(context).size.height * 0.38,
                child: Container(
                  width: 30,
                  height: 190,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(16)),
                  child: Column(children: [
                    const Text('0', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                    Expanded(
                      child: LayoutBuilder(builder: (context, c) {
                        final f = (depth / maxDepth).clamp(0.0, 1.0);
                        return Stack(alignment: Alignment.topCenter, children: [
                          Container(
                            width: 4,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(2),
                              gradient: const LinearGradient(
                                  begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF7DD3FC), Color(0xFF1D4ED8)]),
                            ),
                          ),
                          Positioned(
                            top: f * (c.maxHeight - 12),
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                  color: const Color(0xFFF5B301), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                            ),
                          ),
                        ]);
                      }),
                    ),
                    Text('${plan.depth.round()}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),

            // ── stages + hold-to-walk ──
            Positioned(
              left: 12,
              right: 12,
              bottom: bottom + 14,
              child: Column(children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final st in stages)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: GestureDetector(
                            onTap: () => setState(() {
                              _target = _scene.stageStart(st) + 0.5;
                              _towardTrains = true;
                            }),
                            child: Container(
                              width: 58,
                              height: 50,
                              decoration: BoxDecoration(
                                color: st == stage ? const Color(0xFF1D4ED8) : const Color(0xFF3A3F47).withValues(alpha: 0.86),
                                borderRadius: BorderRadius.circular(25),
                              ),
                              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                Icon(st.icon, color: Colors.white, size: 17),
                                const SizedBox(height: 2),
                                Text(st.label, style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w700)),
                              ]),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  _roundButton(_towardTrains ? Icons.u_turn_left_rounded : Icons.u_turn_right_rounded,
                      () => setState(() => _towardTrains = !_towardTrains),
                      size: 58),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Listener(
                      onPointerDown: (_) => setState(() {
                        _holding = true;
                        _target = null;
                      }),
                      onPointerUp: (_) => setState(() => _holding = false),
                      onPointerCancel: (_) => setState(() => _holding = false),
                      child: Container(
                        height: 62,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: _holding ? const Color(0xFF1E40AF) : const Color(0xFF1D4ED8),
                          borderRadius: BorderRadius.circular(31),
                          boxShadow: [BoxShadow(color: const Color(0xFF1D4ED8).withValues(alpha: 0.45), blurRadius: 16, offset: const Offset(0, 6))],
                        ),
                        child: Row(children: [
                          const Icon(Icons.directions_walk_rounded, color: Colors.white, size: 26),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(_holding ? 'Yürüyorsun…' : 'Basılı tut, yürü',
                                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                              Text(_towardTrains ? 'trenlere doğru' : 'sokağa doğru',
                                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600)),
                            ]),
                          ),
                          SizedBox(
                            width: 30,
                            height: 30,
                            child: CircularProgressIndicator(
                              value: _holding ? null : (_s / _scene.pathLength),
                              strokeWidth: 3,
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation(Color(0xFFF5B301)),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ]),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  String _stageTitle(StationStage s) => switch (s) {
        StationStage.street => 'Sokak',
        StationStage.passage => 'Geçit',
        StationStage.security => 'Güvenlik kontrolü',
        StationStage.gates => 'Turnikeler',
        StationStage.escalators => _towardTrains ? 'Yürüyen merdiven' : 'Yürüyen merdiven · çıkış',
        StationStage.platform => 'Peron',
      };

  Widget _roundButton(IconData icon, VoidCallback onTap, {double size = 52}) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: const Color(0xFF3A3F47).withValues(alpha: 0.86), shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      );
}
