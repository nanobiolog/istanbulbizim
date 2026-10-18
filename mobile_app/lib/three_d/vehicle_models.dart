import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'engine3d.dart';

/// Procedural 3D models of Istanbul transit vehicles, centred on the origin, length along +x,
/// standing on y = 0. Proportions and liveries follow the real Istanbul fleet:
/// - TCDD Hyundai Rotem E32000 (Marmaray)
/// - Metro İstanbul Hyundai Rotem / CAF / Mitsubishi driverless & cab sets
/// - Bombardier Flexity Swift / Alstom Citadis low-floor articulated trams
/// - Beyoğlu / Moda heritage Gotha & nostalgic trams
/// - Şehir Hatları classic double-ended Bosphorus steamer (Fenerbahçe / Barış Manço / Moda class)
/// - İDO fast wave-piercing twin-hull catamaran sea bus
/// - Turyol / Dentur Avrasya Bosphorus passenger motorboat
/// - Şehir Hatları / İDO double-ended Ro-Ro car ferry (Arabalı Vapur)
/// - İETT Otokar Kent / Mercedes-Benz Citaro & CapaCity Metrobüs
enum VehicleKind {
  marmaray,
  metro,
  metroDriverless,
  tram,
  nostalgicTram,
  funicular,
  cable,
  bus,
  metrobus,
  ferry,
  seaBus,
  privateFerry,
  carFerry,
}

class VehicleModels {
  static final Map<String, Mesh> _cache = {};
  static final Map<String, Mesh> _plinthCache = {};

  static Mesh build(VehicleKind kind, {Color accent = const Color(0xFF2E5AAC), int cars = 0}) {
    final key = '$kind-${accent.toARGB32()}-$cars';
    return _cache.putIfAbsent(key, () {
      switch (kind) {
        case VehicleKind.marmaray:
          return _marmaraySet(cars == 0 ? 5 : cars, accent: accent);
        case VehicleKind.metroDriverless:
          return _metroSet(cars == 0 ? 4 : cars, accent: accent, driverless: true);
        case VehicleKind.metro:
          return _metroSet(cars == 0 ? 4 : cars, accent: accent, driverless: false);
        case VehicleKind.tram:
          return _modernTramSet(cars == 0 ? 5 : cars, accent: accent);
        case VehicleKind.nostalgicTram:
          return _nostalgicTram(accent: accent);
        case VehicleKind.funicular:
          return _funicularSet(accent: accent);
        case VehicleKind.cable:
          return _gondola(accent);
        case VehicleKind.bus:
          return _bus(12.0, const Color(0xFFF4C430), const Color(0xFFF8FAFC), accent: accent);
        case VehicleKind.metrobus:
          return _bus(
            18.6,
            const Color(0xFFE5E7EB),
            const Color(0xFFF8FAFC),
            articulated: true,
            band: const Color(0xFFE11D48),
            accent: accent,
          );
        case VehicleKind.ferry:
          return _sehirHatlariVapur();
        case VehicleKind.seaBus:
          return _idoCatamaran(accent);
        case VehicleKind.privateFerry:
          return _bosphorusMotor(accent);
        case VehicleKind.carFerry:
          return _carFerry();
      }
    });
  }

  /// Contextual 3D display plinth for the interactive 3D showcase viewer:
  /// - Ferries / SeaBuses sit on Bosphorus turquoise-navy water with wake foam
  /// - Trains / Trams sit on ballasted/slab rails with sleepers
  /// - Buses sit on a marked asphalt lane
  static Mesh showcasePlinth(VehicleKind kind, double radius, {required bool night}) {
    final key = 'plinth-$kind-${radius.toStringAsFixed(1)}-$night';
    return _plinthCache.putIfAbsent(key, () {
      final m = Mesh();
      final isWater = kind == VehicleKind.ferry ||
          kind == VehicleKind.seaBus ||
          kind == VehicleKind.privateFerry ||
          kind == VehicleKind.carFerry;
      final isRoad = kind == VehicleKind.bus || kind == VehicleKind.metrobus;
      final isCable = kind == VehicleKind.cable;

      if (isWater) {
        final rx = radius * 1.05, rz = radius * 0.52;
        final waterDeep = night ? const Color(0xFF0A2239) : const Color(0xFF0E4D6E);
        final waterMid = night ? const Color(0xFF0F3150) : const Color(0xFF15658A);
        const segs = 32;
        for (var i = 0; i < segs; i++) {
          final a0 = i / segs * math.pi * 2, a1 = (i + 1) / segs * math.pi * 2;
          m.tri(
            0,
            -0.08,
            0,
            math.cos(a1) * rx,
            -0.08,
            math.sin(a1) * rz,
            math.cos(a0) * rx,
            -0.08,
            math.sin(a0) * rz,
            i.isEven ? waterDeep : waterMid,
            emissive: true,
          );
        }
        // White-turquoise wake V-waves around hull
        final wakeCol = night ? const Color(0xFF38BDF8) : const Color(0xFFBAE6FD);
        for (final sgn in [-1.0, 1.0]) {
          m.quad(
            [-radius * 0.78, -0.04, sgn * radius * 0.14],
            [radius * 0.72, -0.04, sgn * radius * 0.08],
            [radius * 0.72, -0.04, sgn * radius * 0.12],
            [-radius * 0.78, -0.04, sgn * radius * 0.22],
            wakeCol,
            emissive: true,
          );
        }
        return m;
      }

      if (isCable) return m;

      if (isRoad) {
        final lx = radius * 1.02, wz = 2.6;
        m.box(-lx, -0.14, -wz, lx, -0.01, wz, const Color(0xFF1E293B), top: const Color(0xFF334155));
        for (final sgn in [-1.0, 1.0]) {
          m.quad(
            [-lx + 0.4, 0.0, sgn * (wz - 0.22)],
            [lx - 0.4, 0.0, sgn * (wz - 0.22)],
            [lx - 0.4, 0.0, sgn * (wz - 0.12)],
            [-lx + 0.4, 0.0, sgn * (wz - 0.12)],
            const Color(0xFFF8FAFC),
            emissive: true,
          );
        }
        for (var x = -lx + 1.0; x < lx - 1.5; x += 2.8) {
          m.quad([x, 0.0, -0.06], [x + 1.4, 0.0, -0.06], [x + 1.4, 0.0, 0.06], [x, 0.0, 0.06], const Color(0xFFFACC15), emissive: true);
        }
        return m;
      }

      // Rail track bed with concrete sleepers and steel rails
      final lx = radius * 1.02;
      m.box(-lx, -0.18, -1.85, lx, -0.04, 1.85, const Color(0xFF334155), top: const Color(0xFF475569));
      for (var x = -lx + 0.5; x <= lx - 0.5; x += 0.95) {
        m.box(x - 0.14, -0.04, -1.35, x + 0.14, 0.0, 1.35, const Color(0xFF64748B));
      }
      for (final z in [-0.72, 0.72]) {
        m.box(-lx, 0.0, z - 0.05, lx, 0.09, z + 0.05, const Color(0xFFCBD5E1));
      }
      return m;
    });
  }

  // ───────────────────────── 1. TCDD E32000 MARMARAY ─────────────────────────

  static Mesh _marmaraySet(int cars, {required Color accent}) {
    final m = Mesh();
    const carLen = 22.5, gap = 0.65, width = 2.95, hw = width / 2;
    const y0 = 0.92, yRoof = 3.72, yCrown = 3.92;
    const steel = Color(0xFFE2E8F0);
    const steelUpper = Color(0xFFF1F5F9);
    const steelRib = Color(0xFFCBD5E1);
    const skirt = Color(0xFF475569);
    const glass = Color(0xFF0F172A);
    const marmarayBlue = Color(0xFF1D4ED8);
    const marmarayRed = Color(0xFFDC2626);

    final total = cars * carLen + (cars - 1) * gap;
    var x = -total / 2;

    for (var i = 0; i < cars; i++) {
      final x0 = x, x1 = x + carLen;
      final front = i == cars - 1, back = i == 0;

      // Underframe equipment skirt
      m.box(x0 + 0.3, 0.48, -hw + 0.12, x1 - 0.3, y0, hw - 0.12, skirt);
      // Main stainless-steel carbody
      m.box(x0, y0, -hw, x1, yRoof, hw, steel, top: steelUpper, faces: 2 | 16 | 32);
      // Chamfered roof tumblehome (gives the curved E32000 cross-section)
      m.quad([x0, yRoof, -hw], [x1, yRoof, -hw], [x1, yCrown, -hw + 0.28], [x0, yCrown, -hw + 0.28], steelUpper);
      m.quad([x0, yRoof, hw], [x0, yCrown, hw - 0.28], [x1, yCrown, hw - 0.28], [x1, yRoof, hw], steelUpper);
      m.quad([x0, yCrown, -hw + 0.28], [x1, yCrown, -hw + 0.28], [x1, yCrown, hw - 0.28], [x0, yCrown, hw - 0.28], const Color(0xFFDbe2ea));

      // Corrugated steel fluting ribs + Marmaray dual blue/red livery + 5 doors per side
      for (final sgn in [-1.0, 1.0]) {
        final z = sgn * (hw + 0.015);
        // Upper & lower stainless corrugation lines
        m.quad([x0 + 0.15, yRoof - 0.22, z], [x1 - 0.15, yRoof - 0.22, z], [x1 - 0.15, yRoof - 0.12, z], [x0 + 0.15, yRoof - 0.12, z], steelRib);
        // Signature TCDD Marmaray blue & red waist bands
        m.quad([x0 + 0.12, y0 + 0.82, z], [x1 - 0.12, y0 + 0.82, z], [x1 - 0.12, y0 + 1.04, z], [x0 + 0.12, y0 + 1.04, z], marmarayBlue);
        m.quad([x0 + 0.12, y0 + 0.64, z], [x1 - 0.12, y0 + 0.64, z], [x1 - 0.12, y0 + 0.79, z], [x0 + 0.12, y0 + 0.79, z], marmarayRed);

        // 5 evenly spaced double-leaf sliding passenger doors & windows between them
        const doors = 5;
        final seg = (carLen - 1.2) / doors;
        const wy0 = y0 + 1.15, wy1 = y0 + 2.18;
        for (var d = 0; d < doors; d++) {
          final sx = x0 + 0.6 + d * seg;
          final dx0 = sx + 0.25, dx1 = dx0 + 1.32;
          // Bi-parting door leaves
          m.quad([dx0, y0 + 0.08, z], [dx1, y0 + 0.08, z], [dx1, yRoof - 0.26, z], [dx0, yRoof - 0.26, z], const Color(0xFFCBD5E1));
          // Center door seam
          final dm = (dx0 + dx1) / 2;
          m.quad([dm - 0.02, y0 + 0.08, z + sgn * 0.005], [dm + 0.02, y0 + 0.08, z + sgn * 0.005],
              [dm + 0.02, yRoof - 0.26, z + sgn * 0.005], [dm - 0.02, yRoof - 0.26, z + sgn * 0.005], const Color(0xFF475569));
          // Door windows
          m.quad([dx0 + 0.12, wy0, z + sgn * 0.005], [dm - 0.06, wy0, z + sgn * 0.005], [dm - 0.06, wy1, z + sgn * 0.005],
              [dx0 + 0.12, wy1, z + sgn * 0.005], glass);
          m.quad([dm + 0.06, wy0, z + sgn * 0.005], [dx1 - 0.12, wy0, z + sgn * 0.005], [dx1 - 0.12, wy1, z + sgn * 0.005],
              [dm + 0.06, wy1, z + sgn * 0.005], glass);
          // Panoramic side window between doors
          final wx0 = dx1 + 0.22, wx1 = sx + seg - 0.08;
          if (wx1 > wx0 + 0.3) {
            m.quad([wx0, wy0, z], [wx1, wy0, z], [wx1, wy1, z], [wx0, wy1, z], glass);
          }
        }
      }

      // Aerodynamic FRP white/silver cab mask at outer ends
      if (front || back) {
        _buildRailCabNose(
          m,
          xBase: front ? x1 : x0,
          dir: front ? 1.0 : -1.0,
          y0: y0,
          yRoof: yRoof,
          yCrown: yCrown,
          hw: hw,
          noseLen: 1.85,
          maskColor: const Color(0xFFF8FAFC),
          bandPrimary: marmarayBlue,
          bandSecondary: marmarayRed,
          panoramic: false,
          isFront: front,
        );
      }

      // Accordion gangway bellows between cars
      if (!front) {
        m.box(x1, y0 + 0.12, -hw + 0.38, x1 + gap, yRoof - 0.18, hw - 0.38, const Color(0xFF334155));
        for (var r = 1; r <= 2; r++) {
          final rx = x1 + gap * (r / 3);
          m.box(rx - 0.03, y0 + 0.10, -hw + 0.34, rx + 0.03, yRoof - 0.15, hw - 0.34, const Color(0xFF1E293B));
        }
      }

      // Detailed 2-axle railway bogies
      for (final bx in [x0 + carLen * 0.17, x1 - carLen * 0.17]) {
        _addRailBogie(m, bx, hw);
      }

      // Roof HVAC pods + Pantograph on every even/middle car
      m.box(x0 + carLen * 0.28, yCrown, -0.82, x0 + carLen * 0.46, yCrown + 0.28, 0.82, const Color(0xFFCBD5E1));
      m.box(x0 + carLen * 0.54, yCrown, -0.82, x0 + carLen * 0.72, yCrown + 0.28, 0.82, const Color(0xFFCBD5E1));
      if (i.isOdd || (cars == 1 && i == 0)) {
        _addPantograph(m, x0 + carLen * 0.18, yCrown);
      }

      x += carLen + gap;
    }
    return m;
  }

  // ───────────────────────── 2. ISTANBUL METRO (DRIVERLESS & CAB) ─────────────────────────

  static Mesh _metroSet(int cars, {required Color accent, required bool driverless}) {
    final m = Mesh();
    const carLen = 20.5, gap = 0.6, width = 2.90, hw = width / 2;
    const y0 = 0.90, yRoof = 3.68, yCrown = 3.86;
    final body = driverless ? const Color(0xFFE5E7EB) : const Color(0xFFF1F5F9);
    const glass = Color(0xFF111827);

    final total = cars * carLen + (cars - 1) * gap;
    var x = -total / 2;

    for (var i = 0; i < cars; i++) {
      final x0 = x, x1 = x + carLen;
      final front = i == cars - 1, back = i == 0;

      // Underframe skirt
      m.box(x0 + 0.25, 0.46, -hw + 0.1, x1 - 0.25, y0, hw - 0.1, const Color(0xFF334155));
      // Main carbody
      m.box(x0, y0, -hw, x1, yRoof, hw, body, top: const Color(0xFFE2E8F0), faces: 2 | 16 | 32);
      // Tapered roof crown
      m.quad([x0, yRoof, -hw], [x1, yRoof, -hw], [x1, yCrown, -hw + 0.25], [x0, yCrown, -hw + 0.25], const Color(0xFFE2E8F0));
      m.quad([x0, yRoof, hw], [x0, yCrown, hw - 0.25], [x1, yCrown, hw - 0.25], [x1, yRoof, hw], const Color(0xFFE2E8F0));
      m.quad([x0, yCrown, -hw + 0.25], [x1, yCrown, -hw + 0.25], [x1, yCrown, hw - 0.25], [x0, yCrown, hw - 0.25], accent);

      for (final sgn in [-1.0, 1.0]) {
        final z = sgn * (hw + 0.015);
        // Bold line-colour livery band along waist and cantrail
        m.quad([x0 + 0.1, y0 + 0.72, z], [x1 - 0.1, y0 + 0.72, z], [x1 - 0.1, y0 + 1.02, z], [x0 + 0.1, y0 + 1.02, z], accent);
        m.quad([x0 + 0.1, yRoof - 0.20, z], [x1 - 0.1, yRoof - 0.20, z], [x1 - 0.1, yRoof - 0.06, z], [x0 + 0.1, yRoof - 0.06, z], accent);

        // Continuous dark window-band mask for modern driverless sets
        const wy0 = y0 + 1.12, wy1 = y0 + 2.22;
        if (driverless) {
          m.quad([x0 + 0.3, wy0 - 0.04, z], [x1 - 0.3, wy0 - 0.04, z], [x1 - 0.3, wy1 + 0.04, z], [x0 + 0.3, wy1 + 0.04, z], const Color(0xFF1E293B));
        }

        // 4 wide metro doors per car side
        const doors = 4;
        final seg = (carLen - 1.2) / doors;
        for (var d = 0; d < doors; d++) {
          final sx = x0 + 0.6 + d * seg;
          final dx0 = sx + 0.3, dx1 = dx0 + 1.40;
          final dm = (dx0 + dx1) / 2;
          m.quad([dx0, y0 + 0.08, z + sgn * 0.004], [dx1, y0 + 0.08, z + sgn * 0.004], [dx1, yRoof - 0.22, z + sgn * 0.004],
              [dx0, yRoof - 0.22, z + sgn * 0.004], driverless ? const Color(0xFFD1D5DB) : const Color(0xFFCBD5E1));
          // Accent stripe on doors
          m.quad([dx0, y0 + 0.72, z + sgn * 0.008], [dx1, y0 + 0.72, z + sgn * 0.008], [dx1, y0 + 1.02, z + sgn * 0.008],
              [dx0, y0 + 1.02, z + sgn * 0.008], accent);
          // Door glazing
          m.quad([dx0 + 0.12, wy0, z + sgn * 0.008], [dm - 0.05, wy0, z + sgn * 0.008], [dm - 0.05, wy1, z + sgn * 0.008],
              [dx0 + 0.12, wy1, z + sgn * 0.008], glass);
          m.quad([dm + 0.05, wy0, z + sgn * 0.008], [dx1 - 0.12, wy0, z + sgn * 0.008], [dx1 - 0.12, wy1, z + sgn * 0.008],
              [dm + 0.05, wy1, z + sgn * 0.008], glass);
          final wx0 = dx1 + 0.26, wx1 = sx + seg - 0.10;
          if (wx1 > wx0 + 0.3) {
            m.quad([wx0, wy0, z + sgn * 0.004], [wx1, wy0, z + sgn * 0.004], [wx1, wy1, z + sgn * 0.004], [wx0, wy1, z + sgn * 0.004], glass);
          }
        }
      }

      if (front || back) {
        _buildRailCabNose(
          m,
          xBase: front ? x1 : x0,
          dir: front ? 1.0 : -1.0,
          y0: y0,
          yRoof: yRoof,
          yCrown: yCrown,
          hw: hw,
          noseLen: driverless ? 1.65 : 1.35,
          maskColor: driverless ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
          bandPrimary: accent,
          bandSecondary: const Color(0xFFE11D48),
          panoramic: driverless,
          isFront: front,
        );
      }

      if (!front) {
        m.box(x1, y0 + 0.12, -hw + 0.35, x1 + gap, yRoof - 0.18, hw - 0.35, const Color(0xFF334155));
      }

      for (final bx in [x0 + carLen * 0.18, x1 - carLen * 0.18]) {
        _addRailBogie(m, bx, hw);
      }

      m.box(x0 + carLen * 0.32, yCrown, -0.78, x0 + carLen * 0.68, yCrown + 0.26, 0.78, const Color(0xFFCBD5E1));
      if (i.isEven) _addPantograph(m, x0 + carLen * 0.2, yCrown);

      x += carLen + gap;
    }
    return m;
  }

  static void _buildRailCabNose(
    Mesh m, {
    required double xBase,
    required double dir,
    required double y0,
    required double yRoof,
    required double yCrown,
    required double hw,
    required double noseLen,
    required Color maskColor,
    required Color bandPrimary,
    required Color bandSecondary,
    required bool panoramic,
    required bool isFront,
  }) {
    final xMid = xBase + dir * (noseLen * 0.62);
    final xTip = xBase + dir * noseLen;
    final yWaist = y0 + 1.05;
    final yWinTop = yRoof - 0.32;

    // Lower bumper & anti-climber apron
    m.quad([xBase, y0 - 0.25, -hw], [xTip, y0 - 0.12, -hw + 0.32], [xTip, yWaist, -hw + 0.22], [xBase, yWaist, -hw], maskColor);
    m.quad([xBase, y0 - 0.25, hw], [xBase, yWaist, hw], [xTip, yWaist, hw - 0.22], [xTip, y0 - 0.12, hw - 0.32], maskColor);
    m.quad([xTip, y0 - 0.12, -hw + 0.32], [xTip, y0 - 0.12, hw - 0.32], [xTip, yWaist, hw - 0.22], [xTip, yWaist, -hw + 0.22], maskColor);

    // Upper raked windshield cheeks & roof brow
    m.quad([xBase, yWaist, -hw], [xTip, yWaist, -hw + 0.22], [xMid, yWinTop, -hw + 0.30], [xBase, yRoof, -hw], maskColor);
    m.quad([xBase, yWaist, hw], [xBase, yRoof, hw], [xMid, yWinTop, hw - 0.30], [xTip, yWaist, hw - 0.22], maskColor);
    m.quad([xBase, yCrown, -hw + 0.25], [xMid, yWinTop, -hw + 0.30], [xMid, yWinTop, hw - 0.30], [xBase, yCrown, hw - 0.25], maskColor);

    // Sloped front windscreen glass (panoramic wide window for driverless sets)
    final padZ = panoramic ? 0.28 : 0.38;
    final wx0 = xTip + dir * 0.02, wx1 = xMid + dir * 0.02;
    m.quad(
      [wx0, yWaist + 0.08, -hw + padZ],
      [wx0, yWaist + 0.08, hw - padZ],
      [wx1, yWinTop - 0.06, hw - padZ - 0.04],
      [wx1, yWinTop - 0.06, -hw + padZ + 0.04],
      const Color(0xFF0B132B),
    );

    // Illuminated amber/white LED destination matrix at top of windscreen
    m.quad(
      [wx1 + dir * 0.01, yWinTop - 0.28, -0.68],
      [wx1 + dir * 0.01, yWinTop - 0.28, 0.68],
      [wx1 + dir * 0.01, yWinTop - 0.10, 0.68],
      [wx1 + dir * 0.01, yWinTop - 0.10, -0.68],
      const Color(0xFFF59E0B),
      emissive: true,
    );

    // Nose livery band + secondary stripe
    final bx = xTip + dir * 0.015;
    m.quad([bx, y0 + 0.68, -hw + 0.28], [bx, y0 + 0.68, hw - 0.28], [bx, y0 + 0.92, hw - 0.26], [bx, y0 + 0.92, -hw + 0.26], bandPrimary);
    m.quad([bx, y0 + 0.52, -hw + 0.30], [bx, y0 + 0.52, hw - 0.30], [bx, y0 + 0.64, hw - 0.28], [bx, y0 + 0.64, -hw + 0.28], bandSecondary);

    // Headlights (warm white at front, red marker lights at rear)
    final lightCol = isFront ? const Color(0xFFFEF9C3) : const Color(0xFFEF4444);
    for (final sgn in [-1.0, 1.0]) {
      m.quad(
        [bx + dir * 0.01, y0 + 0.24, sgn * (hw - 0.78)],
        [bx + dir * 0.01, y0 + 0.24, sgn * (hw - 0.38)],
        [bx + dir * 0.01, y0 + 0.44, sgn * (hw - 0.38)],
        [bx + dir * 0.01, y0 + 0.44, sgn * (hw - 0.78)],
        lightCol,
        emissive: true,
      );
    }

    // Scharfenberg automatic coupler protruding from lower nose skirt
    final cx0 = math.min(xTip, xTip + dir * 0.55), cx1 = math.max(xTip, xTip + dir * 0.55);
    m.box(cx0, 0.38, -0.22, cx1, 0.66, 0.22, const Color(0xFF334155));
  }

  static void _addRailBogie(Mesh m, double bx, double hw) {
    // Bogie side frames
    m.box(bx - 1.45, 0.22, -hw + 0.18, bx + 1.45, 0.78, hw - 0.18, const Color(0xFF1E293B));
    // Two axles with steel wheels
    for (final ax in [bx - 0.95, bx + 0.95]) {
      for (final z in [-hw + 0.22, hw - 0.22]) {
        m.cylinderZ(ax, 0.42, z, 0.42, 0.18, const Color(0xFF0F172A));
      }
    }
  }

  static void _addPantograph(Mesh m, double px, double yRoof) {
    const col = Color(0xFF475569);
    // Insulator base
    m.box(px - 0.7, yRoof, -0.55, px + 0.7, yRoof + 0.14, 0.55, col);
    // Single-arm Z-frame pantograph rising to contact strip
    m.ramp(px - 0.5, yRoof + 0.14, px + 0.55, yRoof + 0.72, -0.08, 0.08, col);
    m.ramp(px + 0.55, yRoof + 0.72, px - 0.25, yRoof + 1.25, -0.07, 0.07, col);
    // Carbon contact pan head
    m.box(px - 0.42, yRoof + 1.23, -0.85, px - 0.08, yRoof + 1.30, 0.85, const Color(0xFF1E293B));
  }

  // ───────────────────────── 3. MODERN LOW-FLOOR TRAM (T1/T4/T5) ─────────────────────────

  static Mesh _modernTramSet(int modules, {required Color accent}) {
    final m = Mesh();
    const modLen = 6.2, gap = 0.38, width = 2.65, hw = width / 2;
    const y0 = 0.34, yRoof = 3.35;
    const body = Color(0xFFF8FAFC);
    const glass = Color(0xFF0F172A);
    final total = modules * modLen + (modules - 1) * gap;
    var x = -total / 2;

    for (var i = 0; i < modules; i++) {
      final x0 = x, x1 = x + modLen;
      final front = i == modules - 1, back = i == 0;

      // Low-floor body shell
      m.box(x0, y0, -hw, x1, yRoof, hw, body, top: const Color(0xFFE2E8F0), faces: 1 | 2 | 16 | 32);
      // Lower accent skirt & roof cantrail band
      for (final sgn in [-1.0, 1.0]) {
        final z = sgn * (hw + 0.015);
        m.quad([x0, y0, z], [x1, y0, z], [x1, y0 + 0.52, z], [x0, y0 + 0.52, z], accent);
        m.quad([x0, yRoof - 0.24, z], [x1, yRoof - 0.24, z], [x1, yRoof - 0.05, z], [x0, yRoof - 0.05, z], accent);
        // Deep low-floor panoramic windows
        m.quad([x0 + 0.35, y0 + 0.62, z], [x1 - 0.35, y0 + 0.62, z], [x1 - 0.35, yRoof - 0.32, z], [x0 + 0.35, yRoof - 0.32, z], glass);
        // Central double door on alternating modules
        final dm = (x0 + x1) / 2;
        m.quad([dm - 0.65, y0 + 0.06, z + sgn * 0.005], [dm + 0.65, y0 + 0.06, z + sgn * 0.005],
            [dm + 0.65, yRoof - 0.28, z + sgn * 0.005], [dm - 0.65, yRoof - 0.28, z + sgn * 0.005], const Color(0xFF1E293B));
      }

      if (front || back) {
        _buildRailCabNose(
          m,
          xBase: front ? x1 : x0,
          dir: front ? 1.0 : -1.0,
          y0: y0,
          yRoof: yRoof,
          yCrown: yRoof + 0.08,
          hw: hw,
          noseLen: 1.45,
          maskColor: accent,
          bandPrimary: Colors.white,
          bandSecondary: const Color(0xFF1E293B),
          panoramic: true,
          isFront: front,
        );
      }

      if (!front) {
        // Articulation bellows
        m.box(x1, y0 + 0.05, -hw + 0.18, x1 + gap, yRoof - 0.08, hw - 0.18, const Color(0xFF1E293B));
      }

      // Concealed low-floor wheel bogie
      m.box((x0 + x1) / 2 - 0.9, 0.08, -hw + 0.15, (x0 + x1) / 2 + 0.9, y0, hw - 0.15, const Color(0xFF1E293B));
      if (i == modules ~/ 2) {
        _addPantograph(m, (x0 + x1) / 2, yRoof);
      } else {
        m.box(x0 + 1.2, yRoof, -0.7, x1 - 1.2, yRoof + 0.22, 0.7, const Color(0xFFCBD5E1));
      }

      x += modLen + gap;
    }
    return m;
  }

  // ───────────────────────── 4. NOSTALGIC TRAM (T2 TAKSİM / T3 MODA) ─────────────────────────

  static Mesh _nostalgicTram({required Color accent}) {
    final m = Mesh();
    const red = Color(0xFFB91C1C), darkRed = Color(0xFF7F1D1D);
    const cream = Color(0xFFFDF6E2), brass = Color(0xFFD97706), wood = Color(0xFF78350F);
    const glass = Color(0xFF1E293B), iron = Color(0xFF1F2937);
    const L = 10.6, hw = 1.18;

    // Classic steel truck / undercarriage with leaf springs & cowcatcher (lifeguard)
    m.box(-3.6, 0.14, -0.95, 3.6, 0.68, 0.95, iron);
    for (final ax in [-2.1, 2.1]) {
      for (final z in [-0.98, 0.98]) {
        m.cylinderZ(ax, 0.36, z, 0.36, 0.16, const Color(0xFF111827));
      }
    }
    // Lower crimson body panel with gold pinstripe
    m.box(-L / 2, 0.68, -hw, L / 2, 1.65, hw, red, top: wood);
    // Upper cream window body
    m.box(-L / 2 + 0.15, 1.65, -hw + 0.02, L / 2 - 0.15, 2.88, hw - 0.02, cream);

    for (final sgn in [-1.0, 1.0]) {
      final z = sgn * (hw + 0.015);
      // Gold heritage trim stripe & white "İETT / BEYOĞLU" waist band
      m.quad([-L / 2 + 0.2, 1.54, z], [L / 2 - 0.2, 1.54, z], [L / 2 - 0.2, 1.63, z], [-L / 2 + 0.2, 1.63, z], brass);
      m.quad([-L / 2 + 0.3, 1.08, z], [L / 2 - 0.3, 1.08, z], [L / 2 - 0.3, 1.24, z], [-L / 2 + 0.3, 1.24, z], cream);
      // 5 framed wooden-sash side windows + end vestibule doors
      for (var i = 0; i < 5; i++) {
        final wx = -3.45 + i * 1.42;
        m.quad([wx - 0.05, 1.74, z], [wx + 1.15, 1.74, z], [wx + 1.15, 2.72, z], [wx - 0.05, 2.72, z], wood);
        m.quad([wx + 0.02, 1.80, z + sgn * 0.004], [wx + 1.08, 1.80, z + sgn * 0.004], [wx + 1.08, 2.66, z + sgn * 0.004],
            [wx + 0.02, 2.66, z + sgn * 0.004], glass);
      }
      // End boarding doorways with brass grab handle
      for (final dx in [-L / 2 + 0.35, L / 2 - 1.25]) {
        m.quad([dx, 0.72, z], [dx + 0.85, 0.72, z], [dx + 0.85, 2.72, z], [dx, 2.72, z], wood);
        m.quad([dx + 0.10, 1.78, z + sgn * 0.005], [dx + 0.75, 1.78, z + sgn * 0.005], [dx + 0.75, 2.64, z + sgn * 0.005],
            [dx + 0.10, 2.64, z + sgn * 0.005], glass);
      }
    }

    // Both ends: 3-pane motorman windscreen, route destination box, single central brass headlamp & bumper
    for (final sgn in [-1.0, 1.0]) {
      final ex = sgn * (L / 2 + 0.01);
      m.quad([ex, 1.78, -0.92], [ex, 1.78, 0.92], [ex, 2.68, 0.92], [ex, 2.68, -0.92], glass);
      // Central brass headlamp
      m.cylinder(sgn * (L / 2 + 0.08), 0, 1.05, 1.32, 0.18, brass, seg: 10);
      m.quad([sgn * (L / 2 + 0.27), 1.08, -0.14], [sgn * (L / 2 + 0.27), 1.08, 0.14], [sgn * (L / 2 + 0.27), 1.30, 0.14],
          [sgn * (L / 2 + 0.27), 1.30, -0.14], const Color(0xFFFEF08A),
          emissive: true);
      // Destination board on roof brow
      m.box(sgn * (L / 2 - 0.35), 2.95, -0.58, sgn * (L / 2 + 0.05), 3.24, 0.58, cream);
    }

    // Overhanging curved roof + raised clerestory lantern roof (fenerli çatı)
    m.box(-L / 2 - 0.25, 2.88, -hw - 0.08, L / 2 + 0.25, 3.06, hw + 0.08, darkRed, top: const Color(0xFF991B1B));
    m.box(-L / 2 + 1.2, 3.06, -0.72, L / 2 - 1.2, 3.34, 0.72, red, top: darkRed);
    // Angled trolley pole (troley kolu) reaching backward/upward
    m.box(-0.35, 3.34, -0.25, 0.35, 3.46, 0.25, iron);
    m.ramp(-0.1, 3.46, -2.8, 4.75, -0.04, 0.04, iron);
    return m;
  }

  // ───────────────────────── 5. FUNICULAR & TELEFERİK ─────────────────────────

  static Mesh _funicularSet({required Color accent}) {
    // 2-car stepped funicular train (F1 Taksim-Kabataş / F2 Tünel / F4 Aşiyan)
    return _metroSet(2, accent: accent, driverless: true);
  }

  static Mesh _gondola(Color accent) {
    final m = Mesh();
    // 8-passenger panoramic diamond-profile cabin (Leitner / Poma style for TF1 Maçka & TF2 Eyüp)
    const y0 = 0.0, yMid = 1.05, yTop = 2.25;
    m.box(-1.35, y0, -1.08, 1.35, yMid, 1.08, const Color(0xFFE2E8F0), top: const Color(0xFFCBD5E1));
    m.box(-1.42, yMid - 0.1, -1.12, 1.42, yTop, 1.12, const Color(0xFF0F172A), top: accent);
    // Corner pillars & accent roof cap
    for (final sx in [-1.36, 1.36]) {
      for (final sz in [-1.06, 1.06]) {
        m.box(sx - 0.06, y0, sz - 0.06, sx + 0.06, yTop + 0.08, sz + 0.06, const Color(0xFFE2E8F0));
      }
    }
    m.box(-1.25, yTop, -0.98, 1.25, yTop + 0.16, 0.98, accent);
    // Curved suspension hanger arm + ropeway grip + haul cable
    m.box(-0.09, yTop + 0.16, -0.09, 0.09, 3.95, 0.09, const Color(0xFF475569));
    m.box(-0.65, 3.95, -0.18, 0.65, 4.26, 0.18, const Color(0xFF1E293B));
    m.box(-10, 4.26, -0.035, 10, 4.33, 0.035, const Color(0xFF0F172A));
    return m;
  }

  // ───────────────────────── 6. İETT BUS & METROBÜS ─────────────────────────

  static Mesh _bus(double len, Color body, Color roof, {bool articulated = false, Color? band, required Color accent}) {
    final m = Mesh();
    const hw = 1.28;
    const glass = Color(0xFF0F172A);
    const darkTrim = Color(0xFF1E293B);
    final x0 = -len / 2, x1 = len / 2;

    // Main low-floor body shell
    m.box(x0, 0.36, -hw, x1, 2.98, hw, body, top: roof);
    // Lower dark bumper & side skirt trim
    m.box(x0 + 0.05, 0.32, -hw - 0.01, x1 - 0.05, 0.56, hw + 0.01, darkTrim, faces: 4 | 8 | 16 | 32);

    // Side glazing mask, doors, and livery stripe
    for (final sgn in [-1.0, 1.0]) {
      final z = sgn * (hw + 0.015);
      // Flush black glass beltline from front pillar to rear
      m.quad([x0 + 0.45, 1.28, z], [x1 - 0.55, 1.28, z], [x1 - 0.55, 2.66, z], [x0 + 0.45, 2.66, z], glass);
      if (band != null) {
        m.quad([x0 + 0.15, 0.72, z], [x1 - 0.15, 0.72, z], [x1 - 0.15, 1.02, z], [x0 + 0.15, 1.02, z], band);
      }
      // Double passenger doors
      final doorXs = articulated ? [x1 - 2.1, x1 - 6.8, x0 + 6.2, x0 + 1.6] : [x1 - 1.9, 0.2, x0 + 1.6];
      for (final dx in doorXs) {
        m.quad([dx - 0.62, 0.38, z + sgn * 0.004], [dx + 0.62, 0.38, z + sgn * 0.004], [dx + 0.62, 2.68, z + sgn * 0.004],
            [dx - 0.62, 2.68, z + sgn * 0.004], darkTrim);
        m.quad([dx - 0.50, 0.58, z + sgn * 0.008], [dx - 0.04, 0.58, z + sgn * 0.008], [dx - 0.04, 2.56, z + sgn * 0.008],
            [dx - 0.50, 2.56, z + sgn * 0.008], glass);
        m.quad([dx + 0.04, 0.58, z + sgn * 0.008], [dx + 0.50, 0.58, z + sgn * 0.008], [dx + 0.50, 2.56, z + sgn * 0.008],
            [dx + 0.04, 2.56, z + sgn * 0.008], glass);
      }
    }

    // Front face: curved windscreen, amber LED destination sign, headlights, side mirrors
    m.quad([x1 + 0.015, 1.02, -hw + 0.10], [x1 + 0.015, 1.02, hw - 0.10], [x1 + 0.015, 2.52, hw - 0.10], [x1 + 0.015, 2.52, -hw + 0.10], glass);
    m.quad([x1 + 0.02, 2.55, -hw + 0.18], [x1 + 0.02, 2.55, hw - 0.18], [x1 + 0.02, 2.88, hw - 0.18], [x1 + 0.02, 2.88, -hw + 0.18],
        const Color(0xFFF59E0B),
        emissive: true);
    for (final sgn in [-1.0, 1.0]) {
      // LED headlights
      m.quad([x1 + 0.02, 0.58, sgn * (hw - 0.48)], [x1 + 0.02, 0.58, sgn * (hw - 0.14)], [x1 + 0.02, 0.78, sgn * (hw - 0.14)],
          [x1 + 0.02, 0.78, sgn * (hw - 0.48)], const Color(0xFFFEF9C3),
          emissive: true);
      // Rear taillights
      m.quad([x0 - 0.02, 0.65, sgn * (hw - 0.42)], [x0 - 0.02, 0.65, sgn * (hw - 0.14)], [x0 - 0.02, 1.05, sgn * (hw - 0.14)],
          [x0 - 0.02, 1.05, sgn * (hw - 0.42)], const Color(0xFFEF4444),
          emissive: true);
      // Horn-style exterior mirrors
      m.box(x1 - 0.15, 2.05, sgn * (hw + 0.02), x1 + 0.22, 2.45, sgn * (hw + 0.22), darkTrim);
    }
    // Rear window
    m.quad([x0 - 0.015, 1.48, -hw + 0.18], [x0 - 0.015, 2.62, -hw + 0.18], [x0 - 0.015, 2.62, hw - 0.18], [x0 - 0.015, 1.48, hw - 0.18], glass);

    // Accordion articulation joint for Metrobüs
    if (articulated) {
      m.box(-0.65, 0.38, -hw - 0.02, 0.65, 2.94, hw + 0.02, const Color(0xFF111827));
      for (final rx in [-0.35, 0.0, 0.35]) {
        m.box(rx - 0.05, 0.36, -hw - 0.04, rx + 0.05, 2.96, hw + 0.04, const Color(0xFF334155));
      }
    }

    // Wheels with silver rims
    final axles = articulated ? [x1 - 2.65, -2.1, x0 + 2.8] : [x1 - 2.55, x0 + 2.95];
    for (final ax in axles) {
      for (final z in [-hw + 0.06, hw - 0.06]) {
        m.cylinderZ(ax, 0.50, z, 0.50, 0.32, const Color(0xFF111827));
      }
    }

    // Roof AC pods
    m.box(x0 + len * 0.24, 2.98, -0.78, x0 + len * 0.52, 3.24, 0.78, const Color(0xFFE2E8F0));
    if (articulated) {
      m.box(x0 + len * 0.65, 2.98, -0.78, x0 + len * 0.84, 3.24, 0.78, const Color(0xFFE2E8F0));
    }
    return m;
  }

  // ───────────────────────── 7. ŞEHİR HATLARI CLASSIC VAPUR ─────────────────────────

  /// Iconic Istanbul double-ended passenger steamer (Fenerbahçe / Paşabahçe / Moda / Barış Manço class).
  static Mesh _sehirHatlariVapur() {
    final m = Mesh();
    const B = 12.6, hw = B / 2;
    const white = Color(0xFFF8FAFC);
    const warmWhite = Color(0xFFF1EFEA);
    const bootGreen = Color(0xFF064E3B);
    const hullBlack = Color(0xFF0F172A);
    const teakDeck = Color(0xFFB48456);
    const mahogany = Color(0xFF7C2D12);
    const shYellow = Color(0xFFF59E0B);
    const shBlue = Color(0xFF0B5CAD);
    const glass = Color(0xFF1E293B);

    // 1. Multi-station lofted double-ended hull with flared sheer line & pointed bow/stern stems
    const yKeel = -1.6, yWater = 0.0, yDeck = 2.25;
    final stX = [-32.0, -29.2, -23.5, -14.0, 0.0, 14.0, 23.5, 29.2, 32.0];
    final stW = [0.12, 2.45, 5.10, 6.20, 6.30, 6.20, 5.10, 2.45, 0.12];
    final stSheer = [2.95, 2.65, 2.40, 2.28, 2.25, 2.28, 2.40, 2.65, 2.95];

    for (var i = 0; i < stX.length - 1; i++) {
      final x0 = stX[i], x1 = stX[i + 1];
      final w0 = stW[i], w1 = stW[i + 1];
      final sh0 = stSheer[i], sh1 = stSheer[i + 1];
      for (final sgn in [-1.0, 1.0]) {
        // Underwater dark green boot-topping
        m.quad([x0, yKeel, sgn * w0 * 0.65], [x1, yKeel, sgn * w1 * 0.65], [x1, yWater + 0.15, sgn * w1 * 0.84],
            [x0, yWater + 0.15, sgn * w0 * 0.84], bootGreen);
        // Lower dark steel hull strake
        m.quad([x0, yWater + 0.15, sgn * w0 * 0.84], [x1, yWater + 0.15, sgn * w1 * 0.84], [x1, 1.05, sgn * w1 * 0.92],
            [x0, 1.05, sgn * w0 * 0.92], hullBlack);
        // Upper white flared topsides
        m.quad([x0, 1.05, sgn * w0 * 0.92], [x1, 1.05, sgn * w1 * 0.92], [x1, sh1, sgn * w1], [x0, sh0, sgn * w0], white);
        // Heavy timber/rubber rubbing strake (usturmaça kuşağı) along the sponson edge
        m.quad([x0, sh0 - 0.28, sgn * (w0 + 0.08)], [x1, sh1 - 0.28, sgn * (w1 + 0.08)], [x1, sh1 - 0.04, sgn * (w1 + 0.08)],
            [x0, sh0 - 0.04, sgn * (w0 + 0.08)], mahogany);
      }
      // Teak main deck planking
      m.quad([x0, sh0, -w0], [x1, sh1, -w1], [x1, sh1, w1], [x0, sh0, w0], teakDeck);
    }

    // 2. Main passenger salon (Alt Salon) with classic arched windows & open fore/aft verandas
    const mX0 = -23.0, mX1 = 23.0, mY0 = yDeck, mY1 = yDeck + 2.75, mW = hw * 0.86;
    m.box(mX0, mY0, -mW, mX1, mY1, mW, white, top: teakDeck);
    // Blue Şehir Hatları cheatline under main deck windows
    for (final sgn in [-1.0, 1.0]) {
      final z = sgn * (mW + 0.02);
      m.quad([mX0 + 0.3, mY0 + 0.55, z], [mX1 - 0.3, mY0 + 0.55, z], [mX1 - 0.3, mY0 + 0.82, z], [mX0 + 0.3, mY0 + 0.82, z], shBlue);
      // 18 classic promenade windows along each side
      for (var k = 0; k < 18; k++) {
        final wx = mX0 + 1.0 + k * 2.45;
        m.quad([wx, mY0 + 1.02, z], [wx + 1.65, mY0 + 1.02, z], [wx + 1.65, mY0 + 2.25, z], [wx, mY0 + 2.25, z], glass);
        // Mahogany window frame top arch accent
        m.quad([wx - 0.05, mY0 + 2.25, z], [wx + 1.70, mY0 + 2.25, z], [wx + 1.70, mY0 + 2.36, z], [wx - 0.05, mY0 + 2.36, z], mahogany);
      }
      // Orange life-rings (can simitleri) mounted along the railing
      for (var lx = -18.0; lx <= 18.0; lx += 9.0) {
        m.box(lx - 0.32, mY1 + 0.25, sgn * (hw * 0.92), lx + 0.32, mY1 + 0.78, sgn * (hw * 0.95), const Color(0xFFEA580C));
      }
    }

    // 3. Upper salon & semi-open sun promenade deck (Üst Güverte)
    const uX0 = -18.5, uX1 = 18.5, uY0 = mY1, uY1 = uY0 + 2.55, uW = hw * 0.76;
    // Extended canopy roof supported over open promenade walkways
    m.box(uX0 - 2.5, uY1 - 0.18, -hw * 0.90, uX1 + 2.5, uY1, hw * 0.90, warmWhite, top: const Color(0xFFE2E8F0));
    m.box(uX0, uY0, -uW, uX1, uY1 - 0.18, uW, white);
    for (final sgn in [-1.0, 1.0]) {
      final z = sgn * (uW + 0.02);
      for (var k = 0; k < 14; k++) {
        final wx = uX0 + 1.1 + k * 2.5;
        m.quad([wx, uY0 + 0.88, z], [wx + 1.7, uY0 + 0.88, z], [wx + 1.7, uY0 + 2.02, z], [wx, uY0 + 2.02, z], glass);
      }
      // Classic wooden slat benches on the open promenade decks
      for (final bx in [-21.2, 19.2]) {
        m.box(bx, uY0, sgn * (uW * 0.55), bx + 1.8, uY0 + 0.65, sgn * (uW * 0.88), mahogany);
      }
    }

    // 4. Twin wheelhouses (Baş ve Kıç Köprüüstü) with wide bridge wings (Kırlangıçlar)
    for (final sgn in [-1.0, 1.0]) {
      final bx0 = sgn > 0 ? 11.5 : -15.5;
      final bx1 = sgn > 0 ? 15.5 : -11.5;
      // Bridge wing walkway extending beyond the beam
      m.box(bx0 + 0.4, uY1, -hw * 1.02, bx1 - 0.4, uY1 + 0.95, hw * 1.02, white, top: teakDeck);
      // Central timber-trimmed wheelhouse (Kaptan Köşkü)
      m.box(bx0, uY1, -hw * 0.46, bx1, uY1 + 2.35, hw * 0.46, white, top: warmWhite);
      m.box(bx0 - 0.05, uY1 + 0.85, -hw * 0.48, bx1 + 0.05, uY1 + 1.15, hw * 0.48, mahogany);
      final faceX = sgn > 0 ? bx1 + 0.02 : bx0 - 0.02;
      m.quad([faceX, uY1 + 1.18, -hw * 0.40], [faceX, uY1 + 1.18, hw * 0.40], [faceX, uY1 + 2.05, hw * 0.40], [faceX, uY1 + 2.05, -hw * 0.40], glass);
      // Navigation mast above wheelhouse
      final mx = (bx0 + bx1) / 2;
      m.cylinder(mx, 0, uY1 + 2.35, uY1 + 6.4, 0.12, white, seg: 8);
      m.box(mx - 0.08, uY1 + 4.8, -1.2, mx + 0.08, uY1 + 4.95, 1.2, white);
    }
    // Port (red) and Starboard (green) navigation lamp boxes on forward bridge wings
    m.box(13.0, uY1 + 0.95, -hw * 1.02, 13.8, uY1 + 1.35, -hw * 0.92, const Color(0xFF16A34A), emissive: true);
    m.box(13.0, uY1 + 0.95, hw * 0.92, 13.8, uY1 + 1.35, hw * 1.02, const Color(0xFFDC2626), emissive: true);

    // 5. Iconic Şehir Hatları central funnel (Baca): white/ochre cylinder with golden-yellow band & black top
    m.box(-2.8, uY1, -1.7, 2.8, uY1 + 1.15, 1.7, white); // Engine room skylight casing
    m.cylinder(0, 0, uY1 + 1.15, uY1 + 5.2, 1.38, white, seg: 16);
    m.cylinder(0, 0, uY1 + 3.25, uY1 + 4.55, 1.41, shYellow, seg: 16);
    m.cylinder(0, 0, uY1 + 5.2, uY1 + 6.35, 1.42, hullBlack, seg: 16);

    // 6. Turkish Flag flying at the stern (-x) flagpole
    m.cylinder(-29.5, 0, 2.75, 6.2, 0.07, white, seg: 6);
    m.quad([-31.6, 5.0, 0.0], [-29.5, 5.15, 0.0], [-29.5, 6.1, 0.0], [-31.6, 5.95, 0.0], const Color(0xFFE11D48), emissive: true);

    return m;
  }

  // ───────────────────────── 8. İDO WAVE-PIERCING CATAMARAN (DENİZ OTOBÜSÜ) ─────────────────────────

  static Mesh _idoCatamaran(Color accent) {
    final m = Mesh();
    const L = 40.0, hw = 5.4;
    const white = Color(0xFFF8FAFC), dark = Color(0xFF0F172A), idoPink = Color(0xFFD61F69), idoBlue = Color(0xFF0284C7);

    // Twin wave-piercing aluminum catamaran demihulls with sharp bows & open tunnel gap between them
    for (final sgn in [-1.0, 1.0]) {
      final zMid = sgn * (hw - 1.15);
      // Main pontoon body
      m.box(-L / 2, -1.15, zMid - 0.95, L / 2 - 5.5, 1.15, zMid + 0.95, white);
      m.box(-L / 2, -1.18, zMid - 0.98, L / 2 - 5.5, -0.25, zMid + 0.98, dark, faces: 4 | 16 | 32);
      // Wave-piercing knife bow
      m.quad([L / 2 - 5.5, -1.15, zMid - 0.95], [L / 2 + 2.5, 0.35, zMid], [L / 2 + 1.2, 1.25, zMid], [L / 2 - 5.5, 1.15, zMid - 0.95], white);
      m.quad([L / 2 - 5.5, -1.15, zMid + 0.95], [L / 2 - 5.5, 1.15, zMid + 0.95], [L / 2 + 1.2, 1.25, zMid], [L / 2 + 2.5, 0.35, zMid], white);
    }

    // Bridging wet-deck & main aerodynamic passenger cabin
    m.box(-L / 2 + 0.8, 1.15, -hw, L / 2 - 3.5, 4.05, hw, white, top: const Color(0xFFE2E8F0));
    // Raked aerodynamic front cabin glacis
    m.quad([L / 2 - 3.5, 1.15, -hw], [L / 2 + 0.2, 1.25, -hw * 0.72], [L / 2 - 2.2, 3.85, -hw * 0.78], [L / 2 - 3.5, 4.05, -hw], white);
    m.quad([L / 2 - 3.5, 1.15, hw], [L / 2 - 3.5, 4.05, hw], [L / 2 - 2.2, 3.85, hw * 0.78], [L / 2 + 0.2, 1.25, hw * 0.72], white);
    m.quad([L / 2 + 0.2, 1.25, -hw * 0.72], [L / 2 + 0.2, 1.25, hw * 0.72], [L / 2 - 2.2, 3.85, hw * 0.78], [L / 2 - 2.2, 3.85, -hw * 0.78], white);

    // Swept ribbon windows & İDO magenta/blue racing stripes
    for (final sgn in [-1.0, 1.0]) {
      final z = sgn * (hw + 0.02);
      m.quad([-L / 2 + 2.0, 2.35, z], [L / 2 - 4.2, 2.35, z], [L / 2 - 5.2, 3.58, z], [-L / 2 + 1.4, 3.58, z], dark);
      m.quad([-L / 2 + 1.0, 1.42, z], [L / 2 - 3.6, 1.42, z], [L / 2 - 3.6, 1.82, z], [-L / 2 + 1.0, 1.82, z], idoBlue);
      m.quad([-L / 2 + 1.0, 1.88, z], [L / 2 - 4.0, 1.88, z], [L / 2 - 4.0, 2.15, z], [-L / 2 + 1.0, 2.15, z], idoPink);
    }

    // Elevated cockpit wheelhouse pod & radar dome
    m.box(-2.0, 4.05, -hw * 0.56, L / 2 - 5.5, 5.95, hw * 0.56, white, top: const Color(0xFFE2E8F0));
    m.quad([L / 2 - 5.48, 4.45, -hw * 0.50], [L / 2 - 5.48, 4.45, hw * 0.50], [L / 2 - 5.48, 5.65, hw * 0.50], [L / 2 - 5.48, 5.65, -hw * 0.50], dark);
    m.cylinder(2.0, 0, 5.95, 7.6, 0.14, white, seg: 8);
    m.cylinder(2.0, 0, 7.6, 8.05, 0.48, white, seg: 10);
    return m;
  }

  // ───────────────────────── 9. TURYOL / DENTUR BOSPHORUS MOTOR ─────────────────────────

  static Mesh _bosphorusMotor(Color accent) {
    final m = Mesh();
    const white = Color(0xFFF8FAFC), dark = Color(0xFF0F172A), deckCol = Color(0xFF94A3B8);

    // Single-ended displacement motor hull: wide flat transom stern (-x) and flared raised bow (+x)
    final stX = [-17.0, -8.0, 4.0, 12.5, 17.0];
    final stW = [3.8, 4.2, 4.1, 2.3, 0.12];
    final stY = [1.8, 1.85, 2.0, 2.45, 2.95];
    for (var i = 0; i < stX.length - 1; i++) {
      final x0 = stX[i], x1 = stX[i + 1], w0 = stW[i], w1 = stW[i + 1], y0 = stY[i], y1 = stY[i + 1];
      for (final sgn in [-1.0, 1.0]) {
        m.quad([x0, -1.1, sgn * w0 * 0.8], [x1, -1.1, sgn * w1 * 0.8], [x1, 0.2, sgn * w1 * 0.92], [x0, 0.2, sgn * w0 * 0.92], dark);
        m.quad([x0, 0.2, sgn * w0 * 0.92], [x1, 0.2, sgn * w1 * 0.92], [x1, y1, sgn * w1], [x0, y0, sgn * w0], white);
        m.quad([x0, y0 - 0.45, sgn * (w0 + 0.02)], [x1, y1 - 0.45, sgn * (w1 + 0.02)], [x1, y1 - 0.12, sgn * (w1 + 0.02)],
            [x0, y0 - 0.12, sgn * (w0 + 0.02)], accent);
      }
      m.quad([x0, y0, -w0], [x1, y1, -w1], [x1, y1, w1], [x0, y0, w0], deckCol);
    }
    // Transom stern closure
    m.quad([-17.0, -1.1, -3.0], [-17.0, -1.1, 3.0], [-17.0, 1.8, 3.8], [-17.0, 1.8, -3.8], white);

    // Lower enclosed salon + upper sun deck canopy + forward pilothouse
    m.box(-14.5, 1.85, -3.5, 8.5, 4.35, 3.5, white, top: deckCol);
    for (final sgn in [-1.0, 1.0]) {
      final z = sgn * 3.52;
      m.quad([-13.5, 2.55, z], [7.5, 2.55, z], [7.5, 3.95, z], [-13.5, 3.95, z], dark);
    }
    // Forward pilothouse
    m.box(2.0, 4.35, -2.5, 8.2, 6.25, 2.5, white);
    m.quad([8.22, 4.85, -2.2], [8.22, 4.85, 2.2], [8.22, 5.95, 2.2], [8.22, 5.95, -2.2], dark);
    // Aft sun-deck awning supported by stanchions
    m.box(-14.0, 6.15, -3.4, 2.0, 6.35, 3.4, accent);
    m.cylinder(5.5, 0, 6.25, 8.8, 0.10, white, seg: 8);
    return m;
  }

  // ───────────────────────── 10. ARABALI VAPUR (RO-RO CAR FERRY) ─────────────────────────

  static Mesh _carFerry() {
    final m = Mesh();
    const L = 68.0, hw = 8.2;
    const white = Color(0xFFF8FAFC), navy = Color(0xFF1E3A8A), asphalt = Color(0xFF334155), glass = Color(0xFF0F172A);

    // Wide double-ended hull with blue lower freeboard
    m.box(-L / 2, -1.4, -hw, L / 2, 2.2, hw, white, top: asphalt);
    m.box(-L / 2, -1.42, -hw - 0.02, L / 2, 0.4, hw + 0.02, navy, faces: 4 | 8 | 16 | 32);
    // Articulated bow and stern loading ramps (kapaklar)
    m.ramp(L / 2, 2.0, L / 2 + 4.2, 2.6, -hw * 0.65, hw * 0.65, const Color(0xFF64748B));
    m.ramp(-L / 2, 2.0, -L / 2 - 4.2, 2.6, -hw * 0.65, hw * 0.65, const Color(0xFF64748B));

    // Side passenger casings flanking the open drive-through vehicle deck
    for (final sgn in [-1.0, 1.0]) {
      final z0 = sgn > 0 ? hw - 1.65 : -hw;
      final z1 = sgn > 0 ? hw : -hw + 1.65;
      m.box(-L / 2 + 5.0, 2.2, z0, L / 2 - 5.0, 5.8, z1, white);
    }

    // Upper passenger salon spanning above the car deck
    m.box(-L / 2 + 11.0, 5.8, -hw, L / 2 - 11.0, 8.6, hw, white, top: const Color(0xFFE2E8F0));
    for (final sgn in [-1.0, 1.0]) {
      final z = sgn * (hw + 0.02);
      for (var k = 0; k < 16; k++) {
        final wx = -L / 2 + 12.2 + k * 2.75;
        m.quad([wx, 6.55, z], [wx + 1.9, 6.55, z], [wx + 1.9, 8.05, z], [wx, 8.05, z], glass);
      }
    }

    // Central high portal wheelhouse straddling the upper deck
    m.box(-4.8, 8.6, -3.4, 4.8, 11.2, 3.4, white);
    for (final sgn in [-1.0, 1.0]) {
      m.quad([sgn * 4.82, 9.3, -2.9], [sgn * 4.82, 9.3, 2.9], [sgn * 4.82, 10.7, 2.9], [sgn * 4.82, 10.7, -2.9], glass);
    }
    m.cylinder(0, 0, 11.2, 14.5, 0.16, white, seg: 8);

    // 3-lane vehicle deck markings + realistic 3D cars parked on deck
    final colors = [
      const Color(0xFFDC2626),
      const Color(0xFF2563EB),
      const Color(0xFFF8FAFC),
      const Color(0xFFF59E0B),
      const Color(0xFF10B981),
    ];
    for (var i = 0; i < 12; i++) {
      final row = i % 6;
      final lane = i ~/ 6;
      final cx = -L / 2 + 7.0 + row * 8.8;
      final cz = lane == 0 ? -2.6 : 2.6;
      final col = colors[i % colors.length];
      m.box(cx, 2.2, cz - 0.95, cx + 4.2, 3.15, cz + 0.95, col);
      m.box(cx + 0.8, 3.15, cz - 0.82, cx + 3.1, 3.75, cz + 0.82, col, top: Colors.white);
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
      tri(x, y, zo, x0, y0, zo, x1, y1, zo, const Color(0xFF94A3B8));
    }
  }
}
