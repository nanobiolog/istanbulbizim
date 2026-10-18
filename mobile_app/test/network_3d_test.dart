import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/network_models.dart';
import 'package:mobile_app/services/network_repository.dart';
import 'package:mobile_app/services/schedule_engine.dart';
import 'package:mobile_app/screens/station_walk_screen.dart';
import 'package:mobile_app/three_d/engine3d.dart';
import 'package:mobile_app/three_d/scene_views.dart';
import 'package:mobile_app/three_d/station_scene.dart';
import 'package:mobile_app/three_d/vehicle_models.dart';

NetworkRepository loadRepo() {
  final rail = jsonDecode(File('assets/data/rail_network.json').readAsStringSync()) as Map<String, dynamic>;
  final fer = jsonDecode(File('assets/data/ferry_network.json').readAsStringSync()) as Map<String, dynamic>;
  final r = NetworkRepository();
  r.lines = (rail['lines'] as List).map((l) => RailLine.fromJson(l as Map<String, dynamic>)).toList();
  r.lineByCode = {for (final l in r.lines) l.code: l};
  r.stations = {
    for (final e in (rail['stations'] as Map<String, dynamic>).entries) e.key: RailStation.fromJson(e.key, e.value as Map<String, dynamic>)
  };
  r.piers = {
    for (final e in (fer['piers'] as Map<String, dynamic>).entries)
      e.key: Pier(e.key, e.value['name'], e.value['full'], LatLng((e.value['lat'] as num).toDouble(), (e.value['lon'] as num).toDouble()),
          (e.value['ops'] as List).map((x) => x.toString()).toList())
  };
  r.ferryLines = (fer['lines'] as List).map((l) => FerryLine.fromJson(l as Map<String, dynamic>)).toList();
  r.legs = {for (final e in (fer['legs'] as Map<String, dynamic>).entries) e.key: decodePolyline(e.value.toString())};
  r.loaded = true;
  return r;
}

void main() {
  late NetworkRepository repo;
  late ScheduleEngine engine;
  final morning = DateTime(2026, 10, 19, 8, 30); // a Monday

  setUpAll(() {
    repo = loadRepo();
    engine = ScheduleEngine(repo);
  });

  test('Marmaray follows the real track and has all 43 stations', () {
    final b1 = repo.lineByCode['B1']!;
    final main = b1.variants.first;
    expect(main.stops.length, 43);
    expect(main.path.length, inInclusiveRange(74000, 78000)); // Halkalı – Gebze 76.6 km
    // the track must dip under the Bosphorus between Sirkeci and Üsküdar (not a straight hop)
    final names = main.stops.map((s) => repo.stations[s.stationId]!.name).toList();
    expect(names.first, 'Halkalı');
    expect(names.last, 'Gebze');
    expect(names, containsAllInOrder(['Kazlıçeşme', 'Yenikapı', 'Sirkeci', 'Üsküdar', 'Ayrılık Çeşmesi']));
    expect(main.path.points.length, greaterThan(300));
  });

  test('schedule engine places trains and departures in the morning peak', () {
    final sw = Stopwatch()..start();
    final trains = engine.trainsAt(morning);
    expect(trains.where((t) => t.line.code == 'B1').length, greaterThan(10));
    expect(trains.where((t) => t.line.code == 'M2').length, greaterThan(8));
    final yk = repo.stations.values.firstWhere((s) => s.name == 'Yenikapı' && s.lines.contains('B1'));
    final deps = engine.departuresAt(yk, morning);
    expect(deps.where((d) => d.line.code == 'B1').length, 2);
    for (final d in deps) {
      expect(d.at.difference(morning).inMinutes, lessThan(20));
    }
    final ev = engine.stationEvents(yk, repo.lineByCode['B1']!, morning);
    expect(ev.length, 2);
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });

  test('ferries sail along the timetable', () {
    final v = engine.vesselsAt(morning);
    expect(v.length, greaterThan(15));
    final busiest = repo.piers.values.reduce((a, b) =>
        repo.ferryLines.where((l) => l.piers.contains(a.id)).length >= repo.ferryLines.where((l) => l.piers.contains(b.id)).length ? a : b);
    expect(engine.pierDepartures(busiest.id, morning).isNotEmpty, isTrue, reason: busiest.name);
  });

  test('Yenikapı station scene builds and renders quickly (reveal + walk)', () {
    final yk = repo.stations.values.firstWhere((s) => s.name == 'Yenikapı' && s.lines.contains('B1'));
    final plan = StationPlan(yk, repo.lineByCode['B1']!);
    expect(plan.underground, isTrue);
    expect(plan.depth, 24);
    final sw = Stopwatch()..start();
    for (final reveal in [true, false]) {
      final scene = StationScene(plan, reveal: reveal);
      expect(scene.pathLength, greaterThan(100));
      final train = StationScene.trainModelFor(plan);
      final r = Renderer3D();
      final cam = Camera3D();
      if (reveal) {
        cam.orbit(-60, -12, 0, 160, -1.0, 0.55);
      } else {
        final (x, y, z, _, _) = scene.pointAt(0);
        cam
          ..ex = x
          ..ey = y + 1.65
          ..ez = z;
      }
      for (var f = 0; f < 5; f++) {
        final rec = ui.PictureRecorder();
        final canvas = Canvas(rec);
        final m = StationScene.trainAt(plan, 1, -40.0 * f, train);
        r.paint(canvas, const Size(390, 844), cam, [scene.staticMesh, ?m], const RenderStyle(), labels: scene.labels);
        rec.endRecording().dispose();
      }
      // ignore: avoid_print
      print('reveal=$reveal triangles=${scene.staticMesh.triangles} drawn=${r.lastTriangles} t=${sw.elapsedMilliseconds}ms');
    }
    expect(sw.elapsedMilliseconds, lessThan(8000));
  });

  test('every rail station has a buildable plan', () {
    for (final st in repo.stations.values) {
      for (final code in st.lines) {
        final line = repo.lineByCode[code];
        if (line == null) continue;
        final scene = StationScene(StationPlan(st, line));
        expect(scene.staticMesh.triangles, greaterThan(100), reason: '${st.name} $code');
        expect(scene.pathLength.isFinite, isTrue);
      }
    }
  });

  testWidgets('reveal view and walk screen pump frames without hanging', (tester) async {
    final yk = repo.stations.values.firstWhere((s) => s.name == 'Yenikapı' && s.lines.contains('B1'));
    final plan = StationPlan(yk, repo.lineByCode['B1']!);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StationRevealView(plan: plan, engine: engine))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpWidget(MaterialApp(home: StationWalkScreen(plan: plan, repo: repo, engine: engine)));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(StationWalkScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('vehicle models build', () {
    for (final k in VehicleKind.values) {
      expect(VehicleModels.build(k).triangles, greaterThan(20));
    }
  });
}
