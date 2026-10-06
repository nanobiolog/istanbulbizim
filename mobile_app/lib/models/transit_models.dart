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
  });

  factory BusVehicle.fromJson(Map<String, dynamic> json) {
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
      bearing: (json['bearing'] as num?)?.toDouble(),
    );
  }

  // Black and white high-contrast speed indication
  Color get speedColor {
    if (speed <= 3) return const Color(0xFF71717A); // Stopped / Waiting (zinc/gray)
    if (speed < 15) return const Color(0xFF3F3F46); // Slow / Traffic (dark zinc)
    return const Color(0xFF18181B); // Moving (solid black/near black)
  }
}

class BusStop {
  final String code;
  final String name;
  final String district;
  final double lat;
  final double lon;
  final int sequence;

  BusStop({
    required this.code,
    required this.name,
    this.district = '',
    required this.lat,
    required this.lon,
    this.sequence = 0,
  });

  factory BusStop.fromJson(Map<String, dynamic> json) {
    return BusStop(
      code: json['code']?.toString() ?? json['c']?.toString() ?? '',
      name: json['name']?.toString() ?? json['n']?.toString() ?? '',
      district: json['district']?.toString() ?? json['d']?.toString() ?? '',
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
  double currentLat;
  double currentLon;
  String state; // 'CRUISING', 'ACCELERATING', 'DECELERATING', 'AT_STATION'
  double dwellRemaining;
  double segDurationSec;
  double timeInSegSec;
  double maxSpeed;
  String targetStationName;
  String prevStationName;

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
    required this.currentLat,
    required this.currentLon,
    this.state = 'CRUISING',
    this.dwellRemaining = 0,
    required this.segDurationSec,
    required this.timeInSegSec,
    required this.maxSpeed,
    required this.targetStationName,
    required this.prevStationName,
  });
}
