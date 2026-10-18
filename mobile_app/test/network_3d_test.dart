import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/network_models.dart';
import 'package:mobile_app/models/rail_models.dart';
import 'package:mobile_app/services/rail_engine.dart';
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
    for (final e in (rail['stations'] as Map<String, dynamic>).entries) e.key: NetworkStation.fromJson(e.key, e.value as Map<String, dynamic>)
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

  test('official Metro İstanbul timetables drive the network engine', () {
    // fixed instant: 2026-10-18 08:30 in Istanbul (fixtures are that service day)
    final day = railServiceDay(DateTime.utc(2026, 10, 18, 5, 30));
    final wall = DateTime(2026, 10, 18, 8, 30); // the network engine runs on Istanbul wall-clock fields
    int secOfDay(DateTime t) => t.hour * 3600 + t.minute * 60 + t.second;
    for (final code in ['M2', 'M1A', 'M4', 'T1', 'M5', 'M7']) {
      final sched = RailSchedule.fromJson(
          jsonDecode(File('test/fixtures/rail_schedule_$code.json').readAsStringSync()) as Map<String, dynamic>);
      final eng = ScheduleEngine(repo);
      expect(eng.applyOfficial(sched), isTrue, reason: code);
      expect(eng.isOfficial(code), isTrue);
      // departures at a mid-line station (matched by name) agree with the official engine
      final onLine = repo.stations.values.where((s) => s.lines.contains(code)).toList();
      var mid = sched.stations.length ~/ 2;
      NetworkStation? st;
      for (var k = 0; k < sched.stations.length && st == null; k++) {
        final i = (mid + k) % sched.stations.length;
        st = onLine.where((s) => railPlainName(s.name) == railPlainName(sched.stations[i].name)).firstOrNull;
        if (st != null) mid = i;
      }
      if (st == null) continue;
      final official = railDeparturesAt(sched, mid, day, perDirection: 1);
      final mine = eng.departuresAt(st, wall).where((d) => d.line.code == code).toList();
      expect(official, isNotEmpty, reason: code);
      expect(mine, isNotEmpty, reason: code);
      for (final o in official) {
        final oSec = secOfDay(o.at.toUtc().add(const Duration(hours: 3)));
        final closest = mine.map((m) => (secOfDay(m.at) - oSec).abs()).reduce(math.min);
        // The old M7 station list (which the official timetable is keyed to) has Yeşilpınar before
        // Veysel Karani; that station is interpolated, so allow a little more there.
        expect(closest, lessThan(code == 'M7' ? 180 : 75), reason: '$code ${st.name}: official ${o.at} vs ${mine.map((m) => m.at)}');
      }
    }
  });

  test('ferries sail along the timetable', () {
    final v = engine.vesselsAt(morning);
    expect(v.length, greaterThan(15));
    final busiest = repo.piers.values.reduce((a, b) =>
        repo.ferryLines.where((l) => l.piers.contains(a.id)).length >= repo.ferryLines.where((l) => l.piers.contains(b.id)).length ? a : b);
    expect(engine.pierDepartures(busiest.id, morning).isNotEmpty, isTrue, reason: busiest.name);
  });

  test('ferry cancellations and replacement timetables apply only on the notice day', () {
    final eng = ScheduleEngine(repo);
    final sh = repo.ferryLines.where((l) => l.operatorId == 'sh').toList();
    final busy = sh.reduce((a, b) => a.trips.length >= b.trips.length ? a : b);
    final pier = busy.piers.first;
    int sailing(DateTime t) => eng.vesselsAt(t).where((v) => v.line.id == busy.id).length;
    expect(sailing(morning), greaterThan(0), reason: busy.name);

    // cancelled today: no vessels, departures flagged, next day unaffected
    eng.ferryStatus = FerryStatus.fromJson({
      'date': '2026-10-19',
      'active': true,
      'message': 'Olumsuz hava koşulları nedeniyle',
      'cancelled_line_ids': [busy.id],
      'updated_at': DateTime.utc(2026, 10, 19, 4, 15).millisecondsSinceEpoch,
    });
    expect(eng.ferryStatus!.updatedAt!.hour, 7); // Istanbul wall clock
    expect(sailing(morning), 0);
    final deps = eng.pierDepartures(pier, morning).where((d) => d.line.id == busy.id).toList();
    expect(deps, isNotEmpty);
    expect(deps.every((d) => d.cancelled), isTrue);
    expect(sailing(morning.add(const Duration(days: 1))), greaterThan(0));

    // replacement timetable: exactly the published trips run that day, whatever their day mask
    final a = busy.trips.first.piers.first, b = busy.trips.first.piers.last;
    eng.ferryStatus = FerryStatus.fromJson({
      'date': '2026-10-19',
      'active': true,
      'overrides': {
        busy.id: {
          'patterns': [
            {
              'trips': [
                {'d': 64, 's': [[a, 8 * 60 + 20], [b, 8 * 60 + 50]]},
              ]
            }
          ]
        }
      },
    });
    final v = eng.vesselsAt(morning).where((v) => v.line.id == busy.id).toList();
    expect(v.length, 1);
    expect(eng.tripsFor(busy, morning).$3, isTrue);
    expect(eng.lineTimetableAt(busy, a, morning).length, 1);
    eng.ferryStatus = null;
  });

  test('network changes add new lines and hide closed ones', () {
    final r = loadRepo();
    final m2 = r.lineByCode['M2']!;
    final json = jsonDecode(File('assets/data/rail_network.json').readAsStringSync()) as Map<String, dynamic>;
    final raw = (json['lines'] as List).cast<Map<String, dynamic>>().firstWhere((l) => l['code'] == 'M2');
    final fresh = {...raw, 'code': 'M99', 'name': 'Test hattı'};
    final n = r.lines.length;
    expect(r.applyNetworkChanges({'added': [fresh], 'removed': []}), isTrue);
    expect(r.lines.length, n + 1);
    expect(r.newLineCodes, contains('M99'));
    expect(r.applyNetworkChanges({'added': [fresh]}), isFalse); // idempotent
    expect(r.applyNetworkChanges({'removed': ['M99']}), isTrue);
    expect(r.lineByCode.containsKey('M99'), isFalse);
    expect(r.lineByCode['M2'], same(m2));
    // the engine rebuilt on the changed network still runs trains
    expect(ScheduleEngine(r).trainsAt(morning, onlyLine: 'M2'), isNotEmpty);
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
