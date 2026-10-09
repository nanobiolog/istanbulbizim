import 'dart:math' as math;
import 'package:flutter/material.dart';

class BusVehicle {
  final String id;
  final double lat;
  final double lon;
  final double speed;
  final String time;
  final int ageSeconds;
  final String operator;
  final String plate;
  final String line;
  final String direction; // 'D' or 'G'
  final String directionName;
  final String headsign;
  final double? bearing;

  final String destination;
  final String nextStop;
  final int? nextStopEtaSec;
  final int? nextStopDistM;

  /// Absolute arrival time at [nextStop]. Counters derive from this, so they tick without a refetch.
  final DateTime? etaAt;
  final DateTime? terminalEtaAt;
  final String etaConf; // 'high' | 'med' | 'low' | ''
  final int stopsLeft;

  /// Moment this telemetry was received; live age = [ageSeconds] + time since.
  final DateTime receivedAt;

  BusVehicle({
    required this.id,
    required this.lat,
    required this.lon,
    required this.speed,
    required this.time,
    this.ageSeconds = 0,
    this.operator = '',
    this.plate = '',
    this.line = '',
    this.direction = '',
    this.directionName = '',
    this.headsign = '',
    this.bearing,
    this.destination = '',
    this.nextStop = '',
    this.nextStopEtaSec,
    this.nextStopDistM,
    this.etaAt,
    this.terminalEtaAt,
    this.etaConf = '',
    this.stopsLeft = 0,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  factory BusVehicle.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    final etaSec = (json['next_stop_eta_sec'] as num?)?.toInt();
    final termSec = (json['terminal_eta_sec'] as num?)?.toInt();
    final heading = (json['h'] as num?)?.toDouble() ?? (json['bearing'] as num?)?.toDouble();
    return BusVehicle(
      id: json['id']?.toString() ?? '',
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lon: (json['lon'] as num?)?.toDouble() ?? 0.0,
      speed: (json['s'] as num?)?.toDouble() ?? 0.0,
      time: json['t']?.toString() ?? json['time']?.toString() ?? '',
      ageSeconds: (json['a'] as num?)?.toInt() ?? 0,
      operator: json['op']?.toString() ?? '',
      plate: json['p']?.toString() ?? '',
      line: json['line']?.toString() ?? '',
      direction: json['dir']?.toString() ?? '',
      directionName: json['dir_name']?.toString() ?? '',
      headsign: json['headsign']?.toString() ?? '',
      bearing: heading,
      destination: json['destination']?.toString() ?? json['dest']?.toString() ?? '',
      nextStop: json['next_stop']?.toString() ?? json['stop']?.toString() ?? '',
      nextStopEtaSec: etaSec,
      nextStopDistM: (json['next_stop_dist_m'] as num?)?.toInt(),
      etaAt: etaSec == null ? null : now.add(Duration(seconds: etaSec)),
      terminalEtaAt: termSec == null ? null : now.add(Duration(seconds: termSec)),
      etaConf: json['eta_conf']?.toString() ?? '',
      stopsLeft: (json['stops_left'] as num?)?.toInt() ?? 0,
      receivedAt: now,
    );
  }

  BusVehicle copyWith({
    String? id,
    double? lat,
    double? lon,
    double? speed,
    String? time,
    int? ageSeconds,
    String? operator,
    String? plate,
    String? line,
    String? direction,
    String? directionName,
    String headsign = '',
    double? bearing,
    String? destination,
    String? nextStop,
    int? nextStopEtaSec,
    int? nextStopDistM,
    DateTime? etaAt,
    DateTime? terminalEtaAt,
    String? etaConf,
    int? stopsLeft,
  }) {
    return BusVehicle(
      id: id ?? this.id,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      speed: speed ?? this.speed,
      time: time ?? this.time,
      ageSeconds: ageSeconds ?? this.ageSeconds,
      operator: operator ?? this.operator,
      plate: plate ?? this.plate,
      line: line ?? this.line,
      direction: direction ?? this.direction,
      directionName: directionName ?? this.directionName,
      headsign: headsign.isNotEmpty ? headsign : this.headsign,
      bearing: bearing ?? this.bearing,
      destination: destination ?? this.destination,
      nextStop: nextStop ?? this.nextStop,
      nextStopEtaSec: nextStopEtaSec ?? this.nextStopEtaSec,
      nextStopDistM: nextStopDistM ?? this.nextStopDistM,
      etaAt: etaAt ?? this.etaAt,
      terminalEtaAt: terminalEtaAt ?? this.terminalEtaAt,
      etaConf: etaConf ?? this.etaConf,
      stopsLeft: stopsLeft ?? this.stopsLeft,
      receivedAt: receivedAt,
    );
  }

  /// Seconds until the next stop, recomputed from the absolute timestamp (null = unknown).
  int? etaSecondsAt(DateTime now) {
    if (etaAt != null) return math.max(0, etaAt!.difference(now).inSeconds);
    return null;
  }

  /// Age of the GPS fix right now (keeps counting between refreshes).
  int liveAgeSeconds(DateTime now) => ageSeconds + math.max(0, now.difference(receivedAt).inSeconds);

  static String formatEta(int? s) {
    if (s == null) return '';
    if (s <= 10) return 'Şimdi';
    if (s < 60) return '$s sn';
    final m = s ~/ 60;
    if (m < 10) return '$m dk ${(s % 60).toString().padLeft(2, '0')} sn';
    if (m < 90) return '$m dk';
    return '${m ~/ 60} sa ${m % 60} dk';
  }

  /// Human-readable next stop ETA (e.g. "45 sn", "2 dk", "Şimdi")
  String get nextStopEtaText {
    if (nextStopEtaSec == null) return '';
    final s = nextStopEtaSec!;
    if (s <= 10) return 'Varıyor / Şimdi';
    if (s < 60) return '$s sn sonra';
    final m = (s / 60).round();
    return '$m dk sonra';
  }

  // High-contrast and traffic speed scale matching the website
  Color get speedColor {
    if (speed <= 3) return const Color(0xFF64748B); // Stopped / Waiting (slate gray)
    if (speed < 15) return const Color(0xFFF59E0B); // Slow / Traffic (amber orange)
    return const Color(0xFF10B981); // Flowing fast (emerald green)
  }
}

class BusStop {
  final String code;
  final String name;
  final String district;
  final String direction;
  final double lat;
  final double lon;
  final int sequence;

  BusStop({
    required this.code,
    required this.name,
    this.district = '',
    this.direction = '',
    required this.lat,
    required this.lon,
    this.sequence = 0,
  });

  factory BusStop.fromJson(Map<String, dynamic> json) {
    return BusStop(
      code: json['code']?.toString() ?? json['c']?.toString() ?? '',
      name: json['name']?.toString() ?? json['n']?.toString() ?? '',
      district: json['district']?.toString() ?? json['d']?.toString() ?? '',
      direction: json['direction']?.toString() ?? json['y']?.toString() ?? '',
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lon: (json['lon'] as num?)?.toDouble() ?? 0.0,
      sequence: (json['seq'] as num?)?.toInt() ?? 0,
    );
  }
}

class LineDirectionRoute {
  final String code; // 'D' or 'G'
  final String name;
  final String origin;
  final String destination;
  final String headsign;
  final String colorHex;
  final List<BusStop> stops;
  List<List<double>> coordinates; // [[lat, lon], ...]
  bool hasRoadGeometry;

  LineDirectionRoute({
    required this.code,
    required this.name,
    required this.origin,
    required this.destination,
    required this.headsign,
    required this.colorHex,
    required this.stops,
    required this.coordinates,
    this.hasRoadGeometry = false,
  });

  factory LineDirectionRoute.fromJson(Map<String, dynamic> json) {
    final rawStops = (json['stops'] as List<dynamic>?) ?? [];
    final parsedStops = rawStops.map((s) => BusStop.fromJson(s as Map<String, dynamic>)).toList();

    final rawCoords = (json['coordinates'] as List<dynamic>?) ?? [];
    final parsedCoords = rawCoords.map((c) {
      if (c is List && c.length >= 2) {
        return [(c[0] as num).toDouble(), (c[1] as num).toDouble()];
      }
      return <double>[];
    }).where((c) => c.isNotEmpty).toList();

    return LineDirectionRoute(
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      origin: json['origin']?.toString() ?? '',
      destination: json['destination']?.toString() ?? '',
      headsign: json['headsign']?.toString() ?? '',
      colorHex: json['color']?.toString() ?? '#18181B',
      stops: parsedStops,
      coordinates: parsedCoords,
      hasRoadGeometry: json['has_road_geometry'] == true,
    );
  }
}

class LineRouteDetails {
  final String code;
  final String name;
  final Map<String, LineDirectionRoute> directions;
  final int totalStops;

  LineRouteDetails({
    required this.code,
    required this.name,
    required this.directions,
    required this.totalStops,
  });

  factory LineRouteDetails.fromJson(Map<String, dynamic> json) {
    final dirs = <String, LineDirectionRoute>{};
    if (json['directions'] is Map) {
      final map = json['directions'] as Map<String, dynamic>;
      map.forEach((k, v) {
        if (v is Map<String, dynamic>) {
          dirs[k] = LineDirectionRoute.fromJson(v);
        }
      });
    }

    return LineRouteDetails(
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      directions: dirs,
      totalStops: (json['total_stops'] as num?)?.toInt() ?? 0,
    );
  }
}

class MetroStation {
  final int id;
  final String name;
  final int order;
  final double lat;
  final double lon;
  final String lineCode;

  MetroStation({
    required this.id,
    required this.name,
    required this.order,
    required this.lat,
    required this.lon,
    required this.lineCode,
  });

  factory MetroStation.fromJson(Map<String, dynamic> json, String line) {
    return MetroStation(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      order: (json['order'] as num?)?.toInt() ?? 0,
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lon: (json['lon'] as num?)?.toDouble() ?? 0.0,
      lineCode: line,
    );
  }
}

/// Simulated 60 FPS Metro Train conforming to Istanbul Metro Kinematics
class MetroTrainVehicle {
  final String id;
  final String lineCode;
  final String systemType;
  final Color color;
  final List<MetroStation> stations;
  int dir; // 1: forward, -1: reverse
  int segIdx;
  double progress; // 0.0 to 1.0
  double currentSpeed; // km/h
  double currentAcc; // m/s²
  double accRate; // m/s²
  double decRate; // m/s²
  String specText;
  double currentLat;
  double currentLon;
  String state; // 'CRUISING', 'ACCELERATING', 'DECELERATING', 'AT_STATION'
  double dwellRemaining;
  double segDurationSec;
  double timeInSegSec;
  double maxSpeed;
  String targetStationName;
  String prevStationName;
  double remainingMeters;
  double etaSec;

  MetroTrainVehicle({
    required this.id,
    required this.lineCode,
    required this.systemType,
    required this.color,
    required this.stations,
    required this.dir,
    required this.segIdx,
    required this.progress,
    required this.currentSpeed,
    this.currentAcc = 0.0,
    this.accRate = 0.89,
    this.decRate = 1.04,
    this.specText = 'Standart Metro',
    required this.currentLat,
    required this.currentLon,
    this.state = 'CRUISING',
    this.dwellRemaining = 0,
    required this.segDurationSec,
    required this.timeInSegSec,
    required this.maxSpeed,
    required this.targetStationName,
    required this.prevStationName,
    this.remainingMeters = 0,
    this.etaSec = 0,
  });

  String get accDisplay {
    if (state == 'ACCELERATING') {
      final a = currentAcc > 0 ? currentAcc : accRate;
      return '+${a.toStringAsFixed(2)} m/s²';
    } else if (state == 'DECELERATING') {
      final d = currentAcc < 0 ? currentAcc : -decRate;
      return '${d.toStringAsFixed(2)} m/s²';
    } else if (state == 'AT_STATION') {
      return 'DURAKTA';
    }
    return '0.00 m/s²';
  }

  String get statusTitle {
    if (state == 'ACCELERATING') return 'Hızlanıyor';
    if (state == 'DECELERATING') return 'Yavaşlıyor / Fren';
    if (state == 'AT_STATION') return 'Durakta (Yolcu)';
    return 'Seyir Halinde';
  }

  String get statusIcon {
    if (state == 'ACCELERATING') return '🚀';
    if (state == 'DECELERATING') return '🛑';
    if (state == 'AT_STATION') return '⏸️';
    return '⚡';
  }

  Color get statusColor {
    if (state == 'ACCELERATING') return const Color(0xFF10B981);
    if (state == 'DECELERATING') return const Color(0xFFEF4444);
    if (state == 'AT_STATION') return const Color(0xFFF59E0B);
    return const Color(0xFF38BDF8);
  }

  String get arrowIcon {
    if (state == 'ACCELERATING') return '▲';
    if (state == 'DECELERATING') return '▼';
    if (state == 'AT_STATION') return '⏸';
    return '●';
  }

  String get etaShort {
    if (state == 'AT_STATION') {
      final s = dwellRemaining.ceil();
      return '${s < 0 ? 0 : s}s';
    }
    final sec = etaSec.ceil();
    if (sec < 60) return '${sec < 1 ? 1 : sec}s';
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m}d ${s.toString().padLeft(2, '0')}s';
  }

  String get etaFull {
    if (state == 'AT_STATION') {
      final s = dwellRemaining.ceil();
      return 'Kalkışa ${s < 0 ? 0 : s} sn';
    }
    final sec = etaSec.ceil();
    if (sec < 60) return '${sec < 1 ? 1 : sec} sn sonra';
    final m = sec ~/ 60;
    final s = sec % 60;
    return '$m dk ${s.toString().padLeft(2, '0')} sn sonra';
  }

  String get arrivalClock {
    final arrivalSec = state == 'AT_STATION' ? dwellRemaining.ceil() : etaSec.ceil();
    final arrivalDate = DateTime.now().add(Duration(seconds: arrivalSec < 0 ? 0 : arrivalSec));
    final h = arrivalDate.hour.toString().padLeft(2, '0');
    final m = arrivalDate.minute.toString().padLeft(2, '0');
    final s = arrivalDate.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class LineInfo {
  final String code;
  final String desc;
  final String type; // 'bus', 'metrobus', 'express', 'metro', 'tram', 'funicular'

  const LineInfo({
    required this.code,
    required this.desc,
    this.type = 'bus',
  });

  factory LineInfo.fromJson(Map<String, dynamic> json) {
    return LineInfo(
      code: json['code']?.toString() ?? '',
      desc: json['desc']?.toString() ?? json['name']?.toString() ?? '',
      type: json['type']?.toString() ?? 'bus',
    );
  }

  Map<String, dynamic> toJson() => {
    'code': code,
    'desc': desc,
    'type': type,
  };
}

class NearbyBusLine {
  final String lineCode;
  final int busCount;
  final double distanceMeters;

  const NearbyBusLine({
    required this.lineCode,
    required this.busCount,
    required this.distanceMeters,
  });
}

class TimetableEntry {
  final String time; // "HH:mm" e.g. "07:15"
  final String direction; // 'D' or 'G'
  final String dayType; // 'I' (İş Günü), 'C' (Cumartesi), 'P' (Pazar)
  final String serviceType; // e.g. "ÖHO", "İETT", "Normal"
  final String? routeSign;
  final bool estimated;

  const TimetableEntry({
    required this.time,
    required this.direction,
    required this.dayType,
    this.serviceType = 'Normal',
    this.routeSign,
    this.estimated = false,
  });

  factory TimetableEntry.fromJson(Map<String, dynamic> json) {
    return TimetableEntry(
      time: json['time']?.toString() ?? json['DT']?.toString() ?? json['saat']?.toString() ?? '',
      direction: json['direction']?.toString() ?? json['SYON']?.toString() ?? json['yon']?.toString() ?? 'D',
      dayType: json['day_type']?.toString() ?? json['SGUNTIPI']?.toString() ?? json['gun']?.toString() ?? 'I',
      serviceType: json['service_type']?.toString() ?? json['SSERVISTIPI']?.toString() ?? 'Normal',
      routeSign: json['route_sign']?.toString() ?? json['GUZERGAH_ISARETI']?.toString(),
      estimated: json['estimated'] == true,
    );
  }

  /// Next occurrence of this departure today (Istanbul wall clock == device clock for users there).
  DateTime todayAt([DateTime? now]) {
    final n = now ?? DateTime.now();
    final parts = time.split(':');
    final h = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return DateTime(n.year, n.month, n.day, h, m);
  }

  Map<String, dynamic> toJson() => {
    'time': time,
    'direction': direction,
    'day_type': dayType,
    'service_type': serviceType,
    if (routeSign != null) 'route_sign': routeSign,
  };

  /// Returns true if this departure is in the future relative to now
  bool isUpcoming([DateTime? now]) {
    final current = now ?? DateTime.now();
    final parts = time.split(':');
    if (parts.length < 2) return false;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final currentMinutes = current.hour * 60 + current.minute;
    final departureMinutes = h * 60 + m;
    return departureMinutes >= currentMinutes;
  }
}

class LineTimetable {
  final String lineCode;
  final List<TimetableEntry> entries;
  final bool isMetro;
  final String? note;

  /// true only when the schedule comes from the official İBB / Metro İstanbul feed.
  final bool official;
  final String source;

  const LineTimetable({
    required this.lineCode,
    required this.entries,
    this.isMetro = false,
    this.note,
    this.official = false,
    this.source = '',
  });

  bool get isEstimated => !official || entries.any((e) => e.estimated);

  factory LineTimetable.fromJson(Map<String, dynamic> json) {
    final rawEntries = (json['entries'] as List<dynamic>?) ?? [];
    return LineTimetable(
      lineCode: json['line_code']?.toString() ?? '',
      entries: rawEntries.map((e) => TimetableEntry.fromJson(e as Map<String, dynamic>)).toList(),
      isMetro: json['is_metro'] == true,
      note: json['note']?.toString(),
      official: json['official'] == true,
      source: json['source']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'line_code': lineCode,
    'entries': entries.map((e) => e.toJson()).toList(),
    'is_metro': isMetro,
    if (note != null) 'note': note,
  };

  List<TimetableEntry> filter({String? direction, String? dayType}) {
    return entries.where((e) {
      if (direction != null && direction != 'ALL' && e.direction != direction) {
        return false;
      }
      if (dayType != null && e.dayType != dayType) {
        return false;
      }
      return true;
    }).toList();
  }
}



/// One predicted arrival at a bus stop (from `/stop/arrivals` or the local engine).
class StopArrival {
  final String line;
  final String busId;
  final String headsign;
  final double speed;
  final int distM;
  final int stopsAway;
  final DateTime etaAt;
  final String conf;

  const StopArrival({
    required this.line,
    required this.busId,
    required this.headsign,
    required this.speed,
    required this.distM,
    required this.stopsAway,
    required this.etaAt,
    this.conf = '',
  });

  factory StopArrival.fromJson(Map<String, dynamic> j, DateTime now) {
    final sec = (j['eta_sec'] as num?)?.toInt() ?? 0;
    return StopArrival(
      line: j['line']?.toString() ?? '',
      busId: j['bus_id']?.toString() ?? '',
      headsign: j['headsign']?.toString() ?? '',
      speed: (j['speed'] as num?)?.toDouble() ?? 0,
      distM: (j['dist_m'] as num?)?.toInt() ?? 0,
      stopsAway: (j['stops_away'] as num?)?.toInt() ?? 0,
      etaAt: now.add(Duration(seconds: sec)),
      conf: j['conf']?.toString() ?? '',
    );
  }
}

/// City-wide live traffic summary derived server-side from fleet probe speeds.
class TrafficSummary {
  final String level; // akici | yogun | cok_yogun
  final double medianMovingKmh;
  final double hourPriorKmh;
  final int vehicles;

  const TrafficSummary({
    required this.level,
    required this.medianMovingKmh,
    required this.hourPriorKmh,
    required this.vehicles,
  });

  static TrafficSummary? fromJson(dynamic j) {
    if (j is! Map) return null;
    return TrafficSummary(
      level: j['level']?.toString() ?? 'akici',
      medianMovingKmh: (j['median_moving_kmh'] as num?)?.toDouble() ?? 0,
      hourPriorKmh: (j['hour_prior_kmh'] as num?)?.toDouble() ?? 0,
      vehicles: (j['vehicles'] as num?)?.toInt() ?? 0,
    );
  }

  String get label => level == 'akici' ? 'Akıcı' : (level == 'yogun' ? 'Yoğun' : 'Çok yoğun');

  /// >1 faster than typical for this hour, <1 slower.
  double get ratio {
    if (hourPriorKmh <= 0 || medianMovingKmh <= 0) return 1;
    return (medianMovingKmh / hourPriorKmh).clamp(0.5, 1.3);
  }
}
