import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/network_models.dart';
import 'network_repository.dart';

enum MotionState { accelerating, cruising, braking, atStation }

extension MotionStateText on MotionState {
  String get label => switch (this) {
        MotionState.accelerating => 'Hızlanıyor',
        MotionState.cruising => 'Seyir halinde',
        MotionState.braking => 'Yavaşlıyor',
        MotionState.atStation => 'İstasyonda',
      };
}

/// A train placed on the real track from the timetable (deterministic: same answer on every device).
class ScheduledTrain {
  final String id;
  final RailLine line;
  final RailVariant variant;
  final LatLng pos;
  final double heading;
  final double speedKmh;
  final MotionState state;
  final int fromIdx;
  final int toIdx;

  /// Seconds until arrival at [toIdx] (or until departure when at a station).
  final double etaSec;
  final double distanceToNextM;
  final double progress; // 0..1 along the whole run

  /// 0..1 between [fromIdx] and [toIdx] (0 while dwelling).
  final double segFrac;

  const ScheduledTrain({
    required this.id,
    required this.line,
    required this.variant,
    required this.pos,
    required this.heading,
    required this.speedKmh,
    required this.state,
    required this.fromIdx,
    required this.toIdx,
    required this.etaSec,
    required this.distanceToNextM,
    required this.progress,
    this.segFrac = 0,
  });

  bool get atStation => state == MotionState.atStation;
  String get fromStationId => variant.stops[fromIdx].stationId;
  String get toStationId => variant.stops[toIdx].stationId;
}

class DepartureEstimate {
  final RailLine line;
  final String towards;
  final int direction; // +1 / -1 relative to the line's main variant
  final DateTime at;
  final DateTime? then;
  const DepartureEstimate(this.line, this.towards, this.direction, this.at, this.then);
}

class StationEvents {
  final int direction;
  double? lastDeparture; // seconds of the day
  double? nextArrival;
  double? nextDeparture;
  StationEvents(this.direction);

  /// Offset of the train relative to its stopping point and whether doors are open.
  /// null = no train within sight.
  (double, bool)? trainOffset(RailLine line, double t) {
    if (nextArrival != null && nextDeparture != null) {
      if (t >= nextArrival! && t < nextDeparture!) return (0, true);
      if (t < nextArrival!) {
        final toArr = nextArrival! - t;
        final sinceDep = lastDeparture == null ? 1e9 : t - lastDeparture!;
        // a departing train is still more visible than the next approaching one
        if (sinceDep < 40 && sinceDep < toArr) return (_leave(line, sinceDep), false);
        if (toArr < 70) return (_approach(line, toArr), false);
      }
    }
    if (lastDeparture != null && t - lastDeparture! < 40) return (_leave(line, t - lastDeparture!), false);
    return null;
  }

  static double _approach(RailLine line, double toArrival) {
    final vmax = line.speedKmh / 3.6, b = line.mode.decel;
    final tb = vmax / b;
    if (toArrival <= tb) return -0.5 * b * toArrival * toArrival;
    return -(0.5 * b * tb * tb + vmax * (toArrival - tb));
  }

  static double _leave(RailLine line, double since) {
    final vmax = line.speedKmh / 3.6, a = line.mode.accel;
    final ta = vmax / a;
    if (since <= ta) return 0.5 * a * since * since;
    return 0.5 * a * ta * ta + vmax * (since - ta);
  }
}

class _RailRun {
  final RailLine line;
  final RailVariant v;
  final int direction;
  final List<double> arr; // s from origin departure to arrival at stop i
  final List<double> dep; // s from origin departure to departure from stop i
  final List<int> departures; // origin departures, seconds of the service day
  final List<_Seg> segs;
  _RailRun(this.line, this.v, this.direction, this.arr, this.dep, this.departures, this.segs);
  double get total => arr.last;
}

class _Seg {
  final double d, vp, t1, t2, tt, a, b;
  const _Seg(this.d, this.vp, this.t1, this.t2, this.tt, this.a, this.b);

  /// Trapezoidal / triangular speed profile.
  factory _Seg.of(double d, double vmax, double a, double b) {
    final dAcc = vmax * vmax / (2 * a), dDec = vmax * vmax / (2 * b);
    if (d >= dAcc + dDec) {
      final t1 = vmax / a;
      final cruise = (d - dAcc - dDec) / vmax;
      return _Seg(d, vmax, t1, t1 + cruise, t1 + cruise + vmax / b, a, b);
    }
    final vp = math.sqrt(2 * d * a * b / (a + b));
    final t1 = vp / a;
    return _Seg(d, vp, t1, t1, t1 + vp / b, a, b);
  }

  (double, double, MotionState) at(double tau) {
    if (tau <= 0) return (0, 0, MotionState.accelerating);
    if (tau < t1) return (0.5 * a * tau * tau, a * tau, MotionState.accelerating);
    final s1 = 0.5 * a * t1 * t1;
    if (tau < t2) return (s1 + vp * (tau - t1), vp, MotionState.cruising);
    if (tau < tt) {
      final r = tt - tau;
      return (d - 0.5 * b * r * r, b * r, MotionState.braking);
    }
    return (d, 0, MotionState.braking);
  }
}

class FerryVessel {
  final String id;
  final FerryLine line;
  final FerryOperator? op;
  final FerryTrip trip;
  final LatLng pos;
  final double heading;
  final bool docked;
  final int fromIdx;
  final int toIdx;
  final double etaSec;
  final double speedKn;
  const FerryVessel(this.id, this.line, this.op, this.trip, this.pos, this.heading, this.docked, this.fromIdx,
      this.toIdx, this.etaSec, this.speedKn);
}

class PierDeparture {
  final FerryLine line;
  final FerryTrip trip;
  final int stopIdx;
  final DateTime at;
  const PierDeparture(this.line, this.trip, this.stopIdx, this.at);
  String get destination => trip.piers.last;
}

class ScheduleEngine {
  final NetworkRepository repo;
  final List<_RailRun> _runs = [];
  final Map<String, MeasuredPath> _legCache = {};

  ScheduleEngine(this.repo) {
    for (final line in repo.lines) {
      final main = line.variants.first;
      final mainOrder = {for (var i = 0; i < main.stops.length; i++) main.stops[i].stationId: i};
      final vmax = line.speedKmh / 3.6;
      for (var vi = 0; vi < line.variants.length; vi++) {
        final v = line.variants[vi];
        // direction relative to the main variant
        var dir = 1;
        final common = v.stops.where((s) => mainOrder.containsKey(s.stationId)).toList();
        if (common.length >= 2 && mainOrder[common.first.stationId]! > mainOrder[common.last.stationId]!) dir = -1;
        final arr = <double>[0], dep = <double>[0], segs = <_Seg>[];
        for (var i = 1; i < v.stops.length; i++) {
          final d = math.max(80.0, v.stops[i].distM - v.stops[i - 1].distM);
          final seg = _Seg.of(d, vmax, line.mode.accel, line.mode.decel);
          segs.add(seg);
          arr.add(dep[i - 1] + seg.tt);
          dep.add(arr[i] + (i == v.stops.length - 1 ? 0 : line.dwellS));
        }
        // Short-turn / branch variants run interleaved with the main service.
        final shortTurn = vi >= 2;
        _runs.add(_RailRun(line, v, dir, arr, dep, _departures(line.headways, shortTurn), segs));
      }
    }
  }

  static List<int> _departures(List<Headway> bands, bool halfOffset) {
    final out = <int>[];
    if (bands.isEmpty) return out;
    var t = bands.first.startMin * 60 + (halfOffset ? bands.first.seconds ~/ 2 : 0);
    for (final b in bands) {
      t = math.max(t, b.startMin * 60 + (halfOffset ? b.seconds ~/ 2 : 0));
      while (t < b.endMin * 60) {
        out.add(t);
        t += b.seconds;
      }
    }
    return out;
  }

  static double secondsOfDay(DateTime now) =>
      now.hour * 3600 + now.minute * 60 + now.second + now.millisecond / 1000.0;

  // ───────────── rail ─────────────

  List<ScheduledTrain> trainsAt(DateTime now, {String? onlyLine}) {
    final out = <ScheduledTrain>[];
    final t0 = secondsOfDay(now);
    for (final r in _runs) {
      if (onlyLine != null && r.line.code != onlyLine) continue;
      for (final t in <double>[t0, t0 + 86400]) {
        // binary search the first departure that may still be running
        final deps = r.departures;
        var lo = 0, hi = deps.length;
        final earliest = t - r.total;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (deps[mid] < earliest) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        for (var k = lo; k < deps.length && deps[k] <= t; k++) {
          final tr = _place(r, deps[k], t - deps[k]);
          if (tr != null) out.add(tr);
        }
      }
    }
    return out;
  }

  ScheduledTrain? _place(_RailRun r, int depSec, double tau) {
    final v = r.v;
    if (tau < 0 || tau > r.total) return null;
    var i = 0;
    while (i < v.stops.length - 1 && r.dep[i] <= tau) {
      i++;
    }
    // The train has left stop i-1 and has not yet left stop i: it is between them or dwelling at i.
    final id = '${r.line.code}-${v.id}-$depSec';
    if (i == 0) i = 1;
    final prev = i - 1;
    if (tau >= r.arr[i]) {
      final (p, h) = v.path.pointAt(v.stops[i].distM);
      final last = i == v.stops.length - 1;
      return ScheduledTrain(
        id: id, line: r.line, variant: v, pos: p, heading: h, speedKmh: 0, state: MotionState.atStation,
        fromIdx: i, toIdx: last ? i : i + 1, etaSec: last ? 0 : math.max(0, r.dep[i] - tau),
        distanceToNextM: 0, progress: tau / r.total);
    }
    final seg = r.segs[i - 1];
    final (s, spd, st) = seg.at(tau - r.dep[prev]);
    final d0 = v.stops[prev].distM, d1 = v.stops[i].distM;
    final along = d0 + (d1 - d0) * (seg.d <= 0 ? 0 : s / seg.d);
    final (p, h) = v.path.pointAt(along);
    return ScheduledTrain(
      id: id, line: r.line, variant: v, pos: p, heading: h, speedKmh: spd * 3.6, state: st,
      fromIdx: prev, toIdx: i, etaSec: math.max(0, r.arr[i] - tau), distanceToNextM: math.max(0, d1 - along),
      progress: tau / r.total, segFrac: d1 > d0 ? ((along - d0) / (d1 - d0)).clamp(0.0, 1.0) : 0);
  }

  /// Re-find a train by id at a new time (keeps a selection alive while it moves).
  ScheduledTrain? trainById(String id, DateTime now) {
    final parts = id.split('-');
    if (parts.length < 3) return null;
    final code = parts.sublist(0, parts.length - 2).join('-');
    for (final t in trainsAt(now, onlyLine: code)) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Next two departures from [station] per line and direction.
  List<DepartureEstimate> departuresAt(RailStation station, DateTime now) {
    final t0 = secondsOfDay(now);
    final best = <String, List<double>>{};
    final meta = <String, (RailLine, String, int)>{};
    for (final r in _runs) {
      final idx = r.v.indexOfStation(station.id);
      if (idx < 0 || idx == r.v.stops.length - 1) continue;
      final main = r.line.variants.first;
      final towards = r.direction == 1 ? main.to : main.from;
      final key = '${r.line.code}|${r.direction}';
      meta[key] = (r.line, towards, r.direction);
      final list = best.putIfAbsent(key, () => []);
      for (final base in [0.0, 86400.0]) {
        for (final d in r.departures) {
          final at = d + base + r.dep[idx];
          if (at >= t0 - 5 && at < t0 + 4 * 3600) list.add(at);
        }
      }
    }
    final out = <DepartureEstimate>[];
    final midnight = DateTime(now.year, now.month, now.day);
    best.forEach((k, list) {
      if (list.isEmpty) return;
      list.sort();
      final m = meta[k]!;
      DateTime toDate(double s) => midnight.add(Duration(milliseconds: (s * 1000).round()));
      out.add(DepartureEstimate(m.$1, m.$2, m.$3, toDate(list[0]), list.length > 1 ? toDate(list[1]) : null));
    });
    out.sort((a, b) {
      final c = a.line.code.compareTo(b.line.code);
      return c != 0 ? c : -a.direction.compareTo(b.direction);
    });
    return out;
  }

  /// Last and next scheduled departure of [line] from [station] in each direction
  /// (seconds of the day). Drives the trains in the 3D station views.
  Map<int, StationEvents> stationEvents(RailStation station, RailLine line, DateTime now) {
    final t0 = secondsOfDay(now);
    final out = <int, StationEvents>{};
    for (final r in _runs) {
      if (r.line.code != line.code) continue;
      final idx = r.v.indexOfStation(station.id);
      if (idx < 0) continue;
      final ev = out.putIfAbsent(r.direction, () => StationEvents(r.direction));
      final terminal = idx == r.v.stops.length - 1;
      for (final base in [-86400.0, 0.0, 86400.0]) {
        for (final d in r.departures) {
          final arr = d + base + r.arr[idx];
          final dep = d + base + (terminal ? r.arr[idx] + line.dwellS : r.dep[idx]);
          if (dep <= t0 && (ev.lastDeparture == null || dep > ev.lastDeparture!)) ev.lastDeparture = dep;
          if (dep > t0 && (ev.nextDeparture == null || dep < ev.nextDeparture!)) {
            ev.nextDeparture = dep;
            ev.nextArrival = arr;
          }
        }
      }
    }
    return out;
  }

  // ───────────── ferries ─────────────

  MeasuredPath _leg(String a, String b) =>
      _legCache.putIfAbsent('$a|$b', () => MeasuredPath(repo.legPath(a, b)));

  List<FerryVessel> vesselsAt(DateTime now) {
    final out = <FerryVessel>[];
    final t = secondsOfDay(now);
    final today = now.weekday;
    final yesterday = today == 1 ? 7 : today - 1;
    for (final line in repo.ferryLines) {
      final op = repo.operators[line.operatorId];
      for (final trip in line.trips) {
        for (final (wd, base) in [(today, 0.0), (yesterday, -86400.0)]) {
          if (!trip.runsOn(wd)) continue;
          final first = trip.minutes.first * 60.0 + base, last = trip.minutes.last * 60.0 + base;
          if (t < first - 240 || t > last) continue;
          final v = _placeVessel(line, op, trip, t - base, '${line.id}-${trip.minutes.first}-$wd');
          if (v != null) out.add(v);
        }
      }
    }
    return out;
  }

  FerryVessel? _placeVessel(FerryLine line, FerryOperator? op, FerryTrip trip, double t, String id) {
    final m = trip.minutes;
    if (t < m.first * 60.0) {
      final p = repo.piers[trip.piers.first];
      if (p == null) return null;
      final next = trip.piers.length > 1 ? repo.piers[trip.piers[1]] : null;
      return FerryVessel(id, line, op, trip, p.pos, next == null ? 0 : bearingDeg(p.pos, next.pos), true, 0, 0,
          m.first * 60.0 - t, 0);
    }
    for (var k = 0; k < m.length - 1; k++) {
      final depK = m[k] * 60.0;
      final isLast = k + 1 == m.length - 1;
      final nextDep = m[k + 1] * 60.0;
      final arrive = isLast ? nextDep : math.max(depK + 60, nextDep - 60);
      if (t < depK || t > nextDep) continue;
      if (t >= arrive) {
        final p = repo.piers[trip.piers[k + 1]];
        if (p == null) return null;
        return FerryVessel(id, line, op, trip, p.pos, 0, true, k + 1, k + 1, nextDep - t, 0);
      }
      final path = _leg(trip.piers[k], trip.piers[k + 1]);
      if (path.points.length < 2) return null;
      final f = ((t - depK) / (arrive - depK)).clamp(0.0, 1.0);
      final eased = f * f * (3 - 2 * f) * 0.35 + f * 0.65; // gentle departure / berthing
      final (p, h) = path.pointAt(path.length * eased);
      final kn = path.length / math.max(60, arrive - depK) * 1.94384;
      return FerryVessel(id, line, op, trip, p, h, false, k, k + 1, arrive - t, kn);
    }
    return null;
  }

  FerryVessel? vesselById(String id, DateTime now) {
    for (final v in vesselsAt(now)) {
      if (v.id == id) return v;
    }
    return null;
  }

  List<PierDeparture> pierDepartures(String pierId, DateTime now, {int limit = 12}) {
    final out = <PierDeparture>[];
    final t = secondsOfDay(now);
    final midnight = DateTime(now.year, now.month, now.day);
    for (final line in repo.ferryLines) {
      if (!line.piers.contains(pierId)) continue;
      for (final trip in line.trips) {
        if (!trip.runsOn(now.weekday)) continue;
        for (var k = 0; k < trip.piers.length - 1; k++) {
          if (trip.piers[k] != pierId) continue;
          final s = trip.minutes[k] * 60.0;
          if (s >= t - 30) out.add(PierDeparture(line, trip, k, midnight.add(Duration(seconds: s.round()))));
        }
      }
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    // Two published routes can describe the same sailing (same operator, time and destination).
    final seen = <String>{};
    final uniq = out.where((d) => seen.add('${d.line.operatorId}|${d.at.millisecondsSinceEpoch}|${d.destination}')).toList();
    return uniq.take(limit).toList();
  }

  /// Full-day timetable at a pier for one line (for the timetable view).
  List<(DateTime, FerryTrip, int)> lineTimetableAt(FerryLine line, String pierId, DateTime day) {
    final midnight = DateTime(day.year, day.month, day.day);
    final out = <(DateTime, FerryTrip, int)>[];
    for (final trip in line.trips) {
      if (!trip.runsOn(day.weekday)) continue;
      for (var k = 0; k < trip.piers.length - 1; k++) {
        if (trip.piers[k] == pierId) out.add((midnight.add(Duration(minutes: trip.minutes[k])), trip, k));
      }
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }
}

String formatCountdown(Duration d) {
  final s = d.inSeconds;
  if (s <= 0) return 'şimdi';
  if (s < 60) return '$s sn';
  final m = (s / 60).floor();
  if (m < 60) return '$m dk';
  return '${m ~/ 60} sa ${m % 60} dk';
}

String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
