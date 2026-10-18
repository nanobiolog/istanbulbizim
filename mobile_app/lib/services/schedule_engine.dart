import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/network_models.dart';
import '../models/rail_models.dart';
import 'network_repository.dart';
import 'rail_engine.dart' show railPlainName;

enum MotionState { accelerating, cruising, braking, atStation }

extension MotionStateText on MotionState {
  String get label => switch (this) {
        MotionState.accelerating => 'Hızlanıyor',
        MotionState.cruising => 'Seyir halinde',
        MotionState.braking => 'Yavaşlıyor',
        MotionState.atStation => 'İstasyonda',
      };
}

/// One articulated carriage of a [ScheduledTrain] sampled along its curved [MeasuredPath].
class SampledTrainCar {
  final int index;
  final LatLng center;
  final LatLng rear;
  final LatLng front;
  final double heading;
  final double lengthM;
  final List<LatLng> spine;
  final bool isLead;
  final bool isTail;

  const SampledTrainCar({
    required this.index,
    required this.center,
    required this.rear,
    required this.front,
    required this.heading,
    required this.lengthM,
    required this.spine,
    required this.isLead,
    required this.isTail,
  });
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

  /// Distance in metres from the start of [variant.path] to the centre of the train.
  final double alongM;

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
    this.alongM = 0,
  });

  bool get atStation => state == MotionState.atStation;
  String get fromStationId => variant.stops[fromIdx].stationId;
  String get toStationId => variant.stops[toIdx].stationId;

  int get carCount {
    final c = line.code;
    if (c == 'B1') return 6;
    if (c == 'M6') return 2;
    if (c == 'T2' || c == 'T3' || c.startsWith('TF')) return 1;
    if (c.startsWith('T')) return 3;
    if (c.startsWith('F')) return 2;
    return 4;
  }

  double get carLengthM {
    final c = line.code;
    if (c == 'B1') return 22.5;
    if (c == 'T2' || c == 'T3') return 11.0;
    if (c.startsWith('TF')) return 6.0;
    if (c.startsWith('T') || c.startsWith('F')) return 15.5;
    return 21.5;
  }

  /// Full curved polyline of the train consist from rear tail to front nose along [variant.path].
  List<LatLng> curvedConsistSpine({double scale = 1.0}) {
    final pathLen = variant.path.length;
    if (pathLen <= 1) return [pos];
    final n = carCount;
    final cLen = carLengthM * scale;
    final gap = (n > 1 ? 3.4 : 0.0) * scale;
    final halfTotal = (n * cLen + (n - 1) * gap) * 0.5;
    final s0 = (alongM - halfTotal).clamp(0.0, pathLen);
    final s1 = (alongM + halfTotal).clamp(0.0, pathLen);
    if (s1 - s0 < 1.0) return [pos];
    return variant.path.slice(s0, s1);
  }

  /// Individual articulated carriages positioned and bogie-aligned along the curved [variant.path].
  List<SampledTrainCar> sampledCars({double scale = 1.0}) {
    final pathLen = variant.path.length;
    final n = carCount;
    final cLen = carLengthM * scale;
    final gap = (n > 1 ? 3.4 : 0.0) * scale;
    final pitch = cLen + gap;
    if (pathLen <= 1) {
      return [
        SampledTrainCar(
          index: 0,
          center: pos,
          rear: pos,
          front: pos,
          heading: heading,
          lengthM: cLen,
          spine: [pos],
          isLead: true,
          isTail: true,
        ),
      ];
    }
    final out = <SampledTrainCar>[];
    for (var k = 0; k < n; k++) {
      final offset = (k - (n - 1) / 2.0) * pitch;
      final sCenter = (alongM + offset).clamp(0.0, pathLen);
      final sRear = (sCenter - cLen * 0.46).clamp(0.0, pathLen);
      final sFront = (sCenter + cLen * 0.46).clamp(0.0, pathLen);
      final pRear = variant.path.rawPointAt(sRear);
      final pFront = variant.path.rawPointAt(sFront);
      final pCenter = variant.path.rawPointAt(sCenter);
      final h = (sFront - sRear > 0.4) ? bearingDeg(pRear, pFront) : heading;
      final carSpine = (sFront - sRear > 0.4) ? variant.path.slice(sRear, sFront) : <LatLng>[pRear, pFront];
      out.add(SampledTrainCar(
        index: k,
        center: pCenter,
        rear: pRear,
        front: pFront,
        heading: h,
        lengthM: math.max(4.0, sFront - sRear),
        spine: carSpine,
        isLead: k == n - 1,
        isTail: k == 0,
      ));
    }
    return out;
  }
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
  List<double> arr; // s from origin departure to arrival at stop i
  List<double> dep; // s from origin departure to departure from stop i
  List<int> departures; // origin departures, seconds of the service day (sorted)
  List<_Seg> segs;

  /// Stop range each departure actually runs (short-turns); null = the whole variant.
  List<int>? fromIdx, toIdx;
  _RailRun(this.line, this.v, this.direction, this.arr, this.dep, this.departures, this.segs);
  double get total => arr.last;
  int from(int k) => fromIdx?[k] ?? 0;
  int to(int k) => toIdx?[k] ?? v.stops.length - 1;
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

  /// Profile that covers [d] metres in exactly [t] seconds (official run times).
  factory _Seg.timed(double d, double t, double a, double b) {
    final k = 1 / (2 * a) + 1 / (2 * b);
    final disc = t * t - 4 * k * d;
    if (disc <= 0) {
      // too tight for the cruise phase: triangular profile scaled to the time
      final vp = 2 * d / math.max(1, t);
      return _Seg(d, vp, t * b / (a + b), t * b / (a + b), t, vp / (t * b / (a + b)), vp / (t * a / (a + b)));
    }
    final v = ((t - math.sqrt(disc)) / (2 * k)).clamp(2.0, 40.0);
    final t1 = v / a, cruise = math.max(0.0, (d - v * v / (2 * a) - v * v / (2 * b)) / v);
    return _Seg(d, v, t1, t1 + cruise, t1 + cruise + v / b, a, b);
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
  final bool cancelled; // the operator cancelled this sailing today
  final bool special; // from today's replacement timetable
  const PierDeparture(this.line, this.trip, this.stopIdx, this.at, {this.cancelled = false, this.special = false});
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

  final Set<String> _official = {};

  /// True when [line]'s trains run on the official Metro İstanbul timetable.
  bool isOfficial(String line) => _official.contains(line);

  /// Replaces the headway estimate of [s.line] with the official timetable (per-station offsets,
  /// trips incl. short-turns, dwell). Stations of the official list are matched to the network by
  /// position and name; stations missing from it are interpolated by distance.
  bool applyOfficial(RailSchedule s) {
    if (!s.official || s.stations.length < 2) return false;
    final runs = _runs.where((r) => r.line.code == s.line).toList();
    if (runs.isEmpty) return false;
    final n = s.stations.length;
    final plain = [for (final st in s.stations) railPlainName(st.name)];
    int? named(RailStop stop) {
      final ns = repo.stations[stop.stationId];
      final want = ns == null ? '' : railPlainName(ns.name);
      if (want.isEmpty) return null;
      int? best;
      var bd = 1500.0;
      for (var i = 0; i < n; i++) {
        if (!(plain[i] == want || plain[i].contains(want) || want.contains(plain[i]))) continue;
        final d = haversine(stop.pos.latitude, stop.pos.longitude, s.stations[i].lat, s.stations[i].lon);
        if (d < bd) {
          bd = d;
          best = i;
        }
      }
      return best;
    }

    /// Name matches win; proximity only fills stations without one and never takes a claimed slot.
    List<int?> matchAll(List<RailStop> stops) {
      final byName = [for (final st in stops) named(st)];
      final claimed = byName.whereType<int>().toSet();
      return [
        for (var k = 0; k < stops.length; k++)
          byName[k] ??
              (() {
                int? best;
                var bd = 350.0;
                for (var i = 0; i < n; i++) {
                  if (claimed.contains(i)) continue;
                  final d = haversine(stops[k].pos.latitude, stops[k].pos.longitude, s.stations[i].lat, s.stations[i].lon);
                  if (d < bd) {
                    bd = d;
                    best = i;
                  }
                }
                return best;
              })(),
      ];
    }

    // run -> (direction, travel position per stop or -1, first/last mapped stop, origin departures)
    final assigned = <_RailRun, (RailDirection, List<int>, int, int, List<int>)>{};
    for (final r in runs) {
      final raw = matchAll(r.v.stops);
      final mappedIdx = [for (var i = 0; i < raw.length; i++) if (raw[i] != null) i];
      if (mappedIdx.length < math.min(3, raw.length)) continue;
      for (final d in s.directions) {
        if (d.offsets.length != n) continue;
        // keep only mappings that advance strictly in travel order (drops mislocated stations)
        final pos = List<int>.filled(raw.length, -1);
        var last = -1;
        for (final i in mappedIdx) {
          final p = d.posOf(raw[i]!, n);
          if (p > last) {
            pos[i] = p;
            last = p;
          }
        }
        final kept = [for (var i = 0; i < pos.length; i++) if (pos[i] >= 0) i];
        if (kept.length < math.max(2, (mappedIdx.length * 0.6).ceil())) continue;
        assigned[r] = (d, pos, kept.first, kept.last, <int>[]);
        break;
      }
    }
    if (assigned.isEmpty) return false;
    // each official trip goes to the run it overlaps most; short-turns keep their stop range
    final ranges = <_RailRun, List<(int, int)>>{};
    for (final d in s.directions) {
      final mine = assigned.entries.where((e) => identical(e.value.$1, d)).toList();
      for (final trip in d.trips) {
        _RailRun? best;
        var bestOverlap = 0;
        for (final e in mine) {
          final p0 = e.value.$2[e.value.$3], p1 = e.value.$2[e.value.$4];
          final int overlap = math.min(p1, trip.to) - math.max(p0, trip.from);
          if (overlap > bestOverlap) {
            bestOverlap = overlap;
            best = e.key;
          }
        }
        if (best == null) continue;
        final (_, pos, first, last, deps) = assigned[best]!;
        // virtual departure at the first mapped stop (earlier than the trip start for short-turns)
        deps.add(trip.dep + d.offsets[pos[first]] - d.offsets[trip.from]);
        // first / last stop of the variant inside the trip
        var iFrom = 0, iTo = pos.length - 1;
        if (trip.from > pos[first]) {
          iFrom = pos.indexWhere((p) => p >= trip.from);
          if (iFrom < 0) iFrom = 0;
        }
        if (trip.to < pos[last]) {
          iTo = pos.lastIndexWhere((p) => p >= 0 && p <= trip.to);
          if (iTo <= iFrom) iTo = pos.length - 1;
        }
        ranges.putIfAbsent(best, () => []).add((iFrom, iTo));
      }
    }
    var applied = 0;
    final dwell = s.dwellSec.toDouble();
    for (final e in assigned.entries) {
      final r = e.key;
      final (d, pos, first, last, depsAtFirst) = e.value;
      if (depsAtFirst.isEmpty) continue;
      final m = pos.length;
      // departure offsets relative to the first mapped stop
      final off = List<double?>.filled(m, null);
      for (var i = first; i <= last; i++) {
        if (pos[i] >= 0) off[i] = (d.offsets[pos[i]] - d.offsets[pos[first]]).toDouble();
      }
      for (var i = first + 1; i < last; i++) {
        if (off[i] != null) continue;
        var b = i + 1;
        while (off[b] == null) {
          b++;
        }
        final a = i - 1;
        final da = r.v.stops[a].distM, db = r.v.stops[b].distM, di = r.v.stops[i].distM;
        off[i] = off[a]! + (off[b]! - off[a]!) * ((di - da) / math.max(1, db - da));
      }
      // stations beyond the official list (newer extensions): keep the estimated run times
      for (var i = last + 1; i < m; i++) {
        off[i] = off[i - 1]! + (r.dep[i] - r.dep[i - 1]);
      }
      for (var i = first - 1; i >= 0; i--) {
        off[i] = off[i + 1]! - (r.dep[i + 1] - r.dep[i]);
      }
      final shift = off[0]!;
      final depOff = [for (final o in off) o! - shift];
      final arr = <double>[0], dep = <double>[0], segs = <_Seg>[];
      var ok = true;
      for (var i = 1; i < m; i++) {
        final isLast = i == m - 1;
        final arrive = isLast ? depOff[i] : math.max(depOff[i - 1] + 20, depOff[i] - dwell);
        final run = arrive - dep[i - 1];
        if (run <= 5) {
          ok = false;
          break;
        }
        final dist = math.max(80.0, r.v.stops[i].distM - r.v.stops[i - 1].distM);
        segs.add(_Seg.timed(dist, run, r.line.mode.accel, r.line.mode.decel));
        arr.add(arrive);
        dep.add(isLast ? arrive : math.max(arrive, depOff[i]));
      }
      if (!ok) continue;
      final rg = ranges[r] ?? const <(int, int)>[];
      final order = List<int>.generate(depsAtFirst.length, (i) => i)..sort((a, b) => depsAtFirst[a].compareTo(depsAtFirst[b]));
      final full = rg.every((x) => x.$1 == 0 && x.$2 == m - 1);
      r
        ..arr = arr
        ..dep = dep
        ..segs = segs
        ..departures = [for (final i in order) (depsAtFirst[i] + shift).round()] // origin departures
        ..fromIdx = full ? null : [for (final i in order) i < rg.length ? rg[i].$1 : 0]
        ..toIdx = full ? null : [for (final i in order) i < rg.length ? rg[i].$2 : m - 1];
      applied++;
    }
    if (applied > 0) _official.add(s.line);
    return applied > 0;
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
      now.hour * 3600 + now.minute * 60 + now.second + now.millisecond / 1000.0 + now.microsecond / 1000000.0;

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
          final tau = t - deps[k];
          final a = r.from(k), b = r.to(k);
          if (tau < r.arr[a] - (a == 0 ? 0 : r.line.dwellS) || tau > r.arr[b] + (b == r.v.stops.length - 1 ? 0 : 20)) continue;
          final tr = _place(r, deps[k], tau);
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
      final alongAtStop = v.stops[i].distM;
      final (p, h) = v.path.pointAt(alongAtStop);
      final last = i == v.stops.length - 1;
      return ScheduledTrain(
        id: id, line: r.line, variant: v, pos: p, heading: h, speedKmh: 0, state: MotionState.atStation,
        fromIdx: i, toIdx: last ? i : i + 1, etaSec: last ? 0 : math.max(0, r.dep[i] - tau),
        distanceToNextM: 0, progress: tau / r.total, alongM: alongAtStop);
    }
    final seg = r.segs[i - 1];
    final (s, spd, st) = seg.at(tau - r.dep[prev]);
    final d0 = v.stops[prev].distM, d1 = v.stops[i].distM;
    final along = d0 + (d1 - d0) * (seg.d <= 0 ? 0 : s / seg.d);
    final (p, h) = v.path.pointAt(along);
    return ScheduledTrain(
      id: id, line: r.line, variant: v, pos: p, heading: h, speedKmh: spd * 3.6, state: st,
      fromIdx: prev, toIdx: i, etaSec: math.max(0, r.arr[i] - tau), distanceToNextM: math.max(0, d1 - along),
      progress: tau / r.total, segFrac: d1 > d0 ? ((along - d0) / (d1 - d0)).clamp(0.0, 1.0) : 0, alongM: along);
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
  List<DepartureEstimate> departuresAt(NetworkStation station, DateTime now) {
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
        for (var k = 0; k < r.departures.length; k++) {
          if (idx < r.from(k) || idx >= r.to(k)) continue;
          final at = r.departures[k] + base + r.dep[idx];
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
  Map<int, StationEvents> stationEvents(NetworkStation station, RailLine line, DateTime now) {
    final t0 = secondsOfDay(now);
    final out = <int, StationEvents>{};
    for (final r in _runs) {
      if (r.line.code != line.code) continue;
      final idx = r.v.indexOfStation(station.id);
      if (idx < 0) continue;
      final ev = out.putIfAbsent(r.direction, () => StationEvents(r.direction));
      for (final base in [-86400.0, 0.0, 86400.0]) {
        for (var k = 0; k < r.departures.length; k++) {
          if (idx < r.from(k) || idx > r.to(k)) continue;
          final terminal = idx == r.to(k);
          final d = r.departures[k];
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

  /// Today's operator notice (cancellations / replacement timetables). Null = none.
  FerryStatus? ferryStatus;

  /// Trips [line] really runs on [day]: replacement timetable, nothing (cancelled) or the normal one.
  (List<FerryTrip>, bool cancelled, bool special) tripsFor(FerryLine line, DateTime day) {
    final st = ferryStatus;
    if (st != null && st.appliesTo(day)) {
      final ov = st.overrides[line.id];
      if (ov != null && ov.isNotEmpty) return (ov, false, true);
      if (st.cancelledLineIds.contains(line.id)) return (line.trips, true, false);
    }
    return (line.trips, false, false);
  }

  bool lineCancelledToday(FerryLine line, DateTime now) => tripsFor(line, now).$2;

  MeasuredPath _leg(String a, String b) =>
      _legCache.putIfAbsent('$a|$b', () => MeasuredPath(repo.legPath(a, b)));

  List<FerryVessel> vesselsAt(DateTime now) {
    final out = <FerryVessel>[];
    final t = secondsOfDay(now);
    final today = now.weekday;
    final yesterday = today == 1 ? 7 : today - 1;
    for (final line in repo.ferryLines) {
      final op = repo.operators[line.operatorId];
      final (trips, cancelled, special) = tripsFor(line, now);
      if (cancelled) continue;
      for (final trip in trips) {
        for (final (wd, base) in [(today, 0.0), (yesterday, -86400.0)]) {
          if (!special && !trip.runsOn(wd)) continue;
          if (special && wd != today) continue;
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
      final (trips, cancelled, special) = tripsFor(line, now);
      for (final trip in trips) {
        if (!special && !trip.runsOn(now.weekday)) continue;
        for (var k = 0; k < trip.piers.length - 1; k++) {
          if (trip.piers[k] != pierId) continue;
          final s = trip.minutes[k] * 60.0;
          if (s >= t - 30) {
            out.add(PierDeparture(line, trip, k, midnight.add(Duration(seconds: s.round())), cancelled: cancelled, special: special));
          }
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
    final (trips, _, special) = tripsFor(line, day);
    for (final trip in trips) {
      if (!special && !trip.runsOn(day.weekday)) continue;
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
