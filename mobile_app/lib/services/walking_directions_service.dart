import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'rail_engine.dart' show haversineM, bearingDeg;

class WalkStep {
  final String instruction;
  final String type; // OSRM maneuver type
  final String modifier;
  final String street;
  final double distanceM; // length of the step that starts at [location]
  final LatLng location; // where the manoeuvre happens

  const WalkStep({
    required this.instruction,
    required this.type,
    required this.modifier,
    required this.street,
    required this.distanceM,
    required this.location,
  });
}

class WalkRoute {
  final List<LatLng> points;
  final double distanceM;
  final double durationSec;
  final List<WalkStep> steps;

  /// False when routing was unavailable and the route is a straight line.
  final bool routed;

  WalkRoute({
    required this.points,
    required this.distanceM,
    required this.durationSec,
    required this.steps,
    required this.routed,
  });

  late final List<double> cumulative = () {
    final out = <double>[0];
    for (var i = 1; i < points.length; i++) {
      out.add(out[i - 1] + haversineM(points[i - 1].latitude, points[i - 1].longitude, points[i].latitude, points[i].longitude));
    }
    return out;
  }();
}

/// Where the user is along a route right now.
class RouteProgress {
  final double alongM; // metres walked along the route
  final double offRouteM; // distance from the route line
  final double remainingM;
  final LatLng lookahead; // point ~[lookaheadM] ahead on the route (AR arrow target)
  final int nextStepIndex; // next manoeuvre still ahead
  final double toNextStepM;

  const RouteProgress({
    required this.alongM,
    required this.offRouteM,
    required this.remainingM,
    required this.lookahead,
    required this.nextStepIndex,
    required this.toNextStepM,
  });
}

/// Pedestrian routing on OpenStreetMap (FOSSGIS OSRM foot profile) with Turkish instructions.
class WalkingDirectionsService {
  static const String footRouter = 'https://routing.openstreetmap.de/routed-foot/route/v1/foot';
  static const double walkSpeedMs = 1.3;

  final http.Client _client;
  WalkingDirectionsService({http.Client? client}) : _client = client ?? http.Client();

  Future<WalkRoute> route(LatLng from, LatLng to) async {
    try {
      final uri = Uri.parse('$footRouter/${from.longitude.toStringAsFixed(6)},${from.latitude.toStringAsFixed(6)};'
          '${to.longitude.toStringAsFixed(6)},${to.latitude.toStringAsFixed(6)}'
          '?overview=full&geometries=geojson&steps=true');
      final res = await _client.get(uri, headers: {'User-Agent': 'IstanbulBizim/1.0 (walking directions)'}).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final r = parseOsrm(jsonDecode(utf8.decode(res.bodyBytes)));
        if (r != null) return r;
      }
    } catch (_) {}
    return straight(from, to);
  }

  static WalkRoute straight(LatLng from, LatLng to) {
    final d = haversineM(from.latitude, from.longitude, to.latitude, to.longitude);
    return WalkRoute(
      points: [from, to],
      distanceM: d,
      durationSec: d * 1.25 / walkSpeedMs, // streets are rarely straight
      steps: [
        WalkStep(
          instruction: '${compassWord(bearingDeg(from.latitude, from.longitude, to.latitude, to.longitude))} yönünde yürüyün',
          type: 'depart',
          modifier: 'straight',
          street: '',
          distanceM: d,
          location: from,
        ),
        WalkStep(instruction: 'Varış noktasına ulaştınız', type: 'arrive', modifier: '', street: '', distanceM: 0, location: to),
      ],
      routed: false,
    );
  }

  static WalkRoute? parseOsrm(dynamic j) {
    if (j is! Map || j['routes'] is! List || (j['routes'] as List).isEmpty) return null;
    final r = (j['routes'] as List).first as Map;
    final coords = (r['geometry']?['coordinates'] as List?) ?? const [];
    final pts = coords
        .whereType<List>()
        .where((c) => c.length >= 2)
        .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();
    if (pts.length < 2) return null;
    final steps = <WalkStep>[];
    for (final leg in (r['legs'] as List? ?? const [])) {
      for (final s in ((leg as Map)['steps'] as List? ?? const [])) {
        final m = (s as Map)['maneuver'] as Map? ?? const {};
        final loc = m['location'] as List? ?? const [0, 0];
        final type = m['type']?.toString() ?? '';
        final modifier = m['modifier']?.toString() ?? '';
        final street = s['name']?.toString() ?? '';
        steps.add(WalkStep(
          instruction: turkishInstruction(type, modifier, street, exit: (m['exit'] as num?)?.toInt()),
          type: type,
          modifier: modifier,
          street: street,
          distanceM: (s['distance'] as num?)?.toDouble() ?? 0,
          location: LatLng((loc[1] as num).toDouble(), (loc[0] as num).toDouble()),
        ));
      }
    }
    return WalkRoute(
      points: pts,
      distanceM: (r['distance'] as num?)?.toDouble() ?? 0,
      // FOSSGIS foot durations assume ~5 km/h; keep theirs when present.
      durationSec: (r['duration'] as num?)?.toDouble() ?? ((r['distance'] as num?)?.toDouble() ?? 0) / walkSpeedMs,
      steps: steps,
      routed: true,
    );
  }

  static String compassWord(double b) {
    const words = ['Kuzey', 'Kuzeydoğu', 'Doğu', 'Güneydoğu', 'Güney', 'Güneybatı', 'Batı', 'Kuzeybatı'];
    return words[((b % 360) / 45).round() % 8];
  }

  static String turnWord(String modifier) {
    switch (modifier) {
      case 'uturn':
        return 'Geri dönün';
      case 'sharp right':
        return 'Keskin sağa dönün';
      case 'right':
        return 'Sağa dönün';
      case 'slight right':
        return 'Hafif sağa yönelin';
      case 'slight left':
        return 'Hafif sola yönelin';
      case 'left':
        return 'Sola dönün';
      case 'sharp left':
        return 'Keskin sola dönün';
      default:
        return 'Düz devam edin';
    }
  }

  static String turkishInstruction(String type, String modifier, String street, {int? exit}) {
    final onto = street.isNotEmpty ? ' — $street' : '';
    switch (type) {
      case 'depart':
        return street.isNotEmpty ? '$street boyunca yürümeye başlayın' : 'Yürümeye başlayın';
      case 'arrive':
        return 'Varış noktasına ulaştınız';
      case 'roundabout':
      case 'rotary':
        return exit != null ? 'Meydandan $exit. çıkıştan çıkın$onto' : 'Meydanı dolaşarak devam edin$onto';
      case 'new name':
      case 'continue':
        return modifier.isEmpty || modifier == 'straight' ? 'Düz devam edin$onto' : '${turnWord(modifier)}$onto';
      default:
        return '${turnWord(modifier)}$onto';
    }
  }

  /// Snaps [pos] to the route and returns progress plus a look-ahead target for the AR arrow.
  static RouteProgress progress(WalkRoute route, LatLng pos, {double lookaheadM = 25}) {
    final pts = route.points;
    final cum = route.cumulative;
    var bestAlong = 0.0, bestOff = double.infinity;
    // Local equirectangular projection around the user (metres): accurate at walking scale.
    final kx = 111320 * math.cos(pos.latitude * math.pi / 180), ky = 110540.0;
    for (var i = 0; i < pts.length - 1; i++) {
      final ax = (pts[i].longitude - pos.longitude) * kx, ay = (pts[i].latitude - pos.latitude) * ky;
      final bx = (pts[i + 1].longitude - pos.longitude) * kx, by = (pts[i + 1].latitude - pos.latitude) * ky;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 > 0 ? (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0) : 0.0;
      final px = ax + dx * t, py = ay + dy * t;
      final off = math.sqrt(px * px + py * py);
      if (off < bestOff) {
        bestOff = off;
        bestAlong = cum[i] + (cum[i + 1] - cum[i]) * t;
      }
    }
    final total = cum.last;
    final target = math.min(total, bestAlong + lookaheadM);
    var j = 0;
    while (j < cum.length - 2 && cum[j + 1] < target) {
      j++;
    }
    final segLen = cum[j + 1] - cum[j];
    final f = segLen > 0 ? (target - cum[j]) / segLen : 0.0;
    final look = LatLng(
      pts[j].latitude + (pts[j + 1].latitude - pts[j].latitude) * f,
      pts[j].longitude + (pts[j + 1].longitude - pts[j].longitude) * f,
    );

    var nextStep = route.steps.length - 1;
    var toNext = math.max(0.0, total - bestAlong);
    for (var k = 0; k < route.steps.length; k++) {
      final along = _alongOf(route, route.steps[k].location);
      if (along > bestAlong + 5) {
        nextStep = k;
        toNext = along - bestAlong;
        break;
      }
    }
    return RouteProgress(
      alongM: bestAlong,
      offRouteM: bestOff,
      remainingM: math.max(0.0, total - bestAlong),
      lookahead: look,
      nextStepIndex: nextStep,
      toNextStepM: toNext,
    );
  }

  static double _alongOf(WalkRoute route, LatLng p) {
    var best = double.infinity, along = 0.0;
    for (var i = 0; i < route.points.length; i++) {
      final d = haversineM(p.latitude, p.longitude, route.points[i].latitude, route.points[i].longitude);
      if (d < best) {
        best = d;
        along = route.cumulative[i];
      }
    }
    return along;
  }

  static String formatDistance(double m) {
    if (m < 1000) return '${(m / 5).round() * 5} m';
    return '${(m / 1000).toStringAsFixed(1)} km';
  }

  static String formatWalk(double sec) {
    final min = (sec / 60).ceil();
    return min < 60 ? '$min dk yürüme' : '${min ~/ 60} sa ${min % 60} dk yürüme';
  }
}
