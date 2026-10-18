import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// Decodes a Google encoded polyline (precision 5) — the format written by tools/build_transit_data.py.
List<LatLng> decodePolyline(String s) {
  final out = <LatLng>[];
  var i = 0, lat = 0, lon = 0;
  while (i < s.length) {
    for (var k = 0; k < 2; k++) {
      var shift = 0, result = 0, b = 0;
      do {
        b = s.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && i < s.length);
      // no `~`: on the JS fallback (dart2js) bitwise results are unsigned 32-bit
      final d = (result & 1) != 0 ? -(result >> 1) - 1 : (result >> 1);
      if (k == 0) {
        lat += d;
      } else {
        lon += d;
      }
    }
    out.add(LatLng(lat / 1e5, lon / 1e5));
  }
  return out;
}

double haversine(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}

double bearingDeg(LatLng a, LatLng b) {
  final la1 = a.latitude * math.pi / 180, la2 = b.latitude * math.pi / 180;
  final dl = (b.longitude - a.longitude) * math.pi / 180;
  final y = math.sin(dl) * math.cos(la2);
  final x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

Color hexColor(String? hex, [Color fallback = const Color(0xFF0284C7)]) {
  if (hex == null) return fallback;
  final h = hex.replaceAll('#', '');
  if (h.length != 6) return fallback;
  return Color(int.parse('FF$h', radix: 16));
}

/// A polyline with cumulative distances so positions can be interpolated by metres travelled.
class MeasuredPath {
  final List<LatLng> points;
  final Float64List cum;

  MeasuredPath(this.points) : cum = Float64List(points.length) {
    for (var i = 1; i < points.length; i++) {
      cum[i] = cum[i - 1] +
          haversine(points[i - 1].latitude, points[i - 1].longitude, points[i].latitude, points[i].longitude);
    }
  }

  double get length => cum.isEmpty ? 0 : cum[cum.length - 1];

  /// Raw interpolated point at [s] metres along the path without tangent bearing calculation.
  LatLng rawPointAt(double s) {
    if (points.isEmpty) return const LatLng(0, 0);
    if (points.length == 1 || s <= 0) return points.first;
    if (s >= length) return points.last;
    var lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final seg = cum[hi] - cum[lo];
    final t = seg <= 0 ? 0.0 : (s - cum[lo]) / seg;
    final a = points[lo], b = points[hi];
    return LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
  }

  /// Point and smooth bogie-chord tangent heading at [s] metres along the path.
  (LatLng, double) pointAt(double s) {
    if (points.length < 2) return (points.isEmpty ? const LatLng(0, 0) : points.first, 0);
    if (s <= 0) return (points.first, bearingDeg(points[0], points[1]));
    if (s >= length) return (points.last, bearingDeg(points[points.length - 2], points.last));
    final pt = rawPointAt(s);
    final sRear = math.max(0.0, s - 12.0);
    final sFront = math.min(length, s + 12.0);
    final pRear = rawPointAt(sRear);
    final pFront = rawPointAt(sFront);
    final h = (sFront - sRear > 0.5) ? bearingDeg(pRear, pFront) : bearingDeg(points.first, points.last);
    return (pt, h);
  }

  /// Sub-path between two distances (used to highlight a leg or slice a curved train spine).
  List<LatLng> slice(double from, double to) {
    if (points.isEmpty) return const [];
    final a = from.clamp(0.0, length);
    final b = to.clamp(0.0, length);
    final lo = math.min(a, b);
    final hi = math.max(a, b);
    final out = <LatLng>[rawPointAt(lo)];
    for (var i = 0; i < points.length; i++) {
      if (cum[i] > lo && cum[i] < hi) out.add(points[i]);
    }
    if (hi > lo) out.add(rawPointAt(hi));
    return from <= to ? out : out.reversed.toList();
  }
}

// ───────────────────────── rail ─────────────────────────

enum RailMode { suburban, metro, tram, funicular, cable }

RailMode railModeOf(String s) => switch (s) {
      'suburban' => RailMode.suburban,
      'tram' => RailMode.tram,
      'funicular' => RailMode.funicular,
      'cable' => RailMode.cable,
      _ => RailMode.metro,
    };

extension RailModeText on RailMode {
  String get label => switch (this) {
        RailMode.suburban => 'MARMARAY',
        RailMode.metro => 'METRO',
        RailMode.tram => 'TRAMVAY',
        RailMode.funicular => 'FÜNİKÜLER',
        RailMode.cable => 'TELEFERİK',
      };

  IconData get icon => switch (this) {
        RailMode.suburban => Icons.train_rounded,
        RailMode.metro => Icons.subway_rounded,
        RailMode.tram => Icons.tram_rounded,
        RailMode.funicular => Icons.directions_railway_filled_rounded,
        RailMode.cable => Icons.airline_seat_recline_normal_rounded,
      };

  /// Key into vehicle_media.json / the procedural 3D model catalogue.
  String get mediaKey => switch (this) {
        RailMode.suburban => 'marmaray',
        RailMode.metro => 'metro',
        RailMode.tram => 'tram',
        RailMode.funicular => 'funicular',
        RailMode.cable => 'cable',
      };

  /// Kinematics (m/s²) — Istanbul rolling stock averages.
  double get accel => switch (this) {
        RailMode.suburban => 0.95,
        RailMode.metro => 0.95,
        RailMode.tram => 1.1,
        RailMode.funicular => 0.75,
        RailMode.cable => 0.5,
      };

  double get decel => switch (this) {
        RailMode.suburban => 1.05,
        RailMode.metro => 1.1,
        RailMode.tram => 1.2,
        RailMode.funicular => 0.85,
        RailMode.cable => 0.5,
      };
}

class Headway {
  final int startMin;
  final int endMin;
  final int seconds;
  const Headway(this.startMin, this.endMin, this.seconds);
}

class RailStop {
  final String stationId;
  final double distM;
  final LatLng pos;
  const RailStop(this.stationId, this.distM, this.pos);
}

class RailVariant {
  final int id;
  final String from;
  final String to;
  final MeasuredPath path;
  final List<RailStop> stops;

  RailVariant({required this.id, required this.from, required this.to, required this.path, required this.stops});

  factory RailVariant.fromJson(Map<String, dynamic> j) {
    final stops = <RailStop>[];
    for (final s in (j['stops'] as List? ?? const [])) {
      final l = s as List;
      stops.add(RailStop(l[0].toString(), (l[1] as num).toDouble(),
          LatLng((l[2] as num).toDouble(), (l[3] as num).toDouble())));
    }
    return RailVariant(
      id: (j['id'] as num?)?.toInt() ?? 0,
      from: j['from']?.toString() ?? '',
      to: j['to']?.toString() ?? '',
      path: MeasuredPath(decodePolyline(j['path']?.toString() ?? '')),
      stops: stops,
    );
  }

  int indexOfStation(String sid) => stops.indexWhere((s) => s.stationId == sid);
}

class RailLine {
  final String code;
  final String name;
  final String longName;
  final RailMode mode;
  final Color color;
  final String operator;
  final double speedKmh;
  final double dwellS;
  final List<Headway> headways;
  final String headwaySource;
  final List<RailVariant> variants;

  RailLine({
    required this.code,
    required this.name,
    required this.longName,
    required this.mode,
    required this.color,
    required this.operator,
    required this.speedKmh,
    required this.dwellS,
    required this.headways,
    required this.headwaySource,
    required this.variants,
  });

  factory RailLine.fromJson(Map<String, dynamic> j) {
    final hw = <Headway>[];
    for (final h in (j['headways'] as List? ?? const [])) {
      final l = h as List;
      hw.add(Headway((l[0] as num).toInt(), (l[1] as num).toInt(), math.max(60, (l[2] as num).toInt())));
    }
    final vs = (j['variants'] as List? ?? const [])
        .map((v) => RailVariant.fromJson(v as Map<String, dynamic>))
        .where((v) => v.stops.length >= 2 && v.path.points.length >= 2)
        .toList();
    // Duplicate relations for the same direction (OSM keeps old + new): keep the most complete.
    final byEnds = <String, RailVariant>{};
    for (final v in vs) {
      final k = '${v.from}>${v.to}';
      final prev = byEnds[k];
      if (prev == null || v.stops.length > prev.stops.length) byEnds[k] = v;
    }
    return RailLine(
      code: j['code']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      longName: j['long']?.toString() ?? '',
      mode: railModeOf(j['mode']?.toString() ?? ''),
      color: hexColor(j['color']?.toString()),
      operator: j['operator']?.toString() ?? '',
      speedKmh: (j['speed_kmh'] as num?)?.toDouble() ?? 60,
      dwellS: (j['dwell_s'] as num?)?.toDouble() ?? 30,
      headways: hw,
      headwaySource: j['headway_src']?.toString() ?? '',
      variants: vs.where((v) => identical(byEnds['${v.from}>${v.to}'], v)).toList(),
    );
  }

  bool get isMarmaray => code == 'B1';
  String get badge => code == 'B1' ? 'B1' : code;
}

class StationEntrance {
  final String ref;
  final String name;
  final LatLng pos;
  final bool wheelchair;
  const StationEntrance(this.ref, this.name, this.pos, this.wheelchair);

  String get label {
    if (ref.isNotEmpty) return 'Giriş $ref';
    if (name.isNotEmpty) return name.length > 22 ? '${name.substring(0, 21)}…' : name;
    return 'Giriş';
  }
}

enum StationKind { underground, surface, elevated }

class NetworkStation {
  final String id;
  final String name;
  final LatLng pos;
  final List<String> lines;
  final StationKind kind;
  final double depth;
  final String depthSource;
  final List<StationEntrance> entrances;
  final int elevators;
  final int escalators;
  final int platformCount;
  final bool islandPlatform;

  /// Per line: 'u' underground, 's' surface, 'e' elevated, and platform depth below street (m).
  final Map<String, String> kinds;
  final Map<String, double> depths;
  final Map<String, String> depthSources;

  NetworkStation({
    required this.id,
    required this.name,
    required this.pos,
    required this.lines,
    required this.kind,
    required this.depth,
    required this.depthSource,
    required this.entrances,
    required this.elevators,
    required this.escalators,
    required this.platformCount,
    required this.islandPlatform,
    this.kinds = const {},
    this.depths = const {},
    this.depthSources = const {},
  });

  factory NetworkStation.fromJson(String id, Map<String, dynamic> j) {
    final ents = <StationEntrance>[];
    for (final e in (j['entrances'] as List? ?? const [])) {
      final m = e as Map<String, dynamic>;
      ents.add(StationEntrance(m['ref']?.toString() ?? '', m['name']?.toString() ?? '',
          LatLng((m['lat'] as num).toDouble(), (m['lon'] as num).toDouble()), m['wc'] == true));
    }
    final kind = switch (j['kind']?.toString()) {
      'underground' => StationKind.underground,
      'elevated' => StationKind.elevated,
      _ => StationKind.surface,
    };
    return NetworkStation(
      id: id,
      name: j['name']?.toString() ?? '',
      pos: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
      lines: (j['lines'] as List? ?? const []).map((e) => e.toString()).toList(),
      kind: kind,
      depth: (j['depth'] as num?)?.toDouble() ?? 0,
      depthSource: j['depth_src']?.toString() ?? 'tahmini',
      entrances: ents,
      elevators: (j['elevators'] as num?)?.toInt() ?? 0,
      escalators: (j['escalators'] as num?)?.toInt() ?? 0,
      platformCount: (j['platforms'] as num?)?.toInt() ?? 0,
      islandPlatform: j['platform']?.toString() != 'side',
      kinds: ((j['kinds'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), v.toString())),
      depths: ((j['depths'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), (v as num).toDouble())),
      depthSources: ((j['depth_srcs'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), v.toString())),
    );
  }

  StationKind kindFor(String line) => switch (kinds[line]) {
        'u' => StationKind.underground,
        'e' => StationKind.elevated,
        's' => StationKind.surface,
        _ => kind,
      };

  double depthFor(String line) => depths[line] ?? depth;
  String depthSourceFor(String line) => depthSources[line] ?? depthSource;

  /// The line whose platforms are deepest (the one the 3D view is built around by default).
  String get primaryLine {
    if (lines.isEmpty) return '';
    final sorted = [...lines]..sort((a, b) {
        final da = kindFor(a) == StationKind.underground ? depthFor(a) : -1.0;
        final db = kindFor(b) == StationKind.underground ? depthFor(b) : -1.0;
        return db.compareTo(da);
      });
    return sorted.first;
  }

  bool get isUnderground => kind == StationKind.underground && depth > 1;

  /// Concourse (gates) level: roughly a third of the way down, 6–12 m.
  double get concourseDepth => isUnderground ? (depth * 0.38).clamp(5.0, 12.0) : 0;

  /// Escalator run from concourse to platform (m along the incline).
  double get escalatorLength {
    final rise = (depth - concourseDepth).abs();
    return rise <= 0 ? 0 : rise / math.sin(30 * math.pi / 180);
  }

  int get entranceCount => entrances.isNotEmpty ? entrances.length : (isUnderground ? 4 : 2);
}

class RailProject {
  final String code;
  final String longName;
  final Color color;
  final List<List<LatLng>> segments;
  final List<(String, LatLng)> stations;

  RailProject(this.code, this.longName, this.color, this.segments, this.stations);

  factory RailProject.fromJson(Map<String, dynamic> j) => RailProject(
        j['code']?.toString() ?? '',
        j['long']?.toString() ?? '',
        hexColor(j['color']?.toString(), const Color(0xFF9CA3AF)),
        (j['segments'] as List? ?? const []).map((s) => decodePolyline(s.toString())).toList(),
        (j['stations'] as List? ?? const [])
            .map((s) => (
                  (s as Map)['name'].toString(),
                  LatLng((s['lat'] as num).toDouble(), (s['lon'] as num).toDouble()),
                ))
            .toList(),
      );
}

// ───────────────────────── ferries ─────────────────────────

class FerryOperator {
  final String id;
  final String name;
  final String short;
  final Color color;
  final bool municipal;
  final String url;
  const FerryOperator(this.id, this.name, this.short, this.color, this.municipal, this.url);

  /// Key into vehicle_media.json.
  String get mediaKey => switch (id) {
        'turyol' => 'ferry_turyol',
        'dentur' => 'ferry_dentur',
        'ido' => 'ferry_ido',
        _ => 'ferry_sh',
      };
}

class Pier {
  final String id;
  final String name;
  final String fullName;
  final LatLng pos;
  final List<String> operators;
  const Pier(this.id, this.name, this.fullName, this.pos, this.operators);
}

class FerryTrip {
  /// bit0 = Monday … bit6 = Sunday
  final int days;
  final List<String> piers;

  /// Minutes after midnight of the service day (may exceed 1440).
  final List<int> minutes;
  final String note;
  const FerryTrip(this.days, this.piers, this.minutes, this.note);

  bool runsOn(int weekday) => (days >> (weekday - 1)) & 1 == 1; // DateTime.weekday: 1 = Monday
}

class FerryLine {
  final String id;
  final String operatorId;
  final String name;
  final String code;
  final String source;
  final bool official;
  final String url;
  final List<String> piers;
  final List<FerryTrip> trips;

  FerryLine(this.id, this.operatorId, this.name, this.code, this.source, this.official, this.url, this.piers, this.trips);

  factory FerryLine.fromJson(Map<String, dynamic> j) {
    final trips = <FerryTrip>[];
    for (final p in (j['patterns'] as List? ?? const [])) {
      for (final t in ((p as Map)['trips'] as List? ?? const [])) {
        final m = t as Map;
        final stops = (m['s'] as List);
        trips.add(FerryTrip(
          (m['d'] as num?)?.toInt() ?? 127,
          stops.map((s) => (s as List)[0].toString()).toList(),
          stops.map((s) => ((s as List)[1] as num).toInt()).toList(),
          m['n']?.toString() ?? '',
        ));
      }
    }
    trips.sort((a, b) => a.minutes.first.compareTo(b.minutes.first));
    return FerryLine(
      j['id']?.toString() ?? '',
      j['op']?.toString() ?? 'sh',
      j['name']?.toString() ?? '',
      j['code']?.toString() ?? '',
      j['src']?.toString() ?? '',
      j['official'] == true,
      j['url']?.toString() ?? '',
      (j['piers'] as List? ?? const []).map((e) => e.toString()).toList(),
      trips,
    );
  }
}

/// A photo with its attribution (Wikimedia Commons).
class VehiclePhoto {
  final String url;
  final String page;
  final String title;
  final String author;
  final String license;
  const VehiclePhoto(this.url, this.page, this.title, this.author, this.license);

  factory VehiclePhoto.fromJson(Map<String, dynamic> j) => VehiclePhoto(
        j['url']?.toString() ?? '',
        j['page']?.toString() ?? '',
        j['title']?.toString() ?? '',
        j['author']?.toString() ?? '',
        j['license']?.toString() ?? '',
      );

  String get credit => '$author · $license · Wikimedia Commons';
}

/// A ferry position received over AIS (via the Worker's /ferries/live).
class LiveVessel {
  final int mmsi;
  final String name;
  final LatLng pos;
  final double sog; // knots
  final double cog; // degrees
  final String operatorId;
  final int ageSec;
  const LiveVessel(this.mmsi, this.name, this.pos, this.sog, this.cog, this.operatorId, this.ageSec);

  /// Smooth dead-reckoned position along [cog] at [sog] knots since [fetchedAt].
  LatLng posAt(DateTime? fetchedAt, DateTime now) {
    if (fetchedAt == null || sog < 0.8) return pos;
    final dtSec = (now.difference(fetchedAt).inMicroseconds / 1e6).clamp(0.0, 32.0);
    final distM = (sog * 0.514444 * dtSec).clamp(0.0, 180.0);
    if (distM < 0.2) return pos;
    final rad = cog * math.pi / 180.0;
    final dLat = (distM * math.cos(rad)) / 110540.0;
    final dLon = (distM * math.sin(rad)) / (111320.0 * math.cos(pos.latitude * math.pi / 180.0));
    return LatLng(pos.latitude + dLat, pos.longitude + dLon);
  }

  factory LiveVessel.fromJson(Map<String, dynamic> j) => LiveVessel(
        (j['mmsi'] as num?)?.toInt() ?? 0,
        j['name']?.toString() ?? '',
        LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
        (j['sog'] as num?)?.toDouble() ?? 0,
        (j['cog'] as num?)?.toDouble() ?? 0,
        j['op']?.toString() ?? '',
        (j['age'] as num?)?.toInt() ?? 0,
      );
}

/// Today's ferry service notice (Şehir Hatları cancellations / replacement timetables), from the
/// Worker's TransitHub (/ferries/status).
/// UTC instant → DateTime whose fields are Istanbul wall-clock time (UTC+3), like AppClock.now().
DateTime _istanbulWall(DateTime utc) {
  final u = utc.add(const Duration(hours: 3));
  return DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second);
}

class FerryStatus {
  final String date; // yyyy-mm-dd the notice applies to
  final bool active;
  final String message;
  final Set<String> cancelledLineIds;
  final List<String> cancelledNames;
  final Map<String, List<FerryTrip>> overrides;
  final DateTime? updatedAt;
  final String source;

  const FerryStatus({
    this.date = '',
    this.active = false,
    this.message = '',
    this.cancelledLineIds = const {},
    this.cancelledNames = const [],
    this.overrides = const {},
    this.updatedAt,
    this.source = '',
  });

  static FerryStatus fromJson(Map<String, dynamic> j) {
    final ov = <String, List<FerryTrip>>{};
    final raw = j['overrides'];
    if (raw is Map) {
      raw.forEach((id, v) {
        if (v is Map && v['patterns'] is List) {
          ov[id.toString()] = FerryLine.fromJson({'id': id, 'patterns': v['patterns']}).trips;
        }
      });
    }
    final t = (j['updated_at'] as num?)?.toInt() ?? 0;
    return FerryStatus(
      date: j['date']?.toString() ?? '',
      active: j['active'] == true && j['available'] != false, // hub couldn't reach Şehir Hatları
      message: j['message']?.toString() ?? '',
      cancelledLineIds: ((j['cancelled_line_ids'] as List?) ?? const []).map((e) => e.toString()).toSet(),
      cancelledNames: ((j['cancelled_names'] as List?) ?? const []).map((e) => e.toString()).toList(),
      overrides: ov,
      updatedAt: t > 0 ? _istanbulWall(DateTime.fromMillisecondsSinceEpoch(t, isUtc: true)) : null,
      source: j['source']?.toString() ?? '',
    );
  }

  /// True when the notice is about [day] (Istanbul date).
  bool appliesTo(DateTime day) {
    if (!active || date.isEmpty) return false;
    final key = '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    return key == date;
  }

  bool get hasNotice => active && (cancelledLineIds.isNotEmpty || overrides.isNotEmpty || message.isNotEmpty);
}
