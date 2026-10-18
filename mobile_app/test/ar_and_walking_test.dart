import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/services/ar_heading.dart';
import 'package:mobile_app/services/walking_directions_service.dart';

/// Device-frame sensor readings for a phone whose camera (−Z) looks at [headingDeg] with the
/// camera axis raised by [pitchDeg] (portrait, no roll). Istanbul field: 45 µT, inclination 56°.
({List<double> g, List<double> m}) _pose(double headingDeg, double pitchDeg, {List<double> bias = const [0, 0, 0]}) {
  final h = headingDeg * math.pi / 180, p = pitchDeg * math.pi / 180;
  // World (east, north, up) unit vectors of the device axes.
  final camFwd = [math.sin(h) * math.cos(p), math.cos(h) * math.cos(p), math.sin(p)]; // −Z
  final yAxis = [-math.sin(h) * math.sin(p), -math.cos(h) * math.sin(p), math.cos(p)]; // top of phone
  final xAxis = [math.cos(h), -math.sin(h), 0.0]; // right edge
  final zAxis = camFwd.map((v) => -v).toList();
  double dot(List<double> a, List<double> b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const inc = 56 * math.pi / 180, b = 45.0;
  final field = [0.0, b * math.cos(inc), -b * math.sin(inc)];
  final up = [0.0, 0.0, 9.81]; // accelerometer reads +g "up" (Android convention)
  return (
    g: [dot(up, xAxis), dot(up, yAxis), dot(up, zAxis)],
    m: [dot(field, xAxis) + bias[0], dot(field, yAxis) + bias[1], dot(field, zAxis) + bias[2]],
  );
}

double _angErr(double a, double b) => (((a - b + 540) % 360) - 180).abs();

void main() {
  test('camera heading is correct for every direction and tilt while held upright', () {
    for (final heading in [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]) {
      for (final pitch in [-30.0, 0.0, 25.0]) {
        final s = _pose(heading, pitch);
        final r = HeadingEstimator.cameraHeadingPitch(s.g, s.m)!;
        expect(_angErr(r.heading, heading), lessThan(0.5), reason: 'heading $heading pitch $pitch');
        expect(r.pitch, closeTo(pitch, 0.5));
      }
    }
  });

  test('flat phone uses the top edge like a compass', () {
    // Lying face up, top edge pointing east: camera looks straight down (pitch −90).
    final s = _pose(90, -90);
    final r = HeadingEstimator.cameraHeadingPitch(s.g, s.m)!;
    expect(r.pitch, closeTo(-90, 0.5));
    // Top edge = the direction the camera faced before tilting down.
    expect(_angErr(r.heading, 90), lessThan(1));
  });

  test('estimator applies declination and learns the iOS hard-iron bias', () {
    final plain = HeadingEstimator(smoothing: 1);
    final s = _pose(30, 0);
    plain.addAccelerometer(s.g[0], s.g[1], s.g[2]);
    plain.addMagnetometer(s.m[0], s.m[1], s.m[2]);
    expect(_angErr(plain.heading!, 30 + istanbulDeclinationDeg), lessThan(1));

    const bias = [60.0, -35.0, 80.0];
    final ios = HeadingEstimator(calibrateHardIron: true, smoothing: 1);
    expect(ios.hardIronReady, isFalse);
    // User waves the phone around: field seen from many orientations.
    for (var h = 0.0; h < 360; h += 20) {
      for (final p in [-80.0, -40.0, 0.0, 40.0, 80.0]) {
        final q = _pose(h, p, bias: bias);
        ios.addAccelerometer(q.g[0], q.g[1], q.g[2]);
        ios.addMagnetometer(q.m[0], q.m[1], q.m[2]);
      }
    }
    expect(ios.hardIronReady, isTrue);
    final t = _pose(200, 0, bias: bias);
    for (var i = 0; i < 30; i++) {
      ios.addAccelerometer(t.g[0], t.g[1], t.g[2]);
      ios.addMagnetometer(t.m[0], t.m[1], t.m[2]);
    }
    expect(_angErr(ios.heading!, 200 + istanbulDeclinationDeg), lessThan(8));
  });

  test('GPS course slowly corrects compass drift while walking', () {
    final e = HeadingEstimator(smoothing: 1, declination: 0);
    final s = _pose(100, 0);
    e.addAccelerometer(s.g[0], s.g[1], s.g[2]);
    e.addMagnetometer(s.m[0], s.m[1], s.m[2]);
    for (var i = 0; i < 120; i++) {
      e.applyCourse(120, 1.4);
    }
    expect(_angErr(e.heading!, 120), lessThan(2));
    e.applyCourse(300, 1.4); // walking backwards / looking sideways: ignored
    expect(_angErr(e.heading!, 120), lessThan(2));
  });

  test('AR projection places bearings across the camera view', () {
    const p = ArProjection(hFovDeg: 54);
    expect(p.x(90, 90, 400), closeTo(200, 1e-6));
    expect(p.x(100, 90, 400)!, greaterThan(200));
    expect(p.x(80, 90, 400)!, lessThan(200));
    expect(p.x(270, 90, 400), isNull); // behind the user
    expect(p.horizonY(0, 800), closeTo(400, 1e-6));
    expect(p.horizonY(20, 800), greaterThan(400)); // looking up: horizon drops
    expect(ArProjection.relative(10, 350), closeTo(20, 1e-9));
  });

  test('OSRM foot route parses into Turkish steps and tracks progress', () {
    final osrm = {
      'code': 'Ok',
      'routes': [
        {
          'distance': 220.0,
          'duration': 170.0,
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [28.9800, 41.0000],
              [28.9800, 41.0010],
              [28.9812, 41.0010],
            ]
          },
          'legs': [
            {
              'steps': [
                {'distance': 111.0, 'name': 'İstiklal Caddesi', 'maneuver': {'type': 'depart', 'modifier': 'straight', 'location': [28.98, 41.0]}},
                {'distance': 101.0, 'name': 'Meşelik Sokak', 'maneuver': {'type': 'turn', 'modifier': 'right', 'location': [28.98, 41.001]}},
                {'distance': 0.0, 'name': '', 'maneuver': {'type': 'arrive', 'location': [28.9812, 41.001]}},
              ]
            }
          ]
        }
      ]
    };
    final r = WalkingDirectionsService.parseOsrm(osrm)!;
    expect(r.routed, isTrue);
    expect(r.steps.map((s) => s.instruction).toList(), [
      'İstiklal Caddesi boyunca yürümeye başlayın',
      'Sağa dönün — Meşelik Sokak',
      'Varış noktasına ulaştınız',
    ]);

    // Halfway up the first leg, 3 m off the line.
    final prog = WalkingDirectionsService.progress(r, const LatLng(41.0005, 28.98004));
    expect(prog.offRouteM, lessThan(5));
    expect(prog.alongM, closeTo(55, 3));
    expect(prog.nextStepIndex, 1);
    expect(prog.toNextStepM, closeTo(56, 4));
    expect(prog.lookahead.latitude, greaterThan(41.0005));

    // Past the corner the look-ahead turns east.
    final later = WalkingDirectionsService.progress(r, const LatLng(41.0010, 28.9803));
    expect(later.nextStepIndex, 2);
    expect(later.lookahead.longitude, greaterThan(28.9803));
  });

  test('straight-line fallback still gives a compass instruction', () {
    final r = WalkingDirectionsService.straight(const LatLng(41.0, 28.98), const LatLng(41.0, 28.99));
    expect(r.routed, isFalse);
    expect(r.steps.first.instruction, 'Doğu yönünde yürüyün');
    expect(r.distanceM, closeTo(840, 10));
  });
}
