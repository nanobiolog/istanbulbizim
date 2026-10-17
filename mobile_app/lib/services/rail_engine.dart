import 'dart:math' as math;

import '../models/rail_models.dart';

/// Pure timetable math shared by the live map, the station view, the 3D view and AR.
/// Mirrors `src/rail.js` in the Worker so a schedule built on either side places trains identically.
class RailProfile {
  final double dwell; // s at each station
  final double loss; // s lost per stop to accel/brake vs cruise (prior only)
  final double cruiseKmh;
  final double accel; // m/s²
  final double decel; // m/s²
  final String systemType;
  final String specText;

  const RailProfile({
    required this.dwell,
    required this.loss,
    required this.cruiseKmh,
    required this.accel,
    required this.decel,
    required this.systemType,
    required this.specText,
  });
}

RailProfile railProfile(String code) {
  final c = code.toUpperCase();
  if (c == 'B1' || c == 'MARMARAY') {
    return const RailProfile(
        dwell: 45, loss: 30, cruiseKmh: 80, accel: 0.95, decel: 1.05,
        systemType: 'Marmaray Banliyö Treni (TCDD)', specText: 'TCDD E32000 EMU (Hızlanma 0,9-1,0 • Fren 1,0-1,1 m/s²)');
  }
  if (c.startsWith('TF')) {
    return const RailProfile(
        dwell: 40, loss: 0, cruiseKmh: 18, accel: 0.75, decel: 0.85,
        systemType: 'Teleferik', specText: 'Kablolu sistem (Hızlanma 0,7-0,8 • Fren 0,8-0,9 m/s²)');
  }
  if (c.startsWith('F')) {
    return const RailProfile(
        dwell: 40, loss: 0, cruiseKmh: 25, accel: 0.75, decel: 0.85,
        systemType: 'Füniküler', specText: 'Kablolu sistem (Hızlanma 0,7-0,8 • Fren 0,8-0,9 m/s²)');
  }
  if (c.startsWith('T')) {
    return const RailProfile(
        dwell: 20, loss: 15, cruiseKmh: 30, accel: 1.1, decel: 1.2,
        systemType: 'Tramvay', specText: 'Tramvay (Hızlanma 1,0-1,2 • Fren 1,1-1,3 m/s²)');
  }
  if (c == 'M5' || c == 'M8' || c == 'M11') {
    return const RailProfile(
        dwell: 25, loss: 25, cruiseKmh: 62, accel: 1.05, decel: 1.15,
        systemType: 'Sürücüsüz Metro', specText: 'Sürücüsüz (Hızlanma 1,0-1,1 • Fren 1,1-1,2 m/s²)');
  }
  if (c.startsWith('M1')) {
    return const RailProfile(
        dwell: 25, loss: 22, cruiseKmh: 50, accel: 1.1, decel: 1.2,
        systemType: 'Hafif Metro', specText: 'Hafif Metro (Hızlanma 1,0-1,2 • Fren 1,1-1,3 m/s²)');
  }
  return const RailProfile(
      dwell: 25, loss: 25, cruiseKmh: 58, accel: 0.89, decel: 1.04,
      systemType: 'Standart Metro', specText: 'Standart Metro (Ort. Hızlanma 0,89 • Ort. Fren 1,04 m/s²)');
}

/// Istanbul has been UTC+3 all year since 2016; never trust the device time zone for timetables.
const Duration istanbulOffset = Duration(hours: 3);
const int railServiceDayStartHour = 3;

class RailServiceDay {
  final String dateKey;
  final int dow; // 0 = Sunday … 6 = Saturday (matches the Worker)
  final String dayType; // I | C | P
  final int nowSec; // seconds since the service day's midnight (can exceed 86400)
  final DateTime midnightUtc; // the service day's 00:00 Istanbul, as an absolute instant

  const RailServiceDay(this.dateKey, this.dow, this.dayType, this.nowSec, this.midnightUtc);

  DateTime at(num sec) => midnightUtc.add(Duration(milliseconds: (sec * 1000).round()));
}

RailServiceDay railServiceDay(DateTime now) {
  final local = now.toUtc().add(istanbulOffset);
  final secOfDay = local.hour * 3600 + local.minute * 60 + local.second;
  final rolled = local.hour < railServiceDayStartHour;
  final svc = rolled ? local.subtract(const Duration(days: 1)) : local;
  final dow = svc.weekday % 7;
  final midnightLocal = DateTime.utc(svc.year, svc.month, svc.day);
  final key = '${svc.year.toString().padLeft(4, '0')}-${svc.month.toString().padLeft(2, '0')}-${svc.day.toString().padLeft(2, '0')}';
  return RailServiceDay(
    key,
    dow,
    dow == 0 ? 'P' : (dow == 6 ? 'C' : 'I'),
    rolled ? secOfDay + 86400 : secOfDay,
    midnightLocal.subtract(istanbulOffset),
  );
}

/// "HH:MM" → seconds of the service day (00:00-02:59 belong to the end of the day).
int? railTimeToSec(String hhmm) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(hhmm.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  var s = h * 3600 + int.parse(m.group(2)!) * 60;
  if (h < railServiceDayStartHour) s += 86400;
  return s;
}

/// Istanbul wall-clock "HH:MM" for an absolute instant.
String istanbulClock(DateTime t, {bool seconds = false}) {
  final l = t.toUtc().add(istanbulOffset);
  final hm = '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  return seconds ? '$hm:${l.second.toString().padLeft(2, '0')}' : hm;
}

double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = p2 - p1, dl = (lon2 - lon1) * math.pi / 180;
  final h = math.pow(math.sin(dp / 2), 2) + math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.asin(math.sqrt(h.toDouble()));
}

double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dl = (lon2 - lon1) * math.pi / 180;
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Prior cumulative departure offsets (s) along [order] (travel order).
List<double> railPriorOffsets(List<RailStation> order, RailProfile prof) {
  final out = <double>[0];
  for (var i = 1; i < order.length; i++) {
    final d = haversineM(order[i - 1].lat, order[i - 1].lon, order[i].lat, order[i].lon);
    out.add(out[i - 1] + prof.dwell + prof.loss + d / (prof.cruiseKmh / 3.6));
  }
  return out;
}

double _median(List<num> a) {
  if (a.isEmpty) return 0;
  final s = a.map((e) => e.toDouble()).toList()..sort();
  final m = s.length >> 1;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

/// See `railMatchOffset` in the Worker: densest 60 s window of (station − origin) votes near [guess].
double? railMatchOffset(List<int> origin, List<int> station, double guess, double win) {
  if (origin.isEmpty || station.isEmpty) return null;
  final votes = <int>[];
  var j = 0;
  for (final o in origin) {
    final lo = o + guess - win, hi = o + guess + win;
    while (j < station.length && station[j] < lo) {
      j++;
    }
    for (var k = j; k < station.length && station[k] <= hi; k++) {
      votes.add(station[k] - o);
    }
  }
  if (votes.length < 3) return null;
  votes.sort();
  var best = 0, bestLo = 0, hiIdx = 0;
  for (var lo = 0; lo < votes.length; lo++) {
    while (hiIdx < votes.length && votes[hiIdx] - votes[lo] <= 60) {
      hiIdx++;
    }
    if (hiIdx - lo > best) {
      best = hiIdx - lo;
      bestLo = lo;
    }
  }
  final support = best / math.min(origin.length, station.length);
  if (support < 0.35) return null;
  return _median(votes.sublist(bestLo, bestLo + best));
}

/// Chained anchors from timetable samples, interpolated on the prior time scale.
({List<int> offsets, int matched}) railDeriveOffsets(List<double> prior, int originPos, Map<int, List<int>> samples) {
  final n = prior.length;
  final anchors = <List<double>>[
    [originPos.toDouble(), 0]
  ];
  final positions = samples.keys.where((p) => p > originPos).toList()..sort();
  var matched = 0;
  final origin = samples[originPos] ?? const <int>[];
  for (final p in positions) {
    final ap = anchors.last[0].toInt();
    final ao = anchors.last[1];
    final guess = ao + (prior[p] - prior[ap]);
    final win = math.max(150.0, math.min(420.0, (prior[p] - prior[ap]) * 0.35 + 120));
    final off = railMatchOffset(origin, samples[p]!, guess, win);
    if (off != null && off > ao) {
      anchors.add([p.toDouble(), off]);
      matched++;
    }
  }
  final offsets = List<double>.filled(n, 0);
  for (var p = 0; p < n; p++) {
    List<double>? a, b;
    for (final an in anchors) {
      if (an[0] <= p) a = an;
      if (an[0] >= p && b == null) b = an;
    }
    if (a != null && b != null && b[0] != a[0]) {
      final span = prior[b[0].toInt()] - prior[a[0].toInt()];
      final f = span > 0 ? (prior[p] - prior[a[0].toInt()]) / span : 0.0;
      offsets[p] = a[1] + (b[1] - a[1]) * f;
    } else if (a != null) {
      offsets[p] = a[1] + (prior[p] - prior[a[0].toInt()]);
    } else {
      offsets[p] = b![1] - (prior[b[0].toInt()] - prior[p]);
    }
  }
  for (var p = 1; p < n; p++) {
    if (offsets[p] <= offsets[p - 1]) offsets[p] = offsets[p - 1] + 30;
  }
  return (offsets: offsets.map((x) => x.round()).toList(), matched: matched);
}

/// Normalises Turkish station names for matching ("Şişli-Mecidiyeköy" == "SISLI-MECIDIYEKOY").
String railPlainName(String s) {
  var u = s.toUpperCase();
  const map = {
    'İ': 'I', 'I': 'I', 'ı': 'I', 'Ş': 'S', 'ş': 'S', 'Ğ': 'G', 'ğ': 'G',
    'Ü': 'U', 'ü': 'U', 'Ö': 'O', 'ö': 'O', 'Ç': 'C', 'ç': 'C', 'Â': 'A', 'Î': 'I', 'Û': 'U'
  };
  final b = StringBuffer();
  for (final ch in u.split('')) {
    b.write(map[ch] ?? ch);
  }
  u = b.toString().replaceAll(RegExp(r'İSTASYONU|ISTASYONU|ISTASYON'), '');
  return u.replaceAll(RegExp(r'[^A-Z0-9]'), '');
}

int railFindStation(List<RailStation> stations, String name) {
  final want = railPlainName(name);
  if (want.isEmpty) return -1;
  var idx = stations.indexWhere((s) => railPlainName(s.name) == want);
  if (idx >= 0) return idx;
  idx = stations.indexWhere((s) {
    final p = railPlainName(s.name);
    return p.isNotEmpty && (p.contains(want) || want.contains(p));
  });
  if (idx >= 0) return idx;
  if (want.length < 4) return -1;
  final head = want.substring(0, math.min(5, want.length));
  return stations.indexWhere((s) => railPlainName(s.name).startsWith(head));
}

List<RailTrip> _sortTrips(List<RailTrip> trips, List<int> offsets) =>
    trips..sort((x, y) => (x.dep - offsets[x.from]).compareTo(y.dep - offsets[y.from]));

/// Marmaray (not in the Metro İstanbul API): TCDD's published plan — Halkalı–Gebze every 15 min,
/// Ataköy–Pendik short-turns interleaved, 108 min end to end, Fri/Sat night extension every 30 min.
RailSchedule buildMarmaraySchedule(List<RailStation> stations, RailServiceDay day) {
  final prof = railProfile('B1');
  final n = stations.length;
  const runSec = 108 * 60, headway = 15 * 60, nightHeadway = 30 * 60;
  const full = {
    'G': ['05:58', '22:58', '01:28'],
    'D': ['06:05', '22:50', '01:20'],
  };
  const short = {
    'G': ['06:09', '21:54'],
    'D': ['06:09', '20:39'],
  };
  final night = day.dow == 5 || day.dow == 6;
  final directions = <RailDirection>[];
  for (final fwd in [true, false]) {
    final dir = fwd ? 'G' : 'D';
    final order = fwd ? stations : stations.reversed.toList();
    final prior = railPriorOffsets(order, prof);
    final scale = runSec / prior.last;
    final offsets = prior.map((x) => (x * scale).round()).toList();
    final trips = <RailTrip>[];
    final f = full[dir]!;
    final first = railTimeToSec(f[0])!, last = railTimeToSec(f[1])!;
    for (var t = first; t <= last; t += headway) {
      trips.add(RailTrip(t, 0, n - 1));
    }
    if (night) {
      final nightLast = railTimeToSec(f[2])!;
      for (var t = last + nightHeadway; t <= nightLast; t += nightHeadway) {
        trips.add(RailTrip(t, 0, n - 1));
      }
    }
    final ia = railFindStation(order, fwd ? 'ATAKOY' : 'PENDIK');
    final ib = railFindStation(order, fwd ? 'PENDIK' : 'ATAKOY');
    if (ia >= 0 && ib > ia) {
      final s = short[dir]!;
      for (var t = railTimeToSec(s[0])!; t <= railTimeToSec(s[1])!; t += headway) {
        trips.add(RailTrip(t, ia, ib));
      }
    }
    directions.add(RailDirection(
      dir: dir,
      forward: fwd,
      name: '${order.first.name} ➔ ${order.last.name}',
      headsign: order.last.name,
      offsets: offsets,
      timetablePoints: 2,
      trips: _sortTrips(trips, offsets),
    ));
  }
  return RailSchedule(
    line: 'B1',
    serviceDate: day.dateKey,
    dayType: day.dayType,
    official: false,
    source: 'TCDD Taşımacılık yayımlanmış Marmaray sefer planı',
    note: 'Marmaray için açık canlı konum verisi yok: konumlar ilk/son sefer ve 15 dk sefer aralığından hesaplanan tahminidir.',
    dwellSec: prof.dwell.round(),
    stations: stations,
    directions: directions,
  );
}

/// Last resort when neither the Worker nor Metro İstanbul answers: a clock-anchored frequency model.
RailSchedule buildEstimatedSchedule(String code, List<RailStation> stations, RailServiceDay day) {
  if (code == 'B1' || code == 'MARMARAY') return buildMarmaraySchedule(stations, day);
  final prof = railProfile(code);
  final n = stations.length;
  final directions = <RailDirection>[];
  for (final fwd in [true, false]) {
    final order = fwd ? stations : stations.reversed.toList();
    final offsets = railPriorOffsets(order, prof).map((x) => x.round()).toList();
    final trips = <RailTrip>[];
    var t = 6 * 3600 + (fwd ? 0 : 120);
    while (t <= 24 * 3600) {
      trips.add(RailTrip(t, 0, n - 1));
      final h = t ~/ 3600;
      final peak = day.dayType == 'I' && ((h >= 7 && h <= 9) || (h >= 17 && h <= 19));
      t += peak ? 240 : (h >= 22 ? 600 : 420);
    }
    directions.add(RailDirection(
      dir: fwd ? 'G' : 'D',
      forward: fwd,
      name: '${order.first.name} ➔ ${order.last.name}',
      headsign: order.last.name,
      offsets: offsets,
      trips: trips,
    ));
  }
  return RailSchedule(
    line: code,
    serviceDate: day.dateKey,
    dayType: day.dayType,
    official: false,
    source: 'Tahmini sıklık (resmî tarife alınamadı)',
    note: 'Resmî tarife alınamadı — trenler ortalama sefer aralığına göre gösteriliyor.',
    dwellSec: prof.dwell.round(),
    stations: stations,
    directions: directions,
  );
}

class RailTrainState {
  final String id;
  final String line;
  final String dir;
  final String headsign;
  final int prevIndex; // station index the train last served
  final int nextIndex; // station index it is heading to (== prevIndex while dwelling)
  final double progress; // 0..1 along the current segment
  final String state; // ACCELERATING | CRUISING | DECELERATING | AT_STATION
  final double speedKmh;
  final double accel; // m/s², signed
  final double lat;
  final double lon;
  final double bearing;
  final double etaSec; // to the next stop (or remaining dwell)
  final double remainingMeters;
  final List<RailStopCall> upcoming;
  final bool official;

  const RailTrainState({
    required this.id,
    required this.line,
    required this.dir,
    required this.headsign,
    required this.prevIndex,
    required this.nextIndex,
    required this.progress,
    required this.state,
    required this.speedKmh,
    required this.accel,
    required this.lat,
    required this.lon,
    required this.bearing,
    required this.etaSec,
    required this.remainingMeters,
    required this.upcoming,
    required this.official,
  });
}

/// Distance travelled after [t] seconds of a [total]-second run over [dist] metres with a
/// trapezoidal speed profile (accelerate, cruise, brake). Returns (metres, m/s, m/s²).
({double s, double v, double a}) railKinematics(double t, double total, double dist, double acc, double dec) {
  if (total <= 0 || dist <= 0) return (s: dist, v: 0, a: 0);
  final k = 1 / (2 * acc) + 1 / (2 * dec);
  final disc = total * total - 4 * k * dist;
  if (disc <= 0) {
    // Physically too short a run for the distance: degrade to constant speed.
    final v = dist / total;
    return (s: (dist * t / total).clamp(0, dist), v: v, a: 0);
  }
  final vc = (total - math.sqrt(disc)) / (2 * k);
  final t1 = vc / acc;
  final t2 = total - vc / dec;
  if (t <= 0) return (s: 0, v: 0, a: acc);
  if (t < t1) return (s: 0.5 * acc * t * t, v: acc * t, a: acc);
  if (t < t2) return (s: 0.5 * acc * t1 * t1 + vc * (t - t1), v: vc, a: 0);
  if (t < total) {
    final r = total - t;
    return (s: dist - 0.5 * dec * r * r, v: dec * r, a: -dec);
  }
  return (s: dist, v: 0, a: 0);
}

/// Every train of [s] that is on the line at [day].nowSec (plus fractional [extraSec]).
List<RailTrainState> railPositions(RailSchedule s, RailServiceDay day, {double extraSec = 0, int upcomingLimit = 6}) {
  final out = <RailTrainState>[];
  final n = s.stations.length;
  if (n < 2) return out;
  final prof = railProfile(s.line);
  final dwell = s.dwellSec.toDouble();
  final now = day.nowSec + extraSec;
  for (final d in s.directions) {
    final off = d.offsets;
    if (off.length != n) continue;
    for (final trip in d.trips) {
      if (trip.from < 0 || trip.to >= n || trip.from >= trip.to) continue;
      final base = trip.dep - off[trip.from];
      final start = trip.dep - dwell;
      final end = base + off[trip.to];
      if (now < start || now > end) continue;

      var p = trip.from;
      while (p < trip.to && now >= base + off[p + 1] - dwell) {
        p++;
      }
      final depP = base + off[p];
      final fromIdx = d.indexOf(p, n);
      final fromSt = s.stations[fromIdx];
      final id = '${s.line}-${d.dir}-${trip.dep}-${trip.from}';

      String state;
      int nextIdx;
      double lat, lon, progress, speed, accel, eta, remaining, bearing;
      if (now < depP || p == trip.to) {
        // Dwelling at p (or arrived at the terminus).
        state = 'AT_STATION';
        nextIdx = p < trip.to ? d.indexOf(p + 1, n) : fromIdx;
        lat = fromSt.lat;
        lon = fromSt.lon;
        progress = 0;
        speed = 0;
        accel = 0;
        eta = p == trip.to ? math.max(0.0, end - now) : depP - now;
        remaining = 0;
        final nb = p < trip.to ? s.stations[nextIdx] : (p > 0 ? s.stations[d.indexOf(p - 1, n)] : fromSt);
        bearing = p < trip.to
            ? bearingDeg(fromSt.lat, fromSt.lon, nb.lat, nb.lon)
            : bearingDeg(nb.lat, nb.lon, fromSt.lat, fromSt.lon);
      } else {
        nextIdx = d.indexOf(p + 1, n);
        final toSt = s.stations[nextIdx];
        final dist = math.max(1.0, haversineM(fromSt.lat, fromSt.lon, toSt.lat, toSt.lon));
        final total = (base + off[p + 1] - dwell) - depP;
        final k = railKinematics(now - depP, total, dist, prof.accel, prof.decel);
        progress = (k.s / dist).clamp(0.0, 1.0);
        lat = fromSt.lat + (toSt.lat - fromSt.lat) * progress;
        lon = fromSt.lon + (toSt.lon - fromSt.lon) * progress;
        speed = k.v * 3.6;
        accel = k.a;
        eta = math.max(0.0, total - (now - depP));
        remaining = math.max(0.0, dist - k.s);
        bearing = bearingDeg(fromSt.lat, fromSt.lon, toSt.lat, toSt.lon);
        state = k.a > 0 ? 'ACCELERATING' : (k.a < 0 ? 'DECELERATING' : 'CRUISING');
      }

      final upcoming = <RailStopCall>[];
      for (var q = p + 1; q <= trip.to && upcoming.length < upcomingLimit; q++) {
        final idx = d.indexOf(q, n);
        upcoming.add(RailStopCall(idx, s.stations[idx].name, day.at(base + off[q] - dwell)));
      }

      out.add(RailTrainState(
        id: id,
        line: s.line,
        dir: d.dir,
        headsign: s.stations[d.indexOf(trip.to, n)].name,
        prevIndex: fromIdx,
        nextIndex: nextIdx,
        progress: progress,
        state: state,
        speedKmh: speed,
        accel: accel,
        lat: lat,
        lon: lon,
        bearing: bearing,
        etaSec: eta,
        remainingMeters: remaining,
        upcoming: upcoming,
        official: s.official,
      ));
    }
  }
  return out;
}

/// Next departures from station [index] in each direction (official times when the schedule is).
List<RailDeparture> railDeparturesAt(RailSchedule s, int index, RailServiceDay day, {int perDirection = 4, int graceSec = 20}) {
  final n = s.stations.length;
  final out = <RailDeparture>[];
  if (index < 0 || index >= n) return out;
  for (final d in s.directions) {
    if (d.offsets.length != n) continue;
    final p = d.posOf(index, n);
    final times = <({int t, int to})>[];
    for (final trip in d.trips) {
      if (p < trip.from || p >= trip.to) continue;
      final t = trip.dep + d.offsets[p] - d.offsets[trip.from];
      if (t >= day.nowSec - graceSec) times.add((t: t, to: trip.to));
    }
    times.sort((a, b) => a.t.compareTo(b.t));
    for (final x in times.take(perDirection)) {
      out.add(RailDeparture(
        line: s.line,
        dir: d.dir,
        headsign: s.stations[d.indexOf(x.to, n)].name,
        at: day.at(x.t),
        official: s.official,
      ));
    }
  }
  return out;
}
