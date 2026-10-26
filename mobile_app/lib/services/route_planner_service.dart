import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/network_models.dart';
import '../services/transit_provider.dart';

enum RouteTimeMode {
  now,
  departAt,
  arriveBy;

  String get apiValue {
    switch (this) {
      case RouteTimeMode.now:
        return 'now';
      case RouteTimeMode.departAt:
        return 'dep';
      case RouteTimeMode.arriveBy:
        return 'arr';
    }
  }

  String get label {
    switch (this) {
      case RouteTimeMode.now:
        return 'Şimdi';
      case RouteTimeMode.departAt:
        return 'Kalkış Zamanı';
      case RouteTimeMode.arriveBy:
        return 'Varış Zamanı';
    }
  }
}

class PlannedPoint {
  final String name;
  final double lat;
  final double lon;
  final String subtitle;
  final String kind; // 'gps', 'station', 'pier', 'bus_stop', 'map'

  const PlannedPoint({
    required this.name,
    required this.lat,
    required this.lon,
    this.subtitle = '',
    this.kind = 'map',
  });

  LatLng get latLng => LatLng(lat, lon);
}

class RouteLegStop {
  final String name;
  final String code;
  final double lat;
  final double lon;
  final String time;

  const RouteLegStop({
    required this.name,
    this.code = '',
    required this.lat,
    required this.lon,
    this.time = '',
  });

  factory RouteLegStop.fromJson(Map<String, dynamic> j) {
    return RouteLegStop(
      name: (j['name'] ?? '').toString(),
      code: (j['code'] ?? '').toString(),
      lat: (j['lat'] as num?)?.toDouble() ?? 0.0,
      lon: (j['lon'] as num?)?.toDouble() ?? 0.0,
      time: (j['time'] ?? '').toString(),
    );
  }
}

class RouteLegLiveBus {
  final String door;
  final int speed;
  final int etaMin;
  final int distM;

  const RouteLegLiveBus({
    required this.door,
    required this.speed,
    required this.etaMin,
    required this.distM,
  });

  factory RouteLegLiveBus.fromJson(Map<String, dynamic> j) {
    return RouteLegLiveBus(
      door: (j['door'] ?? '').toString(),
      speed: (j['speed'] as num?)?.round() ?? 0,
      etaMin: (j['eta_min'] as num?)?.round() ?? 0,
      distM: (j['dist_m'] as num?)?.round() ?? 0,
    );
  }
}

class PlannedRouteLeg {
  final String type; // 'walk', 'bus', 'metrobus', 'rail', 'ferry'
  final String lineCode;
  final String lineName;
  final String direction;
  final String operatorName;
  final String colorHex;
  final String fromName;
  final String toName;
  final double fromLat;
  final double fromLon;
  final double toLat;
  final double toLon;
  final int depMin;
  final int arrMin;
  final String depTime;
  final String arrTime;
  final int durationMin;
  final int distanceM;
  final int stopsCount;
  final List<RouteLegStop> stops;
  final List<LatLng> coords;
  final RouteLegLiveBus? liveBus;
  final String scheduleNote;

  const PlannedRouteLeg({
    required this.type,
    this.lineCode = '',
    this.lineName = '',
    this.direction = '',
    this.operatorName = '',
    this.colorHex = '#64748B',
    required this.fromName,
    required this.toName,
    required this.fromLat,
    required this.fromLon,
    required this.toLat,
    required this.toLon,
    required this.depMin,
    required this.arrMin,
    required this.depTime,
    required this.arrTime,
    required this.durationMin,
    this.distanceM = 0,
    this.stopsCount = 0,
    this.stops = const [],
    this.coords = const [],
    this.liveBus,
    this.scheduleNote = '',
  });

  Color get color {
    final clean = colorHex.replaceFirst('#', '').trim();
    if (clean.length == 6) {
      final v = int.tryParse('FF$clean', radix: 16);
      if (v != null) return Color(v);
    }
    switch (type) {
      case 'metrobus':
        return const Color(0xFFE11D48);
      case 'bus':
        return const Color(0xFF0EA5E9);
      case 'ferry':
        return const Color(0xFF0284C7);
      case 'rail':
        return const Color(0xFF8B5CF6);
      default:
        return const Color(0xFF64748B);
    }
  }

  IconData get icon {
    switch (type) {
      case 'walk':
        return Icons.directions_walk_rounded;
      case 'ferry':
        return Icons.directions_boat_filled_rounded;
      case 'rail':
        return Icons.train_rounded;
      case 'metrobus':
      case 'bus':
      default:
        return Icons.directions_bus_rounded;
    }
  }

  String get modeLabel {
    switch (type) {
      case 'walk':
        return 'Yürüyüş';
      case 'ferry':
        return operatorName.isNotEmpty ? operatorName : 'Vapur / Deniz';
      case 'metrobus':
        return 'Metrobüs';
      case 'rail':
        return lineCode == 'B1' ? 'Marmaray' : 'Metro / Raylı';
      case 'bus':
      default:
        return 'İETT Otobüs';
    }
  }

  factory PlannedRouteLeg.fromJson(Map<String, dynamic> j) {
    final from = j['from'] is Map ? (j['from'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final to = j['to'] is Map ? (j['to'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final rawStops = (j['stops'] as List?) ?? const [];
    final rawCoords = (j['coords'] as List?) ?? const [];
    final parsedCoords = <LatLng>[];
    for (final c in rawCoords) {
      if (c is List && c.length >= 2) {
        final lat = (c[0] as num?)?.toDouble();
        final lon = (c[1] as num?)?.toDouble();
        if (lat != null && lon != null) parsedCoords.add(LatLng(lat, lon));
      }
    }
    final fLat = (from['lat'] as num?)?.toDouble() ?? 0.0;
    final fLon = (from['lon'] as num?)?.toDouble() ?? 0.0;
    final tLat = (to['lat'] as num?)?.toDouble() ?? 0.0;
    final tLon = (to['lon'] as num?)?.toDouble() ?? 0.0;
    if (parsedCoords.length < 2 && fLat != 0 && tLat != 0) {
      parsedCoords
        ..clear()
        ..add(LatLng(fLat, fLon))
        ..add(LatLng(tLat, tLon));
    }

    return PlannedRouteLeg(
      type: (j['type'] ?? 'walk').toString(),
      lineCode: (j['line_code'] ?? '').toString(),
      lineName: (j['line_name'] ?? '').toString(),
      direction: (j['direction'] ?? '').toString(),
      operatorName: (j['operator'] ?? '').toString(),
      colorHex: (j['color'] ?? '#64748B').toString(),
      fromName: (from['name'] ?? '').toString(),
      toName: (to['name'] ?? '').toString(),
      fromLat: fLat,
      fromLon: fLon,
      toLat: tLat,
      toLon: tLon,
      depMin: (j['dep_min'] as num?)?.round() ?? 0,
      arrMin: (j['arr_min'] as num?)?.round() ?? 0,
      depTime: (j['dep_time'] ?? '').toString(),
      arrTime: (j['arr_time'] ?? '').toString(),
      durationMin: (j['duration_min'] as num?)?.round() ?? 0,
      distanceM: (j['distance_m'] as num?)?.round() ?? 0,
      stopsCount: (j['stops_count'] as num?)?.round() ?? 0,
      stops: rawStops.whereType<Map>().map((s) => RouteLegStop.fromJson(s.cast<String, dynamic>())).toList(),
      coords: parsedCoords,
      liveBus: j['live_bus'] is Map ? RouteLegLiveBus.fromJson((j['live_bus'] as Map).cast<String, dynamic>()) : null,
      scheduleNote: (j['schedule_note'] ?? '').toString(),
    );
  }
}

class PlannedItinerary {
  final String id;
  final String tag;
  final int depMin;
  final int arrMin;
  final String depTime;
  final String arrTime;
  final int totalMinutes;
  final int walkMinutes;
  final int transfers;
  final List<String> modes;
  final List<PlannedRouteLeg> legs;

  const PlannedItinerary({
    required this.id,
    required this.tag,
    required this.depMin,
    required this.arrMin,
    required this.depTime,
    required this.arrTime,
    required this.totalMinutes,
    required this.walkMinutes,
    required this.transfers,
    required this.modes,
    required this.legs,
  });

  factory PlannedItinerary.fromJson(Map<String, dynamic> j) {
    final summary = j['summary'] is Map ? (j['summary'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final rawLegs = (j['legs'] as List?) ?? const [];
    final rawModes = (summary['modes'] as List?) ?? const [];
    return PlannedItinerary(
      id: (j['id'] ?? '').toString(),
      tag: (j['tag'] ?? 'Önerilen').toString(),
      depMin: (j['dep_min'] as num?)?.round() ?? 0,
      arrMin: (j['arr_min'] as num?)?.round() ?? 0,
      depTime: (j['dep_time'] ?? '').toString(),
      arrTime: (j['arr_time'] ?? '').toString(),
      totalMinutes: (summary['total_minutes'] as num?)?.round() ?? 0,
      walkMinutes: (summary['walk_minutes'] as num?)?.round() ?? 0,
      transfers: (summary['transfers'] as num?)?.round() ?? 0,
      modes: rawModes.map((e) => e.toString()).toList(),
      legs: rawLegs.whereType<Map>().map((l) => PlannedRouteLeg.fromJson(l.cast<String, dynamic>())).toList(),
    );
  }
}

class RoutePlanResult {
  final bool ok;
  final String? error;
  final String mode;
  final String dateStr;
  final String dayType;
  final String dayLabel;
  final String anchorTime;
  final int? trafficIndex;
  final List<PlannedItinerary> itineraries;

  const RoutePlanResult({
    required this.ok,
    this.error,
    this.mode = 'now',
    this.dateStr = '',
    this.dayType = 'I',
    this.dayLabel = 'İş Günü (Hafta İçi)',
    this.anchorTime = '',
    this.trafficIndex,
    this.itineraries = const [],
  });

  factory RoutePlanResult.fromJson(Map<String, dynamic> j) {
    final query = j['query'] is Map ? (j['query'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final rawIts = (j['itineraries'] as List?) ?? const [];
    return RoutePlanResult(
      ok: j['ok'] == true,
      error: j['error']?.toString(),
      mode: (query['mode'] ?? 'now').toString(),
      dateStr: (query['date'] ?? '').toString(),
      dayType: (query['day_type'] ?? 'I').toString(),
      dayLabel: (query['day_label'] ?? 'İş Günü').toString(),
      anchorTime: (query['anchor_time'] ?? '').toString(),
      trafficIndex: (query['traffic_index'] as num?)?.round(),
      itineraries: rawIts.whereType<Map>().map((it) => PlannedItinerary.fromJson(it.cast<String, dynamic>())).toList(),
    );
  }
}

class RoutePlannerService {
  static final http.Client _client = http.Client();

  static String _fmtMin(int m) {
    final norm = ((m % 1440) + 1440) % 1440;
    final hh = (norm ~/ 60).toString().padLeft(2, '0');
    final mm = (norm % 60).toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  static Future<RoutePlanResult> planRoute({
    required TransitProvider provider,
    required PlannedPoint from,
    required PlannedPoint to,
    required RouteTimeMode timeMode,
    required DateTime selectedDate,
    required TimeOfDay selectedTime,
  }) async {
    final dateStr =
        '${selectedDate.year.toString().padLeft(4, '0')}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}';

    // 1. Try server-side multi-modal engine (/route/plan)
    try {
      final uri = Uri.parse('${provider.api.baseUrl}/route/plan').replace(
        queryParameters: {
          'fromLat': from.lat.toStringAsFixed(6),
          'fromLon': from.lon.toStringAsFixed(6),
          'fromName': from.name,
          'toLat': to.lat.toStringAsFixed(6),
          'toLon': to.lon.toStringAsFixed(6),
          'toName': to.name,
          'mode': timeMode.apiValue,
          'date': dateStr,
          'time': timeStr,
        },
      );
      final res = await _client.get(uri, headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map<String, dynamic>) {
          final parsed = RoutePlanResult.fromJson(data);
          if (parsed.ok && parsed.itineraries.isNotEmpty) {
            return parsed;
          }
        }
      }
    } catch (_) {}

    // 2. Local offline fallback using loaded rail & ferry network
    return _planLocalFallback(
      provider: provider,
      from: from,
      to: to,
      timeMode: timeMode,
      selectedDate: selectedDate,
      selectedTime: selectedTime,
      dateStr: dateStr,
      timeStr: timeStr,
    );
  }

  static RoutePlanResult _planLocalFallback({
    required TransitProvider provider,
    required PlannedPoint from,
    required PlannedPoint to,
    required RouteTimeMode timeMode,
    required DateTime selectedDate,
    required TimeOfDay selectedTime,
    required String dateStr,
    required String timeStr,
  }) {
    final net = provider.network;
    final wd = selectedDate.weekday; // 1=Mon..7=Sun
    final dayType = wd == 7 ? 'P' : (wd == 6 ? 'C' : 'I');
    final dayLabel = wd == 7
        ? 'Pazar Tarifesi'
        : (wd == 6 ? 'Cumartesi Tarifesi' : 'İş Günü (Hafta İçi)');

    final now = DateTime.now();
    final anchorMin = timeMode == RouteTimeMode.now
        ? (now.hour * 60 + now.minute)
        : (selectedTime.hour * 60 + selectedTime.minute);
    final queryWhen = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      anchorMin ~/ 60,
      anchorMin % 60,
    );

    final directDist = haversine(from.lat, from.lon, to.lat, to.lon);
    if (directDist < 90) {
      return const RoutePlanResult(
        ok: false,
        error: 'Kalkış ve varış noktaları birbirine çok yakın.',
      );
    }

    final candidates = <PlannedItinerary>[];

    // Check direct walk if < 2200m
    if (directDist <= 2000) {
      final int walkMin = math.max<int>(1, (directDist * 1.28 / 78.0).round());
      final int depM = timeMode == RouteTimeMode.arriveBy ? anchorMin - walkMin : anchorMin;
      final int arrM = depM + walkMin;
      candidates.add(
        PlannedItinerary(
          id: 'walk-direct',
          tag: 'Yürüyüş',
          depMin: depM,
          arrMin: arrM,
          depTime: _fmtMin(depM),
          arrTime: _fmtMin(arrM),
          totalMinutes: walkMin,
          walkMinutes: walkMin,
          transfers: 0,
          modes: const ['walk'],
          legs: [
            PlannedRouteLeg(
              type: 'walk',
              fromName: from.name,
              toName: to.name,
              fromLat: from.lat,
              fromLon: from.lon,
              toLat: to.lat,
              toLon: to.lon,
              depMin: depM,
              arrMin: arrM,
              depTime: _fmtMin(depM),
              arrTime: _fmtMin(arrM),
              durationMin: walkMin,
              distanceM: (directDist * 1.25).round(),
              coords: [from.latLng, to.latLng],
            ),
          ],
        ),
      );
    }

    // Find nearby rail stations to origin & destination
    final startStations = net.stations.values
        .map((s) => (st: s, d: haversine(from.lat, from.lon, s.pos.latitude, s.pos.longitude)))
        .where((e) => e.d <= 2200)
        .toList()
      ..sort((a, b) => a.d.compareTo(b.d));

    final endStations = net.stations.values
        .map((s) => (st: s, d: haversine(to.lat, to.lon, s.pos.latitude, s.pos.longitude)))
        .where((e) => e.d <= 2200)
        .toList()
      ..sort((a, b) => a.d.compareTo(b.d));

    // Direct 1-leg rail routes
    for (final sA in startStations.take(8)) {
      for (final sB in endStations.take(8)) {
        if (sA.st.id == sB.st.id) continue;
        for (final code in sA.st.lines) {
          if (!sB.st.lines.contains(code)) continue;
          final line = net.lineByCode[code];
          if (line == null || line.variants.isEmpty) continue;
          final v = line.variants.first;
          final idxA = v.indexOfStation(sA.st.id);
          final idxB = v.indexOfStation(sB.st.id);
          if (idxA < 0 || idxB < 0 || idxA == idxB) continue;

          final int walk1Min = math.max<int>(1, (sA.d * 1.25 / 78.0).round());
          final int walk2Min = math.max<int>(1, (sB.d * 1.25 / 78.0).round());
          final int stopDiff = (idxB - idxA).abs();
          final int rideMin = math.max<int>(2, (stopDiff * 2.1).round());
          const int waitMin = 4;

          final int totalMin = walk1Min + waitMin + rideMin + walk2Min;
          final int depM = timeMode == RouteTimeMode.arriveBy ? anchorMin - totalMin : anchorMin;
          final int boardM = depM + walk1Min + waitMin;
          final int alightM = boardM + rideMin;
          final int arrM = alightM + walk2Min;

          final headsign = idxB > idxA ? v.to : v.from;
          final allStopIds = v.stops.map((s) => s.stationId).toList();
          final stepIds = idxB > idxA
              ? allStopIds.sublist(idxA, idxB + 1)
              : allStopIds.sublist(idxB, idxA + 1).reversed.toList();
          final legStops = <RouteLegStop>[];
          final legCoords = <LatLng>[];
          for (var i = 0; i < stepIds.length; i++) {
            final st = net.stations[stepIds[i]];
            if (st == null) continue;
            final int tMin = boardM + ((rideMin * i) / math.max<int>(1, stepIds.length - 1)).round();
            legStops.add(RouteLegStop(
              name: st.name,
              code: st.id,
              lat: st.pos.latitude,
              lon: st.pos.longitude,
              time: _fmtMin(tMin),
            ));
            legCoords.add(st.pos);
          }

          final hex = '#${line.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
          final legs = <PlannedRouteLeg>[
            if (sA.d > 45)
              PlannedRouteLeg(
                type: 'walk',
                fromName: from.name,
                toName: '${sA.st.name} İstasyonu',
                fromLat: from.lat,
                fromLon: from.lon,
                toLat: sA.st.pos.latitude,
                toLon: sA.st.pos.longitude,
                depMin: depM,
                arrMin: depM + walk1Min,
                depTime: _fmtMin(depM),
                arrTime: _fmtMin(depM + walk1Min),
                durationMin: walk1Min,
                distanceM: (sA.d * 1.25).round(),
                coords: [from.latLng, sA.st.pos],
              ),
            PlannedRouteLeg(
              type: 'rail',
              lineCode: line.code,
              lineName: line.name,
              direction: '$headsign Yönü',
              operatorName: line.code == 'B1' ? 'TCDD Marmaray' : 'Metro İstanbul',
              colorHex: hex,
              fromName: sA.st.name,
              toName: sB.st.name,
              fromLat: sA.st.pos.latitude,
              fromLon: sA.st.pos.longitude,
              toLat: sB.st.pos.latitude,
              toLon: sB.st.pos.longitude,
              depMin: boardM,
              arrMin: alightM,
              depTime: _fmtMin(boardM),
              arrTime: _fmtMin(alightM),
              durationMin: rideMin,
              stopsCount: stopDiff,
              stops: legStops,
              coords: legCoords,
              scheduleNote: 'Her ${waitMin * 2} dk',
            ),
            if (sB.d > 45)
              PlannedRouteLeg(
                type: 'walk',
                fromName: '${sB.st.name} İstasyonu',
                toName: to.name,
                fromLat: sB.st.pos.latitude,
                fromLon: sB.st.pos.longitude,
                toLat: to.lat,
                toLon: to.lon,
                depMin: alightM,
                arrMin: arrM,
                depTime: _fmtMin(alightM),
                arrTime: _fmtMin(arrM),
                durationMin: walk2Min,
                distanceM: (sB.d * 1.25).round(),
                coords: [sB.st.pos, to.latLng],
              ),
          ];

          candidates.add(
            PlannedItinerary(
              id: 'rail-${line.code}-${sA.st.id}-${sB.st.id}',
              tag: 'Raylı Sistem',
              depMin: depM,
              arrMin: arrM,
              depTime: _fmtMin(depM),
              arrTime: _fmtMin(arrM),
              totalMinutes: arrM - depM,
              walkMinutes: walk1Min + walk2Min,
              transfers: 0,
              modes: const ['rail'],
              legs: legs,
            ),
          );
        }
      }
    }

    // Direct 1-leg ferry routes
    final startPiers = net.piers.values
        .map((p) => (pier: p, d: haversine(from.lat, from.lon, p.pos.latitude, p.pos.longitude)))
        .where((e) => e.d <= 2500)
        .toList()
      ..sort((a, b) => a.d.compareTo(b.d));

    final endPiers = net.piers.values
        .map((p) => (pier: p, d: haversine(to.lat, to.lon, p.pos.latitude, p.pos.longitude)))
        .where((e) => e.d <= 2500)
        .toList()
      ..sort((a, b) => a.d.compareTo(b.d));

    final eng = provider.engine;
    if (eng != null) {
      for (final pA in startPiers.take(5)) {
        for (final pB in endPiers.take(5)) {
          if (pA.pier.id == pB.pier.id) continue;
          for (final fl in net.ferryLines) {
            if (eng.lineCancelledToday(fl, queryWhen)) continue;
            final idxA = fl.piers.indexOf(pA.pier.id);
            final idxB = fl.piers.indexOf(pB.pier.id);
            if (idxA < 0 || idxB < 0 || idxA == idxB) continue;
            final int walk1Min = math.max<int>(1, (pA.d * 1.25 / 78.0).round());
            final int walk2Min = math.max<int>(1, (pB.d * 1.25 / 78.0).round());
            final rows = eng.lineTimetableAt(fl, pA.pier.id, queryWhen);
            DateTime? chosenAt;
            FerryTrip? chosenTrip;
            for (final (dt, trip, _) in rows) {
              final tIdxA = trip.piers.indexOf(pA.pier.id);
              final tIdxB = trip.piers.indexOf(pB.pier.id);
              if (tIdxA < 0 || tIdxB <= tIdxA) continue;
              final m = dt.hour * 60 + dt.minute;
              if (m >= anchorMin + walk1Min - 2) {
                chosenAt = dt;
                chosenTrip = trip;
                break;
              }
            }
            if (chosenAt == null || chosenTrip == null) continue;
            final tIdxA = chosenTrip.piers.indexOf(pA.pier.id);
            final tIdxB = chosenTrip.piers.indexOf(pB.pier.id);
            final int rideMin = math.max<int>(5, chosenTrip.minutes[tIdxB] - chosenTrip.minutes[tIdxA]);
            final int boardM = chosenAt.hour * 60 + chosenAt.minute;
            final int alightM = boardM + rideMin;
            final int depM = math.min<int>(anchorMin, boardM - walk1Min);
            final int arrM = alightM + walk2Min;

            final seaCoords = <LatLng>[];
            final legStops = <RouteLegStop>[];
            for (var i = tIdxA; i <= tIdxB; i++) {
              final pid = chosenTrip.piers[i];
              final pr = net.piers[pid];
              if (pr != null) {
                final int sm = boardM + (chosenTrip.minutes[i] - chosenTrip.minutes[tIdxA]);
                legStops.add(RouteLegStop(
                  name: '${pr.name} İskelesi',
                  code: pr.id,
                  lat: pr.pos.latitude,
                  lon: pr.pos.longitude,
                  time: _fmtMin(sm),
                ));
              }
              if (i < tIdxB) {
                seaCoords.addAll(net.legPath(chosenTrip.piers[i], chosenTrip.piers[i + 1]));
              }
            }

            final op = net.operators[fl.operatorId];
            final hex = op != null
                ? '#${op.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}'
                : '#0284C7';
            final destPier = net.piers[chosenTrip.piers.last]?.name ?? pB.pier.name;

            candidates.add(
              PlannedItinerary(
                id: 'ferry-${fl.id}-$boardM',
                tag: 'Deniz Yolu',
                depMin: depM,
                arrMin: arrM,
                depTime: _fmtMin(depM),
                arrTime: _fmtMin(arrM),
                totalMinutes: arrM - depM,
                walkMinutes: walk1Min + walk2Min,
                transfers: 0,
                modes: const ['ferry'],
                legs: [
                  if (pA.d > 45)
                    PlannedRouteLeg(
                      type: 'walk',
                      fromName: from.name,
                      toName: '${pA.pier.name} İskelesi',
                      fromLat: from.lat,
                      fromLon: from.lon,
                      toLat: pA.pier.pos.latitude,
                      toLon: pA.pier.pos.longitude,
                      depMin: boardM - walk1Min,
                      arrMin: boardM,
                      depTime: _fmtMin(boardM - walk1Min),
                      arrTime: _fmtMin(boardM),
                      durationMin: walk1Min,
                      distanceM: (pA.d * 1.25).round(),
                      coords: [from.latLng, pA.pier.pos],
                    ),
                  PlannedRouteLeg(
                    type: 'ferry',
                    lineCode: op?.short ?? 'VAPUR',
                    lineName: fl.name,
                    direction: '$destPier Yönü',
                    operatorName: op?.name ?? 'Şehir Hatları',
                    colorHex: hex,
                    fromName: '${pA.pier.name} İskelesi',
                    toName: '${pB.pier.name} İskelesi',
                    fromLat: pA.pier.pos.latitude,
                    fromLon: pA.pier.pos.longitude,
                    toLat: pB.pier.pos.latitude,
                    toLon: pB.pier.pos.longitude,
                    depMin: boardM,
                    arrMin: alightM,
                    depTime: _fmtMin(boardM),
                    arrTime: _fmtMin(alightM),
                    durationMin: rideMin,
                    stopsCount: tIdxB - tIdxA,
                    stops: legStops,
                    coords: seaCoords.length >= 2 ? seaCoords : [pA.pier.pos, pB.pier.pos],
                    scheduleNote: '${_fmtMin(boardM)} seferi',
                  ),
                  if (pB.d > 45)
                    PlannedRouteLeg(
                      type: 'walk',
                      fromName: '${pB.pier.name} İskelesi',
                      toName: to.name,
                      fromLat: pB.pier.pos.latitude,
                      fromLon: pB.pier.pos.longitude,
                      toLat: to.lat,
                      toLon: to.lon,
                      depMin: alightM,
                      arrMin: arrM,
                      depTime: _fmtMin(alightM),
                      arrTime: _fmtMin(arrM),
                      durationMin: walk2Min,
                      distanceM: (pB.d * 1.25).round(),
                      coords: [pB.pier.pos, to.latLng],
                    ),
                ],
              ),
            );
          }
        }
      }
    }

    candidates.sort((a, b) => a.totalMinutes.compareTo(b.totalMinutes));
    if (candidates.isEmpty) {
      return RoutePlanResult(
        ok: false,
        error: 'Seçilen noktalar arasında uygun aktarma bulunamadı. Lütfen internet bağlantınızı kontrol edin veya farklı bir saat deneyin.',
        mode: timeMode.apiValue,
        dateStr: dateStr,
        dayType: dayType,
        dayLabel: dayLabel,
        anchorTime: timeStr,
      );
    }

    return RoutePlanResult(
      ok: true,
      mode: timeMode.apiValue,
      dateStr: dateStr,
      dayType: dayType,
      dayLabel: dayLabel,
      anchorTime: timeStr,
      itineraries: candidates.take(5).toList(),
    );
  }
}
