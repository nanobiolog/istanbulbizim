import 'dart:math' as math;
import '../models/transit_models.dart';

/// Route-aware bus ETA on the device (mirror of the Worker's engine, simplified).
///
/// A bus is projected onto the line polyline, then travel time to each upcoming stop is
/// integrated over 300 m steps using a speed that blends the city-wide hourly prior, the live
/// city traffic ratio and the bus's own measured speed, plus dwell and signal delay.
class EtaEngine {
  EtaEngine._();

  static const double _kx = 111320 * 0.7547; // cos(41°)
  static const double _ky = 110540;

  // Typical bus speeds (km/h) by Istanbul hour: weekday / Saturday / Sunday.
  static const _weekday = [31, 32, 33, 33, 32, 30, 26, 20, 16, 17, 19, 20, 20, 20, 20, 19, 17, 15, 14, 16, 20, 24, 27, 29];
  static const _saturday = [30, 31, 32, 33, 32, 31, 29, 26, 23, 21, 20, 19, 19, 19, 19, 19, 19, 19, 19, 20, 22, 24, 26, 28];
  static const _sunday = [30, 31, 32, 33, 33, 32, 31, 29, 27, 25, 24, 23, 22, 22, 22, 22, 22, 22, 22, 23, 24, 26, 28, 29];

  static DateTime _istanbulNow(DateTime now) => now.toUtc().add(const Duration(hours: 3));

  static double priorKmh(DateTime now) {
    final t = _istanbulNow(now);
    final table = t.weekday == DateTime.sunday ? _sunday : (t.weekday == DateTime.saturday ? _saturday : _weekday);
    return table[t.hour].toDouble();
  }

  static bool _peak(DateTime now) {
    final t = _istanbulNow(now);
    if (t.weekday >= DateTime.saturday) return false;
    return (t.hour >= 7 && t.hour <= 9) || (t.hour >= 16 && t.hour <= 19);
  }

  /// Fills ETA fields on [buses] that have a matching route. Buses that already carry a server
  /// ETA keep it. Returns a new list.
  static List<BusVehicle> annotate(
    List<BusVehicle> buses,
    LineRouteDetails? route,
    TrafficSummary? traffic,
    DateTime now,
  ) {
    if (route == null || route.directions.isEmpty) return buses;
    final indexes = <String, _RouteIndex>{};
    route.directions.forEach((k, d) {
      final ix = _RouteIndex.build(d);
      if (ix != null) indexes[k] = ix;
    });
    if (indexes.isEmpty) return buses;

    final ratio = traffic?.ratio ?? 1.0;
    final base = priorKmh(now) * ratio;
    final dwell = _peak(now) ? 24.0 : 16.0;
    final signalPerKm = _peak(now) ? 12.0 : 7.0;

    return buses.map((b) {
      if (b.etaAt != null) return b;
      _Loc? best;
      final moving = b.speed >= 6 && b.bearing != null;
      for (final e in indexes.entries) {
        final p = e.value.project(b.lat, b.lon);
        var score = p.off;
        if (moving) {
          final d = _angDiff(b.bearing!, e.value.segBearing(p.seg));
          if (d > 100) {
            score += 250;
          } else if (d > 60) {
            score += 60;
          }
        }
        if (best == null || score < best.score) best = _Loc(e.key, e.value, p, score);
      }
      if (best == null || best.p.off > 400) return b;

      final ix = best.ix;
      // own speed matters most right now, the prior over the longer horizon
      final own = b.speed >= 8 ? b.speed : base;
      final speedNear = (0.4 * own + 0.6 * base).clamp(6.0, 55.0);
      final speedFar = base.clamp(6.0, 55.0);

      double sec = 0;
      double a = best.p.along;
      int count = 0;
      _Stop? next;
      double nextSec = 0;
      double lastSec = 0;
      for (final s in ix.stops) {
        if (s.along < best.p.along - 25) continue;
        final target = math.max(s.along, a);
        final dist = target - a;
        final near = math.min(dist, math.max(0.0, 800 - (a - best.p.along)));
        final far = dist - near;
        sec += near / (speedNear / 3.6) + far / (speedFar / 3.6) + dist / 1000 * signalPerKm;
        a = target;
        count++;
        if (next == null) {
          next = s;
          nextSec = sec;
        }
        lastSec = sec;
        sec += dwell;
      }
      if (next == null) return b;

      final dist0 = math.max(0.0, next.along - best.p.along);
      final age = math.min(b.liveAgeSeconds(now), 120);
      final atStop = dist0 <= 35 && b.speed < 8;
      final eta = atStop ? 0.0 : math.max(0.0, nextSec - age);
      final d = route.directions[best.dir];
      return b.copyWith(
        direction: best.dir,
        directionName: d?.name,
        destination: d?.destination,
        headsign: d?.headsign ?? '',
        nextStop: next.name,
        nextStopDistM: dist0.round(),
        nextStopEtaSec: eta.round(),
        etaAt: now.add(Duration(seconds: eta.round())),
        terminalEtaAt: now.add(Duration(seconds: math.max(0.0, lastSec - age).round())),
        etaConf: _conf(b.liveAgeSeconds(now), best.p.off),
        stopsLeft: count,
      );
    }).toList();
  }

  static String _conf(int age, double off) {
    if (age <= 45 && off <= 50) return 'high';
    if (age <= 120 && off <= 120) return 'med';
    return 'low';
  }

  static double _angDiff(double a, double b) => (((a - b + 540) % 360) - 180).abs();
}

class _Stop {
  final String name;
  final double along;
  _Stop(this.name, this.along);
}

class _Proj {
  final double along;
  final double off;
  final int seg;
  _Proj(this.along, this.off, this.seg);
}

class _Loc {
  final String dir;
  final _RouteIndex ix;
  final _Proj p;
  final double score;
  _Loc(this.dir, this.ix, this.p, this.score);
}

class _RouteIndex {
  final List<double> xs;
  final List<double> ys;
  final List<double> cum;
  final List<_Stop> stops;
  _RouteIndex(this.xs, this.ys, this.cum, this.stops);

  static _RouteIndex? build(LineDirectionRoute d) {
    final pts = d.coordinates.length >= 2
        ? d.coordinates
        : d.stops.map((s) => [s.lat, s.lon]).toList();
    if (pts.length < 2) return null;
    final xs = <double>[], ys = <double>[], cum = <double>[];
    for (var i = 0; i < pts.length; i++) {
      xs.add(pts[i][1] * EtaEngine._kx);
      ys.add(pts[i][0] * EtaEngine._ky);
      cum.add(i == 0 ? 0 : cum[i - 1] + math.sqrt(math.pow(xs[i] - xs[i - 1], 2) + math.pow(ys[i] - ys[i - 1], 2)));
    }
    final ix = _RouteIndex(xs, ys, cum, []);
    var prev = 0.0;
    for (final s in d.stops) {
      final p = ix.project(s.lat, s.lon, lo: prev - 200);
      final along = math.max(prev, p.along);
      ix.stops.add(_Stop(s.name, along));
      prev = along;
    }
    return ix;
  }

  _Proj project(double lat, double lon, {double lo = double.negativeInfinity}) {
    final x = lon * EtaEngine._kx, y = lat * EtaEngine._ky;
    var best = double.infinity, bestAlong = 0.0;
    var bestSeg = 0;
    for (var i = 0; i < xs.length - 1; i++) {
      if (cum[i + 1] < lo) continue;
      final dx = xs[i + 1] - xs[i], dy = ys[i + 1] - ys[i];
      final l2 = dx * dx + dy * dy;
      var u = l2 > 0 ? ((x - xs[i]) * dx + (y - ys[i]) * dy) / l2 : 0.0;
      u = u.clamp(0.0, 1.0);
      final ex = x - (xs[i] + u * dx), ey = y - (ys[i] + u * dy);
      final dd = math.sqrt(ex * ex + ey * ey);
      if (dd < best) {
        best = dd;
        bestAlong = cum[i] + u * math.sqrt(l2);
        bestSeg = i;
      }
    }
    return _Proj(bestAlong, best == double.infinity ? 99999 : best, bestSeg);
  }

  double segBearing(int seg) {
    final i = seg.clamp(0, xs.length - 2);
    return (math.atan2(xs[i + 1] - xs[i], ys[i + 1] - ys[i]) * 180 / math.pi + 360) % 360;
  }
}
