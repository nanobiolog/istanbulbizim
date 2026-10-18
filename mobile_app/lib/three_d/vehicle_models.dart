import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'engine3d.dart';

/// Procedural low-poly models of Istanbul vehicles, centred on the origin, length along +x,
/// standing on y = 0. Colours follow the real liveries (see vehicle_media.json photos).
enum VehicleKind { marmaray, metro, tram, nostalgicTram, funicular, cable, bus, metrobus, ferry, seaBus, privateFerry, carFerry }

class VehicleModels {
  static final Map<String, Mesh> _cache = {};

  static Mesh build(VehicleKind kind, {Color accent = const Color(0xFF2E5AAC), int cars = 0}) {
    final key = '$kind-${accent.toARGB32()}-$cars';
    return _cache.putIfAbsent(key, () {
      switch (kind) {
        case VehicleKind.marmaray:
          return trainSet(cars == 0 ? 5 : cars, carLen: 22.5, body: const Color(0xFFF4F5F6), stripe: accent,
              lower: const Color(0xFFB8BEC6), glass: const Color(0xFF1F2933), noseDark: true, roundNose: true);
        case VehicleKind.metro:
          return trainSet(cars == 0 ? 4 : cars, carLen: 20, body: const Color(0xFFD9DDE1), stripe: accent,
              lower: const Color(0xFF9AA3AD), glass: const Color(0xFF23303B), noseDark: true);
        case VehicleKind.tram:
          return trainSet(cars == 0 ? 5 : cars, carLen: 6.6, height: 3.4, width: 2.65,
              body: const Color(0xFFF2F3F5), stripe: const Color(0xFFD7262E), lower: const Color(0xFFD7262E),
              glass: const Color(0xFF26323C), noseDark: false, noseColor: const Color(0xFFD7262E), roundNose: true, gap: 0.25);
        case VehicleKind.nostalgicTram:
          return _nostalgicTram();
        case VehicleKind.funicular:
          return trainSet(2, carLen: 16, height: 3.3, body: const Color(0xFF3B4250), stripe: const Color(0xFF8AA4C8),
              lower: const Color(0xFF2A303B), glass: const Color(0xFF9FB4C9), noseDark: false, roundNose: true);
        case VehicleKind.cable:
          return _gondola(accent);
        case VehicleKind.bus:
          return _bus(12, const Color(0xFFF4C430), const Color(0xFFF7F7F2));
        case VehicleKind.metrobus:
          return _bus(18, const Color(0xFFE5E7EB), const Color(0xFFF7F7F7), articulated: true, band: const Color(0xFF6B7280));
        case VehicleKind.ferry:
          return _ferry(hull: const Color(0xFFF7F7F5), boot: const Color(0xFF1F2937), funnel: const Color(0xFFF7F7F5), funnelTop: const Color(0xFF111827));
        case VehicleKind.seaBus:
          return _seaBus(accent);
        case VehicleKind.privateFerry:
          return _ferry(hull: accent, boot: const Color(0xFF0F172A), funnel: const Color(0xFFF8FAFC), funnelTop: accent, length: 34, decks: 2);
        case VehicleKind.carFerry:
          return _carFerry();
      }
    });
  }

  /// Multi-car train set, total length centred on the origin.
  static Mesh trainSet(int cars,
      {required double carLen,
      double height = 3.75,
      double width = 2.9,
      required Color body,
      required Color stripe,
      required Color lower,
      required Color glass,
      bool noseDark = true,
      Color? noseColor,
      bool roundNose = false,
      double gap = 0.7}) {
    final m = Mesh();
    final total = cars * carLen + (cars - 1) * gap;
    var x = -total / 2;
    final hw = width / 2;
    for (var i = 0; i < cars; i++) {
      final x0 = x, x1 = x + carLen;
      final front = i == cars - 1, back = i == 0;
      final y0 = 0.9, y1 = y0 + height - 0.9;
      // body
      m.box(x0, y0, -hw, x1, y1, hw, body, top: const Color(0xFFE5E7EB), faces: 1 | 2 | 16 | 32);
      // lower skirt
      m.box(x0 + 0.2, y0, -hw - 0.01, x1 - 0.2, y0 + 0.55, hw + 0.01, lower, faces: 16 | 32);
      // window band both sides
      for (final z in [-hw - 0.02, hw + 0.02]) {
        final win = 1.05, wy0 = y0 + 1.25, wy1 = wy0 + win;
        // stripe under windows
        m.quad([x0 + 0.1, wy0 - 0.38, z], [x1 - 0.1, wy0 - 0.38, z], [x1 - 0.1, wy0 - 0.18, z], [x0 + 0.1, wy0 - 0.18, z], stripe);
        // glazing with door gaps
        final doors = math.max(1, (carLen / 6.5).floor());
        final seg = carLen / doors;
        for (var d = 0; d < doors; d++) {
          final sx = x0 + d * seg;
          m.quad([sx + 0.5, wy0, z], [sx + seg * 0.62, wy0, z], [sx + seg * 0.62, wy1, z], [sx + 0.5, wy1, z], glass);
          // door (slightly darker body tone, full height)
          final dx0 = sx + seg * 0.68, dx1 = sx + seg * 0.68 + 1.3;
          if (dx1 < x1 - 0.3) {
            m.quad([dx0, y0 + 0.1, z], [dx1, y0 + 0.1, z], [dx1, y1 - 0.25, z], [dx0, y1 - 0.25, z], const Color(0xFFB0B7BF));
            m.quad([dx0 + 0.12, wy0, z], [dx1 - 0.12, wy0, z], [dx1 - 0.12, wy1, z], [dx0 + 0.12, wy1, z], glass);
          }
        }
      }
      // ends
      if (front || back) {
        final sx = front ? x1 : x0;
        final dir = front ? 1.0 : -1.0;
        final nose = roundNose ? 1.6 : 0.6;
        final nx = sx + dir * nose;
        final nc = noseColor ?? body;
        // tapered cab: 4 sloped faces
        m.quad([sx, y0, -hw], [nx, y0 + 0.2, -hw + 0.35], [nx, y1 - 0.5, -hw + 0.45], [sx, y1, -hw], nc);
        m.quad([sx, y0, hw], [sx, y1, hw], [nx, y1 - 0.5, hw - 0.45], [nx, y0 + 0.2, hw - 0.35], nc);
        m.quad([sx, y1, -hw], [nx, y1 - 0.5, -hw + 0.45], [nx, y1 - 0.5, hw - 0.45], [sx, y1, hw], const Color(0xFFDCDFE3));
        m.quad([nx, y0 + 0.2, -hw + 0.35], [nx, y0 + 0.2, hw - 0.35], [nx, y1 - 0.5, hw - 0.45], [nx, y1 - 0.5, -hw + 0.45], nc);
        // windscreen
        final wx = nx - dir * 0.05;
        m.quad([wx, y0 + 1.3, -hw + 0.5], [wx, y0 + 1.3, hw - 0.5], [wx, y1 - 0.6, hw - 0.52], [wx, y1 - 0.6, -hw + 0.52],
            noseDark ? const Color(0xFF111827) : glass);
        // headlights
        m.quad([wx - dir * 0.01, y0 + 0.55, -hw + 0.45], [wx - dir * 0.01, y0 + 0.55, -hw + 0.85],
            [wx - dir * 0.01, y0 + 0.75, -hw + 0.85], [wx - dir * 0.01, y0 + 0.75, -hw + 0.45], const Color(0xFFFFF7D6),
            emissive: true);
        m.quad([wx - dir * 0.01, y0 + 0.55, hw - 0.85], [wx - dir * 0.01, y0 + 0.55, hw - 0.45],
            [wx - dir * 0.01, y0 + 0.75, hw - 0.45], [wx - dir * 0.01, y0 + 0.75, hw - 0.85], const Color(0xFFFFF7D6),
            emissive: true);
        // line colour band on the nose
        m.quad([nx + dir * 0.01, y0 + 0.9, -hw + 0.4], [nx + dir * 0.01, y0 + 0.9, hw - 0.4], [nx + dir * 0.01, y0 + 1.1, hw - 0.4],
            [nx + dir * 0.01, y0 + 1.1, -hw + 0.4], stripe);
      } else {
        m.box(x1, y0 + 0.2, -hw + 0.5, x1 + gap, y1 - 0.4, hw - 0.5, const Color(0xFF2B2F36));
      }
      if (!front && !back) {
        // nothing extra
      }
      if (back && !front) m.box(x1, y0 + 0.2, -hw + 0.5, x1 + gap, y1 - 0.4, hw - 0.5, const Color(0xFF2B2F36));
      // bogies
      for (final bx in [x0 + carLen * 0.18, x1 - carLen * 0.18]) {
        m.box(bx - 1.3, 0.15, -hw + 0.25, bx + 1.3, 0.9, hw - 0.25, const Color(0xFF30343B));
      }
      // roof equipment
      m.box(x0 + carLen * 0.35, y1, -0.6, x0 + carLen * 0.65, y1 + 0.3, 0.6, const Color(0xFFB9C0C8));
      x += carLen + gap;
    }
    return m;
  }

  static Mesh _nostalgicTram() {
    final m = Mesh();
    const red = Color(0xFFC0242B), cream = Color(0xFFF1E3C6), dark = Color(0xFF2B1D16);
    m.box(-5, 0.7, -1.15, 5, 1.6, 1.15, red);
    m.box(-5, 1.6, -1.15, 5, 2.9, 1.15, cream, faces: 16 | 32 | 4 | 8);
    for (final z in [-1.16, 1.16]) {
      for (var i = 0; i < 6; i++) {
        final x0 = -4.4 + i * 1.5;
        m.quad([x0, 1.75, z], [x0 + 1.1, 1.75, z], [x0 + 1.1, 2.7, z], [x0, 2.7, z], const Color(0xFF3B4A55));
      }
    }
    m.box(-5.3, 2.9, -1.3, 5.3, 3.15, 1.3, red, top: const Color(0xFF8B1A1F));
    m.box(-0.2, 3.15, -0.1, 0.2, 4.2, 0.1, dark); // trolley pole
    m.box(-4.2, 0.1, -1.0, -2.2, 0.7, 1.0, dark);
    m.box(2.2, 0.1, -1.0, 4.2, 0.7, 1.0, dark);
    return m;
  }

  static Mesh _gondola(Color accent) {
    final m = Mesh();
    m.box(-1.3, 0, -1.1, 1.3, 2.2, 1.1, const Color(0xFFE8EDF2), top: accent);
    for (final z in [-1.11, 1.11]) {
      m.quad([-1.1, 0.9, z], [1.1, 0.9, z], [1.1, 2.0, z], [-1.1, 2.0, z], const Color(0xFF2F3E4C));
    }
    m.box(-0.08, 2.2, -0.08, 0.08, 4.0, 0.08, const Color(0xFF4B5563));
    m.box(-0.5, 4.0, -0.15, 0.5, 4.3, 0.15, const Color(0xFF374151));
    // cable
    m.box(-12, 4.3, -0.03, 12, 4.36, 0.03, const Color(0xFF111827));
    return m;
  }

  static Mesh _bus(double len, Color body, Color roof, {bool articulated = false, Color? band}) {
    final m = Mesh();
    const hw = 1.27;
    const glass = Color(0xFF1C252E);
    final x0 = -len / 2, x1 = len / 2;
    m.box(x0, 0.35, -hw, x1, 2.95, hw, body, top: roof);
    // windows band
    for (final z in [-hw - 0.01, hw + 0.01]) {
      m.quad([x0 + 0.6, 1.35, z], [x1 - 1.0, 1.35, z], [x1 - 1.0, 2.55, z], [x0 + 0.6, 2.55, z], glass);
      if (band != null) m.quad([x0 + 0.2, 0.75, z], [x1 - 0.2, 0.75, z], [x1 - 0.2, 0.95, z], [x0 + 0.2, 0.95, z], band);
      // doors
      for (final dx in articulated ? [x1 - 2.2, x1 - 7.5, x0 + 6, x0 + 1.5] : [x1 - 2.0, x0 + len * 0.45, x0 + 1.4]) {
        m.quad([dx - 0.6, 0.4, z], [dx + 0.6, 0.4, z], [dx + 0.6, 2.6, z], [dx - 0.6, 2.6, z], const Color(0xFF34404B));
      }
    }
    // windscreen + destination display
    m.quad([x1 + 0.01, 1.0, -hw + 0.1], [x1 + 0.01, 1.0, hw - 0.1], [x1 + 0.01, 2.45, hw - 0.1], [x1 + 0.01, 2.45, -hw + 0.1], glass);
    m.quad([x1 + 0.02, 2.5, -hw + 0.2], [x1 + 0.02, 2.5, hw - 0.2], [x1 + 0.02, 2.85, hw - 0.2], [x1 + 0.02, 2.85, -hw + 0.2],
        const Color(0xFFFFB020), emissive: true);
    m.quad([x0 - 0.01, 1.4, -hw + 0.2], [x0 - 0.01, 2.6, -hw + 0.2], [x0 - 0.01, 2.6, hw - 0.2], [x0 - 0.01, 1.4, hw - 0.2], glass);
    if (articulated) m.box(-0.4, 0.4, -hw - 0.02, 0.4, 2.9, hw + 0.02, const Color(0xFF1F2937));
    // wheels
    final axles = articulated ? [x1 - 2.6, -2.5, x0 + 2.6] : [x1 - 2.6, x0 + 3.0];
    for (final ax in axles) {
      for (final z in [-hw + 0.05, hw - 0.05]) {
        m.cylinderZ(ax, 0.5, z, 0.5, 0.3, const Color(0xFF111111));
      }
    }
    // roof HVAC
    m.box(x0 + len * 0.3, 2.95, -0.7, x0 + len * 0.55, 3.25, 0.7, const Color(0xFFD1D5DB));
    return m;
  }

  static Mesh _ferry({required Color hull, required Color boot, required Color funnel, required Color funnelTop, double length = 60, int decks = 3}) {
    final m = Mesh();
    final L = length, hw = L * 0.095;
    // hull: tapered bow & stern (double-ended Istanbul ferry)
    const y0 = -1.4, y1 = 2.0;
    final xs = [-L / 2, -L / 2 + L * 0.12, L / 2 - L * 0.12, L / 2];
    final ws = [hw * 0.35, hw, hw, hw * 0.35];
    for (var i = 0; i < 3; i++) {
      for (final sgn in [-1.0, 1.0]) {
        m.quad([xs[i], y0, sgn * ws[i] * 0.85], [xs[i + 1], y0, sgn * ws[i + 1] * 0.85], [xs[i + 1], y1, sgn * ws[i + 1]],
            [xs[i], y1, sgn * ws[i]], hull);
        // boot topping (dark waterline band)
        m.quad([xs[i], y0, sgn * ws[i] * 0.86], [xs[i + 1], y0, sgn * ws[i + 1] * 0.86], [xs[i + 1], 0.1, sgn * ws[i + 1] * 0.93],
            [xs[i], 0.1, sgn * ws[i] * 0.93], boot);
      }
      // deck
      m.quad([xs[i], y1, -ws[i]], [xs[i + 1], y1, -ws[i + 1]], [xs[i + 1], y1, ws[i + 1]], [xs[i], y1, ws[i]], const Color(0xFFB8A27A));
    }
    // superstructure decks
    for (var d = 0; d < decks; d++) {
      final inset = 0.1 + d * 0.1;
      final dx0 = -L / 2 + L * (0.14 + d * 0.06), dx1 = L / 2 - L * (0.14 + d * 0.06);
      final dy0 = y1 + d * 2.6, dy1 = dy0 + 2.6;
      final dw = hw * (0.98 - inset * 0.6);
      m.box(dx0, dy0, -dw, dx1, dy1, dw, const Color(0xFFF7F7F5), top: const Color(0xFFE7E5E0));
      for (final z in [-dw - 0.02, dw + 0.02]) {
        final n = ((dx1 - dx0) / 1.6).floor();
        for (var k = 0; k < n; k++) {
          final wx = dx0 + 0.4 + k * 1.6;
          m.quad([wx, dy0 + 0.9, z], [wx + 1.1, dy0 + 0.9, z], [wx + 1.1, dy0 + 2.0, z], [wx, dy0 + 2.0, z], const Color(0xFF2B3743));
        }
      }
    }
    final topY = y1 + decks * 2.6;
    // bridge houses at both ends and funnel
    m.box(-L * 0.22, topY, -hw * 0.5, -L * 0.12, topY + 2.0, hw * 0.5, const Color(0xFFF7F7F5));
    m.box(L * 0.12, topY, -hw * 0.5, L * 0.22, topY + 2.0, hw * 0.5, const Color(0xFFF7F7F5));
    m.cylinder(0, 0, topY, topY + 4.2, hw * 0.28, funnel, seg: 12);
    m.cylinder(0, 0, topY + 4.2, topY + 5.2, hw * 0.29, funnelTop, seg: 12);
    // masts
    m.box(-L * 0.17, topY + 2.0, -0.08, -L * 0.17 + 0.16, topY + 6.5, 0.08, const Color(0xFF1F2937));
    m.box(L * 0.17, topY + 2.0, -0.08, L * 0.17 + 0.16, topY + 6.5, 0.08, const Color(0xFF1F2937));
    return m;
  }

  static Mesh _seaBus(Color accent) {
    final m = Mesh();
    const L = 38.0, hw = 5.0;
    // twin hulls
    for (final z in [-hw + 1.1, hw - 1.1]) {
      m.box(-L / 2, -1.2, z - 1.0, L / 2 - 2, 1.2, z + 1.0, const Color(0xFFF2F4F7));
      m.quad([L / 2 - 2, -1.2, z - 1.0], [L / 2 + 2, 1.2, z], [L / 2 + 2, 1.2, z], [L / 2 - 2, -1.2, z + 1.0], const Color(0xFFF2F4F7));
      m.box(-L / 2, -1.21, z - 1.01, L / 2 - 2, -0.4, z + 1.01, const Color(0xFF0F172A), faces: 16 | 32 | 4);
    }
    m.box(-L / 2 + 1, 1.2, -hw, L / 2 - 4, 4.2, hw, Colors.white, top: const Color(0xFFE5E7EB));
    for (final z in [-hw - 0.02, hw + 0.02]) {
      m.quad([-L / 2 + 2, 2.2, z], [L / 2 - 6, 2.2, z], [L / 2 - 6, 3.6, z], [-L / 2 + 2, 3.6, z], const Color(0xFF1E293B));
      m.quad([-L / 2 + 1.2, 1.4, z], [L / 2 - 4.2, 1.4, z], [L / 2 - 4.2, 1.9, z], [-L / 2 + 1.2, 1.9, z], accent);
    }
    m.box(L / 2 - 12, 4.2, -hw * 0.6, L / 2 - 6, 6.0, hw * 0.6, Colors.white);
    m.quad([L / 2 - 5.99, 4.6, -hw * 0.55], [L / 2 - 5.99, 4.6, hw * 0.55], [L / 2 - 5.99, 5.7, hw * 0.55], [L / 2 - 5.99, 5.7, -hw * 0.55],
        const Color(0xFF0F172A));
    return m;
  }

  static Mesh _carFerry() {
    final m = Mesh();
    const L = 70.0, hw = 8.0;
    m.box(-L / 2, -1.5, -hw, L / 2, 2.5, hw, Colors.white, top: const Color(0xFF6B7280));
    m.box(-L / 2, -1.51, -hw - 0.01, L / 2, 0.0, hw + 0.01, const Color(0xFF1E3A8A), faces: 4 | 8 | 16 | 32);
    // car deck walls & passenger deck on top
    m.box(-L / 2 + 6, 2.5, -hw, L / 2 - 6, 6.0, -hw + 1.2, Colors.white);
    m.box(-L / 2 + 6, 2.5, hw - 1.2, L / 2 - 6, 6.0, hw, Colors.white);
    m.box(-L / 2 + 10, 6.0, -hw, L / 2 - 10, 9.0, hw, Colors.white, top: const Color(0xFFE5E7EB));
    for (final z in [-hw - 0.02, hw + 0.02]) {
      for (var k = 0; k < 18; k++) {
        final wx = -L / 2 + 11 + k * 2.6;
        m.quad([wx, 6.8, z], [wx + 1.8, 6.8, z], [wx + 1.8, 8.4, z], [wx, 8.4, z], const Color(0xFF1F2937));
      }
    }
    m.box(-4, 9.0, -3, 4, 11.5, 3, Colors.white);
    m.quad([4.01, 9.6, -2.8], [4.01, 9.6, 2.8], [4.01, 11.0, 2.8], [4.01, 11.0, -2.8], const Color(0xFF111827));
    // cars on deck
    final colors = [const Color(0xFFDC2626), const Color(0xFF2563EB), const Color(0xFFE5E7EB), const Color(0xFF111827), const Color(0xFFF59E0B)];
    for (var i = 0; i < 10; i++) {
      final cx = -L / 2 + 4 + (i % 5) * 4.6, cz = i < 5 ? -3.5 : 3.0;
      m.box(cx, 2.5, cz - 0.9, cx + 4.0, 3.9, cz + 0.9, colors[i % colors.length]);
    }
    return m;
  }
}

extension on Mesh {
  /// Cylinder lying along z (wheels).
  void cylinderZ(double x, double y, double z, double r, double w, Color color, {int seg = 10}) {
    for (var i = 0; i < seg; i++) {
      final a0 = i / seg * math.pi * 2, a1 = (i + 1) / seg * math.pi * 2;
      final x0 = x + math.cos(a0) * r, y0 = y + math.sin(a0) * r;
      final x1 = x + math.cos(a1) * r, y1 = y + math.sin(a1) * r;
      final zo = z < 0 ? z - w / 2 : z + w / 2;
      quad([x0, y0, z - w / 2], [x1, y1, z - w / 2], [x1, y1, z + w / 2], [x0, y0, z + w / 2], color);
      tri(x, y, zo, x0, y0, zo, x1, y1, zo, const Color(0xFF6B7280));
    }
  }
}
