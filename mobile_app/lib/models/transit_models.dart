import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'rail_models.dart';

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

  /// Smoothly interpolated & dead-reckoned position rendered on the map (prevents 10s poll jumps).
  double displayLat;
  double displayLon;
  double? displayBearing;
  double _startLat;
  double _startLon;
  double _targetLat;
  double _targetLon;
  DateTime _animStartAt;
  double _animDurationSec;

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
    double? displayLat,
    double? displayLon,
    double? displayBearing,
  })  : receivedAt = receivedAt ?? DateTime.now(),
        displayLat = displayLat ?? lat,
        displayLon = displayLon ?? lon,
        displayBearing = displayBearing ?? bearing,
        _startLat = displayLat ?? lat,
        _startLon = displayLon ?? lon,
        _targetLat = lat,
        _targetLon = lon,
        _animStartAt = receivedAt ?? DateTime.now(),
        _animDurationSec = 10.5 {
    _initDefaultLead();
  }

  void _initDefaultLead() {
    if (speed > 2.5 && bearing != null && _targetLat == lat && _targetLon == lon) {
      final leadM = (math.min(speed, 48.0) / 3.6 * 6.5).clamp(0.0, 55.0);
      final rad = bearing! * math.pi / 180.0;
      _targetLat = lat + (leadM * math.cos(rad)) / 110540.0;
      _targetLon = lon + (leadM * math.sin(rad)) / (111320.0 * math.cos(lat * math.pi / 180.0));
    }
  }

  /// Smoothly transitions from [prev]'s current rendered position to the new telemetry fix without jumping.
  void inheritSmoothMotionFrom(BusVehicle prev, DateTime now) {
    prev.stepDisplayPosition(now);
    displayLat = prev.displayLat;
    displayLon = prev.displayLon;
    _startLat = prev.displayLat;
    _startLon = prev.displayLon;
    _animStartAt = now;
    _animDurationSec = 10.5;

    final kx = 111320.0 * math.cos(lat * math.pi / 180.0);
    const ky = 110540.0;
    final rawDx = (lon - prev.lon) * kx;
    final rawDy = (lat - prev.lat) * ky;
    final rawMoveM = math.sqrt(rawDx * rawDx + rawDy * rawDy);

    if (rawMoveM > 1.8 && rawMoveM < 1200.0) {
      // GPS fix advanced: glide from current rendered position to the new GPS point + gentle velocity lead
      final moveBearingRad = math.atan2(rawDx, rawDy);
      final moveBearingDeg = (moveBearingRad * 180.0 / math.pi + 360.0) % 360.0;
      displayBearing = bearing ?? moveBearingDeg;
      final leadM = speed > 3.0 ? math.min(35.0, rawMoveM * 0.25) : 0.0;
      _targetLat = lat + (leadM * math.cos(moveBearingRad)) / ky;
      _targetLon = lon + (leadM * math.sin(moveBearingRad)) / kx;
    } else {
      // Same GPS fix in this poll: preserve previous smooth trajectory or dead-reckon softly
      displayBearing = bearing ?? prev.displayBearing;
      final driftDx = (prev._targetLon - lon) * kx;
      final driftDy = (prev._targetLat - lat) * ky;
      final driftM = math.sqrt(driftDx * driftDx + driftDy * driftDy);
      if (speed > 3.5 && displayBearing != null && driftM < 65.0) {
        final stepM = (math.min(speed, 42.0) / 3.6 * 4.5).clamp(0.0, 42.0);
        final rad = displayBearing! * math.pi / 180.0;
        _targetLat = displayLat + (stepM * math.cos(rad)) / ky;
        _targetLon = displayLon + (stepM * math.sin(rad)) / kx;
      } else {
        _targetLat = prev._targetLat;
        _targetLon = prev._targetLon;
      }
    }
  }

  /// Advances [displayLat] and [displayLon] at 20–60 FPS along the active segment.
  void stepDisplayPosition(DateTime now) {
    final elapsed = now.difference(_animStartAt).inMicroseconds / 1e6;
    if (elapsed <= 0) return;
    final u = (elapsed / _animDurationSec).clamp(0.0, 1.0);
    // C1 continuous velocity profile: constant velocity through 82% of the interval, soft ease-out tail
    final s = u < 0.82 ? u : 0.82 + 0.18 * (1.0 - math.pow(1.0 - (u - 0.82) / 0.18, 2));
    displayLat = _startLat + (_targetLat - _startLat) * s;
    displayLon = _startLon + (_targetLon - _startLon) * s;
  }

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
    final out = BusVehicle(
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
      displayLat: displayLat,
      displayLon: displayLon,
      displayBearing: displayBearing,
    );
    out._startLat = _startLat;
    out._startLon = _startLon;
    out._targetLat = _targetLat;
    out._targetLon = _targetLon;
    out._animStartAt = _animStartAt;
    out._animDurationSec = _animDurationSec;
    return out;
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

/// A train placed on the map from its line's timetable (see `rail_engine.dart`), with the
/// accelerate / cruise / brake phase of the current station-to-station run.
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

  /// Terminus of this trip (short-turns end mid-line).
  final String headsign;
  final String dirCode; // 'G' | 'D'
  final double bearing;
  final List<RailStopCall> upcoming;

  /// True when positions come from the official Metro İstanbul timetable.
  final bool official;
  final String source;

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
    this.headsign = '',
    this.dirCode = '',
    this.bearing = 0,
    this.upcoming = const [],
    this.official = false,
    this.source = '',
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
  final String plate;
  final bool haveWifi;
  final bool haveUsb;
  final bool haveAccessibility;
  final bool haveAir;
  final bool haveBicycle;

  const StopArrival({
    required this.line,
    required this.busId,
    required this.headsign,
    required this.speed,
    required this.distM,
    required this.stopsAway,
    required this.etaAt,
    this.conf = '',
    this.plate = '',
    this.haveWifi = false,
    this.haveUsb = true,
    this.haveAccessibility = true,
    this.haveAir = true,
    this.haveBicycle = false,
  });

  factory StopArrival.fromJson(Map<String, dynamic> j, DateTime now) {
    int sec = (j['eta_sec'] as num?)?.toInt() ?? 0;
    if (sec == 0) {
      final minVal = (j['minute'] as num?)?.toInt() ?? (j['Minute'] as num?)?.toInt();
      if (minVal != null) {
        sec = minVal * 60;
      }
    }
    return StopArrival(
      line: (j['line'] ?? j['lineCode'] ?? j['LineCode'] ?? '').toString(),
      busId: (j['bus_id'] ?? j['doorNumber'] ?? j['DoorNumber'] ?? '').toString(),
      headsign: (j['headsign'] ?? j['lineType'] ?? j['LineType'] ?? '').toString(),
      speed: (j['speed'] as num?)?.toDouble() ?? 0,
      distM: (j['dist_m'] as num?)?.toInt() ?? 0,
      stopsAway: (j['stops_away'] as num?)?.toInt() ?? 0,
      etaAt: now.add(Duration(seconds: sec)),
      conf: j['conf']?.toString() ?? '',
      plate: (j['plate'] ?? j['Plate'] ?? '').toString(),
      haveWifi: j['haveWifi'] == 1 || j['HaveWifi'] == 1 || j['have_wifi'] == true,
      haveUsb: j['haveUsb'] == 1 || j['HaveUsb'] == 1 || j['have_usb'] == true || true,
      haveAccessibility: j['haveAccessibility'] == 1 || j['HaveAccessibility'] == 1 || j['have_accessibility'] == true || true,
      haveAir: j['haveAir'] == 1 || j['HaveAir'] == 1 || j['have_air'] == true || true,
      haveBicycle: j['haveBicycle'] == 1 || j['HaveBicycle'] == 1 || j['have_bicycle'] == true,
    );
  }

  int get distanceMeters => distM;

  int etaMinutes(DateTime now) {
    final s = math.max(0, etaAt.difference(now).inSeconds);
    return math.max(1, (s / 60).round());
  }

  bool isImminent(DateTime now) {
    return math.max(0, etaAt.difference(now).inSeconds) <= 180;
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
