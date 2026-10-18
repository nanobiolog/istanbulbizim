import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/models/rail_models.dart';
import 'package:mobile_app/services/rail_engine.dart';
import 'package:mobile_app/services/rail_schedule_service.dart';

List<RailStation> _stations(String line) {
  final j = jsonDecode(File('assets/data/metro_stations.json').readAsStringSync()) as Map<String, dynamic>;
  return (j[line] as List)
      .map((e) => RailStation(name: e['name'] as String, lat: (e['lat'] as num).toDouble(), lon: (e['lon'] as num).toDouble()))
      .toList();
}

void main() {
  test('service day rolls over at 03:00 Istanbul time regardless of device zone', () {
    // 2026-10-17 (Saturday) 01:30 Istanbul == 2026-10-16 22:30 UTC → still Friday's service day.
    final night = railServiceDay(DateTime.utc(2026, 10, 16, 22, 30));
    expect(night.dateKey, '2026-10-16');
    expect(night.dayType, 'I');
    expect(night.nowSec, 86400 + 3600 + 1800);

    final morning = railServiceDay(DateTime.utc(2026, 10, 17, 5, 0)); // 08:00 Istanbul
    expect(morning.dateKey, '2026-10-17');
    expect(morning.dayType, 'C');
    expect(morning.nowSec, 8 * 3600);
    expect(morning.at(8 * 3600), DateTime.utc(2026, 10, 17, 5, 0));
  });

  test('timetable clock parsing keeps after-midnight trains on the same service day', () {
    expect(railTimeToSec('06:05'), 6 * 3600 + 300);
    expect(railTimeToSec('00:15'), 86400 + 900);
    expect(railTimeToSec('x'), isNull);
  });

  test('running offsets are recovered from minute-rounded official timetables', () {
    final st = _stations('M2');
    final prof = railProfile('M2');
    final prior = railPriorOffsets(st, prof);
    final rnd = math.Random(3);
    // "True" profile deliberately 20 % slower than the prior plus per-station noise.
    final truth = <double>[0];
    for (var i = 1; i < st.length; i++) {
      truth.add(truth.last + (prior[i] - prior[i - 1]) * 1.2 + rnd.nextDouble() * 20);
    }
    final origin = <int>[];
    for (var t = 6 * 3600; t <= 24 * 3600; t += (t >= 7 * 3600 && t < 9 * 3600) ? 240 : 420) {
      origin.add(t);
    }
    int pub(num x) => (x ~/ 60) * 60;
    final samples = <int, List<int>>{0: origin.map(pub).toList()};
    for (var p = 2; p < st.length - 1; p += 2) {
      samples[p] = origin.map((o) => pub(o + truth[p])).toList();
    }
    final r = railDeriveOffsets(prior, 0, samples);
    expect(r.matched, samples.length - 1);
    for (var p = 1; p < st.length - 1; p++) {
      for (final o in origin.take(40)) {
        expect((pub(o) + r.offsets[p] - pub(o + truth[p])).abs(), lessThanOrEqualTo(90), reason: 'station $p');
      }
    }
  });

  test('trapezoidal run covers the full distance continuously', () {
    const total = 120.0, dist = 1500.0;
    var prev = 0.0;
    for (var t = 0.0; t <= total; t += 0.5) {
      final k = railKinematics(t, total, dist, 0.89, 1.04);
      expect(k.s, greaterThanOrEqualTo(prev - 1e-6));
      prev = k.s;
    }
    expect(railKinematics(total, total, dist, 0.89, 1.04).s, closeTo(dist, 1e-6));
    expect(railKinematics(total / 2, total, dist, 0.89, 1.04).a, 0);
  });

  test('trains sit at the platform until the official departure and then move', () {
    final st = _stations('M2');
    final day = railServiceDay(DateTime.utc(2026, 10, 19, 6, 0)); // Monday 09:00
    final offsets = railPriorOffsets(st, railProfile('M2')).map((e) => e.round()).toList();
    final dep = 9 * 3600 + 60;
    final sched = RailSchedule(
      line: 'M2',
      serviceDate: day.dateKey,
      dayType: day.dayType,
      official: true,
      source: 'test',
      stations: st,
      dwellSec: 25,
      directions: [
        RailDirection(dir: 'G', forward: true, name: 'x', headsign: st.last.name, offsets: offsets, trips: [RailTrip(dep, 0, st.length - 1)]),
      ],
    );
    final dwell = RailServiceDay(day.dateKey, day.dow, day.dayType, dep - 10, day.midnightUtc);
    final atPlatform = railPositions(sched, dwell).single;
    expect(atPlatform.state, 'AT_STATION');
    expect(atPlatform.prevIndex, 0);
    expect(atPlatform.etaSec, closeTo(10, 0.01));

    final moving = railPositions(sched, RailServiceDay(day.dateKey, day.dow, day.dayType, dep + 5, day.midnightUtc)).single;
    expect(moving.state, 'ACCELERATING');
    expect(moving.nextIndex, 1);
    expect(moving.progress, greaterThan(0));
    expect(moving.upcoming.first.name, st[1].name);
    expect(moving.upcoming.first.at, day.at(dep + offsets[1] - 25));

    final gone = railPositions(sched, RailServiceDay(day.dateKey, day.dow, day.dayType, dep + offsets.last + 5, day.midnightUtc));
    expect(gone, isEmpty);

    final deps = railDeparturesAt(sched, 4, RailServiceDay(day.dateKey, day.dow, day.dayType, dep, day.midnightUtc));
    expect(deps.single.at, day.at(dep + offsets[4]));
    expect(deps.single.headsign, st.last.name);
  });

  test('reverse direction maps travel positions back to station indexes', () {
    final st = _stations('M4');
    final day = railServiceDay(DateTime.utc(2026, 10, 19, 9, 0));
    final sched = buildEstimatedSchedule('M4', st, day);
    final rev = sched.directions.firstWhere((d) => !d.forward);
    expect(rev.headsign, st.first.name);
    final trains = railPositions(sched, day).where((t) => t.dir == 'D').toList();
    expect(trains, isNotEmpty);
    for (final t in trains) {
      expect(t.state == 'AT_STATION' || t.nextIndex == t.prevIndex - 1, isTrue);
    }
  });

  test('Marmaray plan matches the Worker (108 min, 15 min headway, Ataköy–Pendik short-turns)', () {
    final st = _stations('B1');
    final sat = railServiceDay(DateTime.utc(2026, 10, 17, 9, 0));
    final s = buildMarmaraySchedule(st, sat);
    final g = s.directions.firstWhere((d) => d.dir == 'G');
    final d = s.directions.firstWhere((d) => d.dir == 'D');
    expect(g.offsets.last, 108 * 60);
    // Same counts as the Worker harness for a Saturday (night extension on).
    expect(g.trips.length, 138);
    expect(d.trips.length, 132);
    final shortTrip = g.trips.firstWhere((t) => t.from != 0);
    expect(st[shortTrip.from].name, 'ATAKOY');
    expect(st[shortTrip.to].name, 'PENDIK');
    expect(s.official, isFalse);

    final tue = railServiceDay(DateTime.utc(2026, 10, 20, 9, 0));
    expect(buildMarmaraySchedule(st, tue).directions.first.trips.length, 69 + 64);
  });

  test('schedule JSON round-trips', () {
    final st = _stations('T1');
    final day = railServiceDay(DateTime.utc(2026, 10, 19, 9, 0));
    final s = buildEstimatedSchedule('T1', st, day);
    final back = RailSchedule.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(back.directions.length, 2);
    expect(back.directions.first.trips.length, s.directions.first.trips.length);
    expect(back.directions.last.forward, isFalse);
    expect(railPositions(back, day).length, railPositions(s, day).length);
  });

  test('Metro İstanbul payload helpers', () {
    final times = RailScheduleService.timesFrom({
      'TimeInfos': {'Day': 1, 'DayName': 'Pazartesi', 'Times': ['06:00', '06:04', '00:10', 'bad']}
    });
    expect(times, [21600, 21840, 87000]);
    expect(RailScheduleService.splitEnds('Yenikapı->Hacıosman'), ['Yenikapı', 'Hacıosman']);
    expect(RailScheduleService.splitEnds('Kabataş - Bağcılar'), ['Kabataş', 'Bağcılar']);
    expect(railFindStation(_stations('M2'), 'Şişli-Mecidiyeköy'), 6);
    expect(railFindStation(_stations('M2'), 'İTÜ-Ayazağa'), 12);
    expect(railLineFromText('M2 Yenikapı-Hacıosman'), 'M2');
    expect(railLineFromText('Saat 10:00 itibarıyla'), '');
    expect(railLineFromText('Marmaray seferleri'), 'B1');
  });
}
