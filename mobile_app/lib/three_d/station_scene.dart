import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/network_models.dart';
import 'engine3d.dart';
import 'vehicle_models.dart';

/// Vertical layers of a station, top to bottom — the same list the station sheet shows.
enum StationStage { street, passage, security, gates, escalators, platform }

extension StationStageText on StationStage {
  String get label => switch (this) {
        StationStage.street => 'Sokak',
        StationStage.passage => 'Geçit',
        StationStage.security => 'Güvenlik',
        StationStage.gates => 'Turnike',
        StationStage.escalators => 'Merdiven',
        StationStage.platform => 'Peron',
      };

  IconData get icon => switch (this) {
        StationStage.street => Icons.directions_walk_rounded,
        StationStage.passage => Icons.south_east_rounded,
        StationStage.security => Icons.shield_outlined,
        StationStage.gates => Icons.credit_card_rounded,
        StationStage.escalators => Icons.stairs_rounded,
        StationStage.platform => Icons.directions_subway_filled_rounded,
      };
}

/// One row of the "layers" list (Street → Gates & security → Escalators → Platforms).
class PlanLayer {
  final StationStage stage;
  final String title;
  final String subtitle;
  final IconData icon;
  final double y; // level height (m, + up)
  final double x; // focus point along the station
  const PlanLayer(this.stage, this.title, this.subtitle, this.icon, this.y, this.x);
}

/// Geometry of one station for one line, derived from the plan data.
class StationPlan {
  final NetworkStation station;
  final RailLine line;
  final StationKind kind;
  final double depth; // platform depth below street (m); negative = elevated
  final String depthSource;

  StationPlan(this.station, this.line)
      : kind = station.kindFor(line.code),
        depth = station.depthFor(line.code),
        depthSource = station.depthSourceFor(line.code);

  bool get underground => kind == StationKind.underground && depth > 1;
  bool get elevated => kind == StationKind.elevated;
  bool get isRail => line.mode == RailMode.suburban || line.mode == RailMode.metro;

  double get yPlatform => underground ? -depth : (elevated ? 8.0 : (isRail ? 1.0 : 0.3));
  double get yConcourse => underground ? -(depth * 0.38).clamp(5.0, 12.0) : 0.0;
  double get platformLength => switch (line.mode) {
        RailMode.suburban => 225,
        RailMode.metro => line.code == 'M6' ? 80 : 180,
        RailMode.tram => 50,
        RailMode.funicular => 60,
        RailMode.cable => 24,
      };
  bool get island => station.islandPlatform;
  bool get hasSecurity => underground || (isRail && !elevated);
  double get trackZ => island ? 7.0 : 1.75;

  /// Horizontal run of the main escalator bank (30° incline).
  double get escalatorRun => (yPlatform - yConcourse).abs() * 1.732;
  double get escalatorLength => (yPlatform - yConcourse).abs() * 2.0;
  double get entranceRun => underground ? (-yConcourse) * 1.732 : 0;

  // x positions along the station (platform centre = 0, the street is toward −x)
  double get xLanding => -platformLength * 0.16;
  double get xTop => xLanding - math.max(escalatorRun, 4);
  double get xGates => xTop - 10;
  double get xSecurity => xTop - 19;
  double get xConcourseStart => xTop - 34;
  double get xPassageStart => xConcourseStart - (underground ? 18 : 6);
  double get xStreetTop => xPassageStart - entranceRun;

  int get entranceCount => station.entranceCount;

  String get depthText {
    if (underground) return '${depth.round()} m';
    if (elevated) return '+${depth.abs().round()} m';
    return 'Zemin';
  }

  List<PlanLayer> get layers {
    final esc = escalatorLength;
    final escMin = math.max(1, (esc / 0.5 / 60).round());
    return [
      PlanLayer(StationStage.street, 'Sokak', '$entranceCount giriş${station.elevators > 0 ? ' · ${station.elevators} asansör' : ''}',
          Icons.directions_walk_rounded, 0, xStreetTop - 6),
      PlanLayer(
          StationStage.gates,
          underground ? 'Turnike & güvenlik' : 'Turnikeler',
          underground ? '${(-yConcourse).round()} m · X-ray, İstanbulkart' : 'Zemin kat · İstanbulkart',
          Icons.shield_outlined,
          yConcourse,
          xGates),
      if (esc > 3)
        PlanLayer(StationStage.escalators, underground ? 'Yürüyen merdiven' : 'Merdiven / asansör',
            '${esc.round()} m · yaklaşık $escMin dk', Icons.stairs_rounded, (yConcourse + yPlatform) / 2, (xTop + xLanding) / 2),
      PlanLayer(
          StationStage.platform,
          'Peronlar',
          '${underground ? '${depth.round()} m' : (elevated ? 'Viyadük +${depth.abs().round()} m' : 'Zemin seviyesi')} · ${island ? 'ada peron' : 'yan peron'}',
          Icons.directions_subway_filled_rounded,
          yPlatform,
          0),
    ];
  }
}

/// Camera path for "Walk inside".
class WalkPoint {
  final double x, y, z;
  final StationStage stage;
  final bool escalator;
  const WalkPoint(this.x, this.y, this.z, this.stage, {this.escalator = false});
}

class StationScene {
  final StationPlan plan;
  final bool reveal;
  late final Mesh staticMesh;
  final List<WalkPoint> path = [];
  late final List<double> pathCum;
  final List<Label3D> labels = [];
  final math.Random _rnd;

  StationScene(this.plan, {this.reveal = false}) : _rnd = math.Random(plan.station.name.hashCode) {
    staticMesh = Mesh();
    _build();
    pathCum = [0];
    for (var i = 1; i < path.length; i++) {
      final a = path[i - 1], b = path[i];
      pathCum.add(pathCum.last + math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2) + math.pow(b.z - a.z, 2)));
    }
  }

  double get pathLength => pathCum.last;

  // palette
  static const _tileA = Color(0xFFE9EAEC), _tileB = Color(0xFFDADCDF);
  static const _wallA = Color(0xFFE4E6E8), _wallB = Color(0xFFD5D8DB);
  static const _steel = Color(0xFF9CA3AF), _dark = Color(0xFF2B2F36);
  static const _yellow = Color(0xFFF2C230);

  Color get accent => plan.line.color;

  void _build() {
    final p = plan;
    final m = staticMesh;
    final yc = p.yConcourse, yp = p.yPlatform;

    _street();
    if (p.underground) {
      _entranceEscalator();
      _passage();
    }
    _concourse(yc);
    _escalatorBank(p.xTop, yc, p.xLanding, yp, p.island ? 0.0 : p.trackZ + 4.6);
    _platformHall(yp);

    // walk path
    final zW = p.island ? 0.0 : p.trackZ + 4.6;
    final xs = p.xStreetTop;
    path.add(WalkPoint(xs - 24, 0, -4, StationStage.street));
    path.add(WalkPoint(xs - 6, 0, 0, StationStage.street));
    if (p.underground) {
      path.add(WalkPoint(xs, 0, 0, StationStage.street, escalator: true));
      path.add(WalkPoint(p.xPassageStart, yc, 0, StationStage.passage));
      path.add(WalkPoint(p.xConcourseStart - 2, yc, 0, StationStage.passage));
    } else {
      path.add(WalkPoint(p.xConcourseStart - 2, yc, 0, StationStage.passage));
    }
    if (p.hasSecurity) {
      path.add(WalkPoint(p.xSecurity - 7, yc, 1.2, StationStage.security));
      path.add(WalkPoint(p.xSecurity + 2, yc, 0.6, StationStage.security));
    }
    path.add(WalkPoint(p.xGates - 2, yc, 0.6, StationStage.gates));
    path.add(WalkPoint(p.xGates + 3, yc, zW * 0.3, StationStage.gates));
    path.add(WalkPoint(p.xTop - 1.5, yc, zW, StationStage.escalators, escalator: true));
    path.add(WalkPoint(p.xLanding + 1.5, yp, zW, StationStage.platform));
    path.add(WalkPoint(p.xLanding + 14, yp, zW + (p.island ? 2.4 : -1.5), StationStage.platform));

    // labels (reveal mode)
    final name = p.station.name;
    labels.add(Label3D(xs - 4, 4.2, 0, name, sub: p.underground ? '${p.depth.round()} m derinlikte' : p.depthText,
        color: accent, icon: p.line.mode.icon));
    if (p.underground) {
      labels.add(Label3D(p.xGates, yc + 3.4, 0, 'Turnike & güvenlik', sub: '${yc.round()} m', icon: Icons.shield_outlined, dark: true));
    }
    if (p.escalatorLength > 3) {
      labels.add(Label3D((p.xTop + p.xLanding) / 2, (yc + yp) / 2 + 3, zW, 'Yürüyen merdiven',
          sub: '${p.escalatorLength.round()} m · ${math.max(1, (p.escalatorLength / 0.5 / 60).round())} dk', icon: Icons.stairs_rounded, dark: true));
    }
    labels.add(Label3D(p.platformLength * 0.15, yp + 4.2, 0, 'Peronlar', sub: p.underground ? '${yp.round()} m' : p.depthText,
        icon: Icons.directions_subway_filled_rounded, dark: true));
    // entrance labels
    final n = math.min(4, p.entranceCount);
    for (var i = 0; i < n; i++) {
      final e = i < p.station.entrances.length ? p.station.entrances[i] : null;
      final ref = (e != null && e.ref.isNotEmpty) ? e.ref : '${i + 1}';
      final ex = xs - 4 + (i.isEven ? 0 : 28.0) * (i > 1 ? -1 : 1), ez = i == 0 ? 0.0 : (i == 1 ? -14.0 : (i == 2 ? 14.0 : -26.0));
      if (i > 0) _miniEntrance(ex, ez);
      labels.add(Label3D(ex, 3.6, ez, 'Giriş $ref', icon: Icons.directions_walk_rounded, color: const Color(0xFF111827)));
    }
    if (m.triangles == 0) m.tri(0, 0, 0, 1, 0, 0, 0, 0, 1, Colors.transparent);
  }

  // ───────── street level ─────────

  void _street() {
    final p = plan;
    final m = staticMesh;
    final xs = p.xStreetTop;
    final alpha = reveal ? 0x70 : 0xFF;
    Color a(Color c) => c.withAlpha(alpha);
    final half = p.platformLength / 2;
    final px1 = p.underground ? xs + 30 : math.min(xs + 30, -half - 1);
    // plaza
    m.tiledFloor(xs - 36, -22, px1, 22, 0, 3, a(const Color(0xFFD9D7D2)), a(const Color(0xFFCFCCC6)));
    // roads around the plaza
    m.tiledFloor(xs - 36, 22, xs + 30, 34, -0.02, 11, a(const Color(0xFF6B7280)), a(const Color(0xFF656B74)));
    m.tiledFloor(xs - 36, -34, xs + 30, -22, -0.02, 11, a(const Color(0xFF6B7280)), a(const Color(0xFF656B74)));
    if (!p.underground) {
      // ground beside the open-air tracks
      final wz = (p.island ? p.trackZ + 3.4 : p.trackZ + 8.2);
      m.tiledFloor(-half - 1, wz, half + 40, 34, -0.02, 12, a(const Color(0xFFCFCCC6)), a(const Color(0xFFC8C5BF)));
      m.tiledFloor(-half - 1, -34, half + 40, -wz, -0.02, 12, a(const Color(0xFFCFCCC6)), a(const Color(0xFFC8C5BF)));
    }
    for (var x = xs - 34; x < xs + 28; x += 6) {
      m.quad([x, 0.0, 27.9], [x + 3, 0.0, 27.9], [x + 3, 0.0, 28.2], [x, 0.0, 28.2], a(Colors.white), emissive: true);
      m.quad([x, 0.0, -28.2], [x + 3, 0.0, -28.2], [x + 3, 0.0, -27.9], [x, 0.0, -27.9], a(Colors.white), emissive: true);
    }
    // the rest of the ground (big, faded by fog)
    if (!reveal) {
      m.tiledFloor(xs - 160, -160, xs - 36, 160, -0.03, 40, const Color(0xFFCBC8C2), const Color(0xFFC6C3BD));
      m.tiledFloor(xs + 30, -160, xs + 260, 160, -0.03, 40, const Color(0xFFCBC8C2), const Color(0xFFC6C3BD));
      m.tiledFloor(xs - 36, 34, xs + 30, 160, -0.03, 40, const Color(0xFFCBC8C2), const Color(0xFFC6C3BD));
      m.tiledFloor(xs - 36, -160, xs + 30, -34, -0.03, 40, const Color(0xFFCBC8C2), const Color(0xFFC6C3BD));
    }
    // buildings (Istanbul pastel facades with tiled roofs)
    const facades = [Color(0xFFEFE3C8), Color(0xFFF2C9A5), Color(0xFFF3E3A0), Color(0xFFC9DCEB), Color(0xFFE9B7A6), Color(0xFFF1F1EE)];
    void building(double x0, double z0, double w, double d, int floors) {
      final col = facades[_rnd.nextInt(facades.length)];
      final h = floors * 3.2 + 1.0;
      m.box(x0, 0, z0, x0 + w, h, z0 + d, col, top: const Color(0xFFB5523B), faces: 63 - 2);
      // ground floor shop band
      m.box(x0 - 0.05, 0, z0 - 0.05, x0 + w + 0.05, 3.4, z0 + d + 0.05, col.withValues(alpha: 1), faces: 4 | 8 | 16 | 32,
          side: Color.lerp(col, Colors.black, 0.08));
      final shop = [const Color(0xFFB91C1C), const Color(0xFF1D4ED8), const Color(0xFF047857), const Color(0xFFD97706)][_rnd.nextInt(4)];
      for (final z in [z0 - 0.07, z0 + d + 0.07]) {
        m.quad([x0 + 0.6, 2.7, z], [x0 + w - 0.6, 2.7, z], [x0 + w - 0.6, 3.3, z], [x0 + 0.6, 3.3, z], shop);
        final nWin = math.max(1, (w / 2.6).floor());
        for (var f = 1; f < floors; f++) {
          for (var k = 0; k < nWin; k++) {
            final wx = x0 + 0.8 + k * (w - 1.6) / nWin;
            final wy = 1.0 + f * 3.2 + 0.4;
            m.quad([wx, wy, z], [wx + 1.1, wy, z], [wx + 1.1, wy + 1.6, z], [wx, wy + 1.6, z], const Color(0xFF5B6670));
          }
        }
      }
      // roof ridge
      m.quad([x0, h, z0], [x0 + w, h, z0], [x0 + w * 0.5 + w * 0.3, h + 1.6, z0 + d / 2], [x0 + w * 0.5 - w * 0.3, h + 1.6, z0 + d / 2],
          const Color(0xFFA9452F));
      m.quad([x0, h, z0 + d], [x0 + w * 0.5 - w * 0.3, h + 1.6, z0 + d / 2], [x0 + w * 0.5 + w * 0.3, h + 1.6, z0 + d / 2], [x0 + w, h, z0 + d],
          const Color(0xFF9C3F2B));
    }

    if (!reveal) {
      for (var i = 0; i < 6; i++) {
        building(xs - 34 + i * 11.0, 35 + _rnd.nextDouble() * 3, 9 + _rnd.nextDouble() * 2, 10, 3 + _rnd.nextInt(3));
        building(xs - 34 + i * 11.0, -47 - _rnd.nextDouble() * 3, 9 + _rnd.nextDouble() * 2, 10, 3 + _rnd.nextInt(3));
      }
      for (var k = 0; k < 4; k++) {
        building(xs - 58 - _rnd.nextDouble() * 4, -30 + k * 15.0, 12, 12, 3 + _rnd.nextInt(3));
      }
      // streets continuing past the entrance (in view while walking toward it)
      for (var i = 0; i < 9; i++) {
        final bx = xs + 34 + i * 13.0;
        building(bx, 24 + _rnd.nextDouble() * 3, 11 + _rnd.nextDouble() * 1.5, 11, 3 + _rnd.nextInt(4));
        building(bx, -36 - _rnd.nextDouble() * 3, 11 + _rnd.nextDouble() * 1.5, 11, 3 + _rnd.nextInt(4));
      }
      for (var k = 0; k < 5; k++) {
        building(xs + 152 + _rnd.nextDouble() * 6, -40 + k * 17.0, 14, 14, 4 + _rnd.nextInt(4));
      }
      // plaza trees
      for (var i = 0; i < 6; i++) {
        final tx = xs - 30 + i * 11.0;
        for (final tz in [16.5, -16.5]) {
          m.cylinder(tx, tz, 0, 2.4, 0.18, const Color(0xFF6B4F32), seg: 6);
          m.box(tx - 1.5, 2.2, tz - 1.5, tx + 1.5, 4.6, tz + 1.5, const Color(0xFF5E8C4A), top: const Color(0xFF6FA055));
          m.box(tx - 1.0, 4.6, tz - 1.0, tx + 1.0, 5.6, tz + 1.0, const Color(0xFF6FA055));
        }
      }
    }
    // street lamps
    for (var x = xs - 30; x < xs + 26; x += 14) {
      m.cylinder(x, 20.5, 0, 5.2, 0.09, _dark, seg: 6);
      m.box(x - 0.4, 5.2, 20.3, x + 0.4, 5.45, 20.7, _dark);
      m.cylinder(x, -20.5, 0, 5.2, 0.09, _dark, seg: 6);
      m.box(x - 0.4, 5.2, -20.7, x + 0.4, 5.45, -20.3, _dark);
    }
    // entrance canopy (glass box with line-colour frame)
    if (plan.underground) {
      final x0 = xs - 5, x1 = xs + 7;
      final glass = const Color(0x553B82F6);
      m.box(x0, 3.2, -3.4, x1, 3.45, 3.4, accent, top: const Color(0xFFE5E7EB));
      for (final z in [-3.4, 3.4]) {
        m.quad([x0, 0, z], [x1, 0, z], [x1, 3.2, z], [x0, 3.2, z], glass);
        for (var x = x0; x <= x1; x += 3) {
          m.box(x - 0.06, 0, z - 0.06, x + 0.06, 3.2, z + 0.06, const Color(0xFF374151));
        }
      }
      m.quad([x1, 0, -3.4], [x1, 0, 3.4], [x1, 3.2, 3.4], [x1, 3.2, -3.4], glass);
      // sign on the canopy
      m.quad([x0 - 0.02, 2.4, -2.2], [x0 - 0.02, 2.4, 2.2], [x0 - 0.02, 3.15, 2.2], [x0 - 0.02, 3.15, -2.2], accent, emissive: true);
      m.quad([x0 - 0.03, 2.55, -2.0], [x0 - 0.03, 2.55, -1.2], [x0 - 0.03, 3.0, -1.2], [x0 - 0.03, 3.0, -2.0], Colors.white, emissive: true);
    } else {
      // surface station shelter
      final x0 = plan.xConcourseStart - 4, x1 = plan.xTop + 4;
      m.box(x0, 3.4, -9, x1, 3.6, 9, const Color(0xFFE5E7EB), top: accent);
      for (var x = x0; x <= x1; x += 6) {
        m.cylinder(x, -8.5, 0, 3.4, 0.12, _steel, seg: 6);
        m.cylinder(x, 8.5, 0, 3.4, 0.12, _steel, seg: 6);
      }
    }
  }

  void _miniEntrance(double x, double z) {
    final m = staticMesh;
    final alpha = reveal ? 0xC0 : 0xFF;
    m.box(x - 3, 2.9, z - 2, x + 3, 3.1, z + 2, accent.withAlpha(alpha));
    for (final dz in [-2.0, 2.0]) {
      m.box(x - 3, 0, z + dz - 0.05, x + 3, 1.0, z + dz + 0.05, const Color(0xFF9CA3AF).withAlpha(alpha));
    }
    m.cylinder(x - 2.9, z - 1.9, 0, 2.9, 0.07, _dark, seg: 5);
    m.cylinder(x + 2.9, z + 1.9, 0, 2.9, 0.07, _dark, seg: 5);
  }

  // ───────── underground ─────────

  void _entranceEscalator() {
    final p = plan;
    final yc = p.yConcourse;
    final xa = p.xStreetTop, xb = p.xPassageStart;
    final m = staticMesh;
    // shaft walls & ceiling
    if (!reveal) {
      m.box(xa - 1, -1.0, -3.4, xb + 0.5, 3.2, -3.3, _wallA, faces: 32);
      m.box(xa - 1, yc, 3.3, xb + 0.5, 0.0, 3.4, _wallA, faces: 16);
      _slopedCeiling(xa - 1, 3.2, xb, yc + 4.2, -3.4, 3.4);
    }
    _escalators(xa, 0, xb, yc, 0, count: 2);
    // stairs alongside
    m.ramp(xa, 0, xb, yc, 2.0, 3.2, const Color(0xFFC9CCD0), steps: math.max(8, ((-yc) / 0.18).round() ~/ 2), alt: const Color(0xFFB8BCC1));
    m.ramp(xa, 0, xb, yc, -3.2, -2.0, const Color(0xFFC9CCD0), steps: math.max(8, ((-yc) / 0.18).round() ~/ 2), alt: const Color(0xFFB8BCC1));
  }

  void _slopedCeiling(double xa, double ya, double xb, double yb, double z0, double z1) {
    final n = math.max(2, ((xb - xa) / 4).round());
    for (var i = 0; i < n; i++) {
      final t0 = i / n, t1 = (i + 1) / n;
      final x0 = xa + (xb - xa) * t0, x1 = xa + (xb - xa) * t1;
      final y0 = ya + (yb - ya) * t0, y1 = ya + (yb - ya) * t1;
      staticMesh.quad([x0, y0, z0], [x1, y1, z0], [x1, y1, z1], [x0, y0, z1], i.isEven ? const Color(0xFFDDE0E3) : const Color(0xFFD3D6DA));
      // light strip
      staticMesh.quad([x0 + 0.3, y0 - 0.02, -0.3], [x1 - 0.3, y1 - 0.02, -0.3], [x1 - 0.3, y1 - 0.02, 0.3], [x0 + 0.3, y0 - 0.02, 0.3],
          Colors.white, emissive: true);
    }
  }

  void _escalators(double xa, double ya, double xb, double yb, double zc, {int count = 3}) {
    final m = staticMesh;
    const w = 1.0, gap = 0.55;
    final total = count * w + (count - 1) * gap;
    final steps = math.max(10, ((ya - yb).abs() / 0.2).round());
    for (var i = 0; i < count; i++) {
      final z0 = zc - total / 2 + i * (w + gap), z1 = z0 + w;
      m.ramp(xa, ya, xb, yb, z0, z1, const Color(0xFF4B5563), steps: math.min(steps, 60), alt: const Color(0xFF3F4652));
      // yellow comb lines at ends
      m.quad([xa - 0.4, ya + 0.01, z0], [xa, ya + 0.01, z0], [xa, ya + 0.01, z1], [xa - 0.4, ya + 0.01, z1], _yellow, emissive: true);
      m.quad([xb, yb + 0.01, z0], [xb + 0.4, yb + 0.01, z0], [xb + 0.4, yb + 0.01, z1], [xb, yb + 0.01, z1], _yellow, emissive: true);
      // balustrades with black handrails
      for (final z in [z0 - 0.12, z1 + 0.12]) {
        m.quad([xa, ya, z], [xb, yb, z], [xb, yb + 1.0, z], [xa, ya + 1.0, z], const Color(0x66C7D2FE));
        m.quad([xa - 0.8, ya + 1.0, z - 0.05], [xb + 0.8, yb + 1.0, z - 0.05], [xb + 0.8, yb + 1.1, z + 0.05], [xa - 0.8, ya + 1.1, z + 0.05],
            const Color(0xFF111111));
      }
    }
  }

  void _passage() {
    final p = plan;
    final m = staticMesh;
    final yc = p.yConcourse;
    final x0 = p.xPassageStart, x1 = p.xConcourseStart;
    m.tiledFloor(x0, -3.4, x1, 3.4, yc, 1.7, _tileA, _tileB);
    if (!reveal) {
      m.wallX(x0, x1, yc, yc + 3.6, -3.4, 1.2, _wallA, _wallB);
      m.wallX(x0, x1, yc, yc + 3.6, 3.4, 1.2, _wallA, _wallB);
      m.quad([x0, yc + 3.6, -3.4], [x1, yc + 3.6, -3.4], [x1, yc + 3.6, 3.4], [x0, yc + 3.6, 3.4], const Color(0xFFDCDFE2));
      for (var x = x0 + 1; x < x1 - 1; x += 3.5) {
        m.quad([x, yc + 3.58, -0.25], [x + 2.4, yc + 3.58, -0.25], [x + 2.4, yc + 3.58, 0.25], [x, yc + 3.58, 0.25], Colors.white, emissive: true);
      }
    } else {
      m.wallX(x0, x1, yc, yc + 3.6, -3.4, 2.4, _wallA, _wallB);
    }
    // line-colour stripe
    for (final z in reveal ? [-3.38] : [-3.38, 3.38]) {
      m.quad([x0, yc + 2.4, z], [x1, yc + 2.4, z], [x1, yc + 2.65, z], [x0, yc + 2.65, z], accent, emissive: true);
    }
  }

  void _concourse(double yc) {
    final p = plan;
    final m = staticMesh;
    final x0 = p.xConcourseStart, x1 = p.xTop + 4;
    const hw = 9.0;
    m.tiledFloor(x0, -hw, x1, hw, yc + (plan.underground ? 0 : 0.03), 2, _tileA, _tileB);
    final ceil = yc + 4.4;
    if (plan.underground) {
      m.wallX(x0, x1, yc, ceil, -hw, 1.5, _wallA, _wallB);
      m.quad([x0, yc + 2.6, -hw + 0.02], [x1, yc + 2.6, -hw + 0.02], [x1, yc + 2.9, -hw + 0.02], [x0, yc + 2.9, -hw + 0.02], accent, emissive: true);
      if (!reveal) {
        m.wallX(x0, x1, yc, ceil, hw, 1.5, _wallA, _wallB);
        m.quad([x0, yc + 2.6, hw - 0.02], [x1, yc + 2.6, hw - 0.02], [x1, yc + 2.9, hw - 0.02], [x0, yc + 2.9, hw - 0.02], accent, emissive: true);
        m.wallZ(-hw, -3.4, yc, ceil, x0, 1.5, _wallA, _wallB);
        m.wallZ(3.4, hw, yc, ceil, x0, 1.5, _wallA, _wallB);
        m.tiledFloor(x0, -hw, x1, hw, ceil, 3, const Color(0xFFD9DCDF), const Color(0xFFD1D4D8));
        // light strips (as in the reference: long white diagonals)
        for (var x = x0 + 2; x < x1 - 2; x += 5) {
          m.quad([x, ceil - 0.03, -hw + 1], [x + 0.5, ceil - 0.03, -hw + 1], [x + 2.5, ceil - 0.03, hw - 1], [x + 2.0, ceil - 0.03, hw - 1],
              Colors.white, emissive: true);
        }
      }
      // columns
      for (var x = x0 + 6; x < x1 - 2; x += 9) {
        m.box(x - 0.5, yc, -6.2, x + 0.5, ceil, -5.2, const Color(0xFFCDD1D5));
        m.box(x - 0.5, yc, 5.2, x + 0.5, ceil, 6.2, const Color(0xFFCDD1D5));
      }
      // "Peronlar · Platforms" sign
      final sx = p.xTop - 4;
      m.box(sx, ceil - 1.1, -2.6, sx + 0.12, ceil - 0.5, 2.6, const Color(0xFF1D4ED8), emissive: true);
      m.quad([sx - 0.01, ceil - 0.95, -2.3], [sx - 0.01, ceil - 0.95, -1.6], [sx - 0.01, ceil - 0.65, -1.6], [sx - 0.01, ceil - 0.65, -2.3],
          Colors.white, emissive: true);
    }
    // security: X-ray machines + queue belts
    final xs = p.xSecurity;
    for (final z in p.hasSecurity ? [-3.2, 3.2] : const <double>[]) {
      m.box(xs - 1.4, yc, z - 0.6, xs + 1.4, yc + 1.2, z + 0.6, const Color(0xFF94A3B8), top: const Color(0xFF475569));
      m.box(xs - 0.5, yc + 1.2, z - 0.55, xs + 0.5, yc + 1.9, z + 0.55, const Color(0xFFCBD5E1));
      m.quad([xs - 2.6, yc + 0.8, z - 0.4], [xs - 1.4, yc + 0.8, z - 0.4], [xs - 1.4, yc + 0.8, z + 0.4], [xs - 2.6, yc + 0.8, z + 0.4],
          const Color(0xFF111827));
      // walk-through detector
      m.box(xs + 2.6, yc, z + 1.0, xs + 2.8, yc + 2.2, z + 1.15, const Color(0xFFE5E7EB));
      m.box(xs + 2.6, yc, z + 2.0, xs + 2.8, yc + 2.2, z + 2.15, const Color(0xFFE5E7EB));
      m.box(xs + 2.6, yc + 2.2, z + 1.0, xs + 2.8, yc + 2.4, z + 2.15, const Color(0xFFE5E7EB));
    }
    for (var row = 0; row < (p.hasSecurity ? 3 : 0); row++) {
      final z = -1.0 + row * 1.0;
      for (var k = 0; k < 4; k++) {
        final x = xs - 8 + k * 1.7;
        m.cylinder(x, z, yc, yc + 1.0, 0.05, _dark, seg: 5);
        if (k < 3) m.box(x, yc + 0.88, z - 0.03, x + 1.7, yc + 0.98, z + 0.03, const Color(0xFF1D4ED8));
      }
    }
    // gates (turnstiles)
    final xg = p.xGates;
    for (var i = 0; i < 8; i++) {
      final z = -6.3 + i * 1.8;
      m.box(xg - 0.6, yc, z - 0.17, xg + 0.6, yc + 1.05, z + 0.17, const Color(0xFF374151), top: const Color(0xFF1F2937));
      m.quad([xg - 0.61, yc + 0.82, z - 0.1], [xg - 0.61, yc + 0.82, z + 0.1], [xg - 0.61, yc + 0.98, z + 0.1], [xg - 0.61, yc + 0.98, z - 0.1],
          const Color(0xFF22C55E), emissive: true);
      if (i < 7) {
        m.quad([xg, yc + 0.35, z + 0.17], [xg, yc + 0.35, z + 1.63], [xg, yc + 1.1, z + 1.63], [xg, yc + 1.1, z + 0.17], const Color(0x88BFDBFE));
      }
    }
  }

  void _escalatorBank(double xa, double ya, double xb, double yb, double zc) {
    if ((ya - yb).abs() < 1.5) {
      staticMesh.ramp(xa, ya, xb, yb, zc - 2.5, zc + 2.5, const Color(0xFFCBCDD1));
      return;
    }
    final m = staticMesh;
    _escalators(xa, ya, xb, yb, zc, count: 3);
    // shaft
    final yTopCeil = ya + 4.4, yBotCeil = yb + 5.0;
    if (!reveal) {
      _slopedCeiling(xa, yTopCeil, xb, yBotCeil, zc - 3.2, zc + 3.2);
      final n = math.max(2, ((xb - xa).abs() / 3).round());
      for (var i = 0; i < n; i++) {
        final t0 = i / n, t1 = (i + 1) / n;
        final x0 = xa + (xb - xa) * t0, x1 = xa + (xb - xa) * t1;
        final y0 = ya + (yb - ya) * t0, y1 = ya + (yb - ya) * t1;
        for (final z in [zc - 3.2, zc + 3.2]) {
          m.quad([x0, y0 - 0.5, z], [x1, y1 - 0.5, z], [x1, y1 + 4.6, z], [x0, y0 + 4.6, z], i.isEven ? _wallA : _wallB);
        }
      }
    } else {
      // cut-away: show only the far wall, translucent
      final n = math.max(2, ((xb - xa).abs() / 6).round());
      for (var i = 0; i < n; i++) {
        final t0 = i / n, t1 = (i + 1) / n;
        final x0 = xa + (xb - xa) * t0, x1 = xa + (xb - xa) * t1;
        final y0 = ya + (yb - ya) * t0, y1 = ya + (yb - ya) * t1;
        m.quad([x0, y0 - 0.5, zc - 3.2], [x1, y1 - 0.5, zc - 3.2], [x1, y1 + 4.6, zc - 3.2], [x0, y0 + 4.6, zc - 3.2], const Color(0xAAD5D8DB));
      }
    }
  }

  void _platformHall(double yp) {
    final p = plan;
    final m = staticMesh;
    final half = p.platformLength / 2;
    final tz = p.trackZ;
    final ext = reveal ? 25.0 : 160.0;
    final wallZ = p.island ? tz + 3.4 : tz + 8.2;
    final ceil = yp + (p.underground ? 6.0 : 4.2);
    // platform floor(s)
    if (p.island) {
      m.tiledFloor(-half, -tz + 1.6, half, tz - 1.6, yp, 2.5, _tileA, _tileB);
      for (final z in [-tz + 1.6, tz - 2.2]) {
        m.quad([-half, yp + 0.005, z], [half, yp + 0.005, z], [half, yp + 0.005, z + 0.6], [-half, yp + 0.005, z + 0.6], _yellow, emissive: true);
      }
    } else {
      for (final s in [-1.0, 1.0]) {
        final z0 = s > 0 ? tz + 1.6 : -tz - 1.6 - 5, z1 = z0 + 5;
        m.tiledFloor(-half, z0, half, z1, yp, 2.5, _tileA, _tileB);
        final ez = s > 0 ? z0 : z1 - 0.6;
        m.quad([-half, yp + 0.005, ez], [half, yp + 0.005, ez], [half, yp + 0.005, ez + 0.6], [-half, yp + 0.005, ez + 0.6], _yellow, emissive: true);
      }
    }
    // track beds & rails
    final yb = yp - 1.1;
    for (final s in [-1.0, 1.0]) {
      final zc = s * tz;
      m.tiledFloor(-half - ext, zc - 1.6, half + ext, zc + 1.6, yb, 20, const Color(0xFF4A4F57), const Color(0xFF454A52));
      for (var x = -half - math.min(ext, 30); x < half + math.min(ext, 30); x += 1.6) {
        m.quad([x, yb + 0.02, zc - 1.2], [x + 0.35, yb + 0.02, zc - 1.2], [x + 0.35, yb + 0.02, zc + 1.2], [x, yb + 0.02, zc + 1.2],
            const Color(0xFF6B7078));
      }
      for (final rz in [zc - 0.72, zc + 0.72]) {
        m.box(-half - ext, yb + 0.02, rz - 0.04, half + ext, yb + 0.18, rz + 0.04, const Color(0xFF9CA3AF), top: const Color(0xFFE5E7EB));
      }
      // platform edge wall
      final ez = s * (p.island ? tz - 1.6 : tz + 1.6);
      m.quad([-half, yb, ez], [half, yb, ez], [half, yp, ez], [-half, yp, ez], const Color(0xFF7B8088));
    }
    if (p.underground) {
      // back walls with tiles + accent stripe (both in walk mode, far one only in reveal)
      for (final s in reveal ? [-1.0] : [-1.0, 1.0]) {
        final z = s * wallZ;
        m.wallX(-half - ext, half + ext, yb, ceil, z, reveal ? 6 : 3, _wallA, _wallB);
        m.quad([-half, yp + 2.6, z - s * 0.02], [half, yp + 2.6, z - s * 0.02], [half, yp + 2.95, z - s * 0.02], [-half, yp + 2.95, z - s * 0.02],
            accent, emissive: true);
        // station name boards
        for (var x = -half + 20; x < half - 10; x += 40) {
          m.quad([x, yp + 3.4, z - s * 0.03], [x + 8, yp + 3.4, z - s * 0.03], [x + 8, yp + 4.3, z - s * 0.03], [x, yp + 4.3, z - s * 0.03],
              const Color(0xFF1D4ED8), emissive: true);
        }
      }
      if (!reveal) {
        m.tiledFloor(-half - ext, -wallZ, half + ext, wallZ, ceil, 6, const Color(0xFFD8DBDE), const Color(0xFFCFD3D7));
        for (var x = -half; x < half; x += 7) {
          m.quad([x, ceil - 0.03, -1.2], [x + 4.5, ceil - 0.03, -1.2], [x + 4.5, ceil - 0.03, 1.2], [x, ceil - 0.03, 1.2], Colors.white, emissive: true);
        }
      }
    }
    // columns & benches on the island
    if (p.island) {
      for (var x = -half + 10; x < half - 5; x += 15) {
        if ((x - p.xLanding).abs() < 9) continue;
        m.box(x - 0.45, yp, -0.45, x + 0.45, ceil, 0.45, const Color(0xFFE2E5E8));
        m.box(x + 2, yp + 0.4, -0.3, x + 4.4, yp + 0.5, 0.3, const Color(0xFF8B5E34));
        m.box(x + 2.1, yp, -0.25, x + 2.2, yp + 0.4, 0.25, _dark);
        m.box(x + 4.2, yp, -0.25, x + 4.3, yp + 0.4, 0.25, _dark);
      }
    } else {
      for (var x = -half + 12; x < half - 5; x += 18) {
        for (final s in [-1.0, 1.0]) {
          final z = s * (tz + 5.5);
          m.box(x - 0.35, yp, z - 0.35, x + 0.35, ceil, z + 0.35, const Color(0xFFE2E5E8));
        }
      }
      if (!p.underground) {
        for (final s in [-1.0, 1.0]) {
          final z0 = s > 0 ? tz + 1.6 : -tz - 6.6;
          m.box(-half * 0.6, ceil, z0, half * 0.6, ceil + 0.2, z0 + 5, const Color(0xFFE5E7EB), top: accent);
        }
      }
    }
    if (p.elevated) {
      // viaduct deck & piers
      m.box(-half - 40, yb - 1.2, -wallZ, half + 40, yb, wallZ, const Color(0xFFBFC3C8));
      for (var x = -half - 30; x < half + 40; x += 25) {
        m.box(x - 1, 0, -2, x + 1, yb - 1.2, 2, const Color(0xFFAEB3B9));
      }
    }
  }

  // ───────── dynamic: trains ─────────

  /// Train mesh for the platform track in [direction] (+1/−1) at signed distance [offset] (m)
  /// from its stopping point (negative = still approaching).
  static Mesh? trainAt(StationPlan plan, int direction, double offset, Mesh trainModel) {
    if (offset.abs() > 420) return null;
    final m = Mesh();
    final z = direction > 0 ? plan.trackZ : -plan.trackZ;
    final x = direction * offset;
    m.addTransformed(trainModel, x, plan.yPlatform - 1.1 + 0.18, z, yaw: direction > 0 ? 0 : math.pi);
    return m;
  }

  static Mesh trainModelFor(StationPlan plan) {
    final carLen = plan.line.mode == RailMode.suburban ? 22.5 : (plan.line.mode == RailMode.tram ? 6.6 : 20.0);
    final cars = (plan.platformLength * 0.92 / (carLen + 0.7)).floor().clamp(2, 8);
    final kind = switch (plan.line.mode) {
      RailMode.suburban => VehicleKind.marmaray,
      RailMode.tram => (plan.line.code == 'T2' || plan.line.code == 'T3') ? VehicleKind.nostalgicTram : VehicleKind.tram,
      RailMode.funicular => VehicleKind.funicular,
      RailMode.cable => VehicleKind.cable,
      RailMode.metro => VehicleKind.metro,
    };
    return VehicleModels.build(kind, accent: plan.line.color, cars: cars);
  }

  /// Distance offset of a train relative to its stop from schedule times (seconds).
  /// [toArrival] > 0: approaching; [sinceDeparture] > 0: leaving. Uses the line's kinematics.
  static double offsetFor(RailLine line, {double? toArrival, double? sinceDeparture}) {
    final vmax = line.speedKmh / 3.6, a = line.mode.accel, b = line.mode.decel;
    if (toArrival != null && toArrival > 0) {
      final tb = vmax / b;
      if (toArrival <= tb) return -0.5 * b * toArrival * toArrival;
      return -(0.5 * b * tb * tb + vmax * (toArrival - tb));
    }
    if (sinceDeparture != null && sinceDeparture > 0) {
      final ta = vmax / a;
      if (sinceDeparture <= ta) return 0.5 * a * sinceDeparture * sinceDeparture;
      return 0.5 * a * ta * ta + vmax * (sinceDeparture - ta);
    }
    return 0;
  }

  /// Point on the walk path at distance [s].
  (double, double, double, StationStage, bool) pointAt(double s) {
    if (path.isEmpty) return (0, 0, 0, StationStage.street, false);
    s = s.clamp(0, pathLength);
    var i = 1;
    while (i < pathCum.length - 1 && pathCum[i] < s) {
      i++;
    }
    final a = path[i - 1], b = path[i];
    final seg = pathCum[i] - pathCum[i - 1];
    final t = seg <= 0 ? 0.0 : (s - pathCum[i - 1]) / seg;
    return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.stage == b.stage || t < 0.5 ? a.stage : b.stage, a.escalator);
  }

  double stageStart(StationStage stage) {
    for (var i = 0; i < path.length; i++) {
      if (path[i].stage.index >= stage.index) return pathCum[i];
    }
    return pathLength;
  }
}
