import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import '../models/transit_models.dart';

class TransitApiService {
  // Remote Cloudflare Worker endpoint with fallback to direct IBB
  static const String defaultWorkerUrl = "https://istanbulbizim-live.nano-carbay.workers.dev";
  static const String directIettFleet = "https://api.ibb.gov.tr/iett/FiloDurum/SeferGerceklesme.asmx";
  static const String directIbbRoute = "https://api.ibb.gov.tr/iett/ibb/ibb.asmx";

  String baseUrl = defaultWorkerUrl;

  // Local assets cache
  Map<String, List<String>> _busLinesDoors = {};
  Map<String, String> _doorToLine = {};
  Map<String, List<MetroStation>> _metroStations = {};
  Map<String, String> _metroColors = {};
  bool _assetsLoaded = false;

  Future<void> loadLocalAssets() async {
    if (_assetsLoaded) return;
    try {
      // 1. Bus Lines Map
      final linesJson = await rootBundle.loadString('assets/data/bus_lines_map.json');
      final Map<String, dynamic> parsedLines = jsonDecode(linesJson);
      _busLinesDoors = {};
      _doorToLine = {};
      parsedLines.forEach((line, doors) {
        if (doors is List) {
          final doorList = doors.map((d) => d.toString()).toList();
          _busLinesDoors[line] = doorList;
          for (final door in doorList) {
            _doorToLine[door] = line;
          }
        }
      });

      // 2. Metro Colors
      final colorsJson = await rootBundle.loadString('assets/data/metro_colors.json');
      final Map<String, dynamic> parsedColors = jsonDecode(colorsJson);
      _metroColors = parsedColors.map((k, v) => MapEntry(k, v.toString()));

      // 3. Metro Stations
      final stationsJson = await rootBundle.loadString('assets/data/metro_stations.json');
      final Map<String, dynamic> parsedStations = jsonDecode(stationsJson);
      _metroStations = {};
      parsedStations.forEach((line, list) {
        if (list is List) {
          _metroStations[line] = list.map((item) => MetroStation.fromJson(item, line)).toList();
        }
      });

      _assetsLoaded = true;
    } catch (e) {
      // ignore local load error, will use dynamic data
    }
  }

  Map<String, List<String>> get busLinesDoors => _busLinesDoors;
  Map<String, List<MetroStation>> get metroStations => _metroStations;
  Map<String, String> get metroColors => _metroColors;

  // Fetch all fleet vehicles
  Future<List<BusVehicle>> fetchFleetBuses() async {
    await loadLocalAssets();

    // 1. Try Worker first
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/buses'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['buses'] is List) {
          final list = (data['buses'] as List).map((b) => BusVehicle.fromJson(b)).toList();
          return _enrichBusesWithLines(list);
        }
      }
    } catch (_) {
      // Fallback to direct IETT SOAP API
    }

    // 2. Direct SOAP fallback
    return await _fetchDirectIettFleet();
  }

  // Fetch vehicles for a specific line
  Future<List<BusVehicle>> fetchBusesForLine(String lineCode) async {
    await loadLocalAssets();
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/line?code=${Uri.encodeComponent(lineCode)}'),
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['buses'] is List) {
          return (data['buses'] as List).map((b) => BusVehicle.fromJson(b)).toList();
        }
      }
    } catch (_) {}

    // Fallback: Filter from entire fleet
    final fleet = await fetchFleetBuses();
    final targetDoors = _busLinesDoors[lineCode]?.toSet() ?? {};
    if (targetDoors.isNotEmpty) {
      return fleet.where((b) => targetDoors.contains(b.id)).map((b) {
        return BusVehicle(
          id: b.id,
          lat: b.lat,
          lon: b.lon,
          speed: b.speed,
          time: b.time,
          ageSeconds: b.ageSeconds,
          operator: b.operator,
          plate: b.plate,
          line: lineCode,
          direction: b.direction,
          directionName: b.directionName,
          headsign: b.headsign,
          bearing: b.bearing,
        );
      }).toList();
    }
    return fleet.where((b) => b.line.toUpperCase() == lineCode.toUpperCase()).toList();
  }

  // Fetch official line stops and geometry (directions D & G)
  Future<LineRouteDetails?> fetchLineRoute(String lineCode) async {
    // 1. Worker endpoint
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/line/route?code=${Uri.encodeComponent(lineCode)}'),
      ).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map<String, dynamic> && data['directions'] != null) {
          return LineRouteDetails.fromJson(data);
        }
      }
    } catch (_) {}

    // 2. Direct SOAP fallback to IBB DurakDetay_GYY
    return await _fetchDirectLineRoute(lineCode);
  }

  // Direct SOAP implementation for fleet
  Future<List<BusVehicle>> _fetchDirectIettFleet() async {
    const soapBody = '''<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <GetFiloAracKonum_json xmlns="http://tempuri.org/" />
  </soap:Body>
</soap:Envelope>''';

    try {
      final res = await http.post(
        Uri.parse(directIettFleet),
        headers: {
          'Content-Type': 'text/xml; charset=utf-8',
          'SOAPAction': '"http://tempuri.org/GetFiloAracKonum_json"',
          'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)',
        },
        body: utf8.encode(soapBody),
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        final bodyStr = res.body;
        final startTag = '<GetFiloAracKonum_jsonResult>';
        final endTag = '</GetFiloAracKonum_jsonResult>';
        final startIdx = bodyStr.indexOf(startTag);
        final endIdx = bodyStr.indexOf(endTag);

        if (startIdx != -1 && endIdx != -1) {
          final rawJson = bodyStr.substring(startIdx + startTag.length, endIdx);
          final unescaped = rawJson
              .replaceAll('&quot;', '"')
              .replaceAll('&lt;', '<')
              .replaceAll('&gt;', '>')
              .replaceAll('&amp;', '&');

          final List<dynamic> rows = jsonDecode(unescaped);
          final buses = <BusVehicle>[];

          for (final r in rows) {
            final lat = double.tryParse((r['Enlem'] ?? '').toString().replaceAll(',', '.')) ?? 0.0;
            final lon = double.tryParse((r['Boylam'] ?? '').toString().replaceAll(',', '.')) ?? 0.0;
            if (lat < 40.5 || lat > 41.6 || lon < 27.8 || lon > 29.8) continue;

            final speed = double.tryParse((r['Hiz'] ?? '').toString().replaceAll(',', '.')) ?? 0.0;
            final door = r['KapiNo']?.toString() ?? '';

            buses.add(BusVehicle(
              id: door,
              lat: lat,
              lon: lon,
              speed: speed,
              time: r['Saat']?.toString() ?? '',
              operator: r['Operator']?.toString() ?? '',
              plate: r['Plaka']?.toString() ?? '',
              line: _doorToLine[door] ?? '',
            ));
          }
          return buses;
        }
      }
    } catch (e) {
      // Direct SOAP failed
    }
    return [];
  }

  // Direct SOAP implementation for Line Route Details
  Future<LineRouteDetails?> _fetchDirectLineRoute(String lineCode) async {
    final body = '''<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <soap:Body>
    <DurakDetay_GYY xmlns="http://tempuri.org/">
      <hat_kodu>$lineCode</hat_kodu>
    </DurakDetay_GYY>
  </soap:Body>
</soap:Envelope>''';

    try {
      final res = await http.post(
        Uri.parse(directIbbRoute),
        headers: {
          'Content-Type': 'text/xml; charset=utf-8',
          'SOAPAction': '"http://tempuri.org/DurakDetay_GYY"',
          'User-Agent': 'Mozilla/5.0',
        },
        body: utf8.encode(body),
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final xml = res.body;
        final tableRegex = RegExp(r'<Table>([\s\S]*?)<\/Table>');
        final matches = tableRegex.allMatches(xml);

        final dirs = <String, List<BusStop>>{};

        for (final m in matches) {
          final row = m.group(1) ?? '';
          String getTag(String tag) {
            final tMatch = RegExp('<$tag>([^<]*)<\\/$tag>', caseSensitive: false).firstMatch(row);
            return tMatch?.group(1)?.trim() ?? '';
          }

          final yon = getTag('YON').isEmpty ? 'D' : getTag('YON');
          final lat = double.tryParse(getTag('YKOORDINATI').replaceAll(',', '.')) ?? 0.0;
          final lon = double.tryParse(getTag('XKOORDINATI').replaceAll(',', '.')) ?? 0.0;
          if (lat < 40.0 || lat > 42.0 || lon < 27.0 || lon > 30.5) continue;

          dirs.putIfAbsent(yon, () => []).add(BusStop(
                code: getTag('DURAKKODU'),
                name: getTag('DURAKADI'),
                district: getTag('ILCEADI'),
                lat: lat,
                lon: lon,
                sequence: int.tryParse(getTag('SIRANO')) ?? 0,
              ));
        }

        final directions = <String, LineDirectionRoute>{};
        dirs.forEach((k, stops) {
          stops.sort((a, b) => a.sequence.compareTo(b.sequence));
          if (stops.isNotEmpty) {
            final origin = stops.first.name;
            final dest = stops.last.name;
            final isOutbound = k == 'G' || k == 'GİDİŞ';
            directions[k] = LineDirectionRoute(
              code: k,
              name: (isOutbound ? 'Gidiş: ' : 'Dönüş: ') + dest,
              origin: origin,
              destination: dest,
              headsign: '$origin ➔ $dest',
              colorHex: isOutbound ? '#a855f7' : '#06b6d4',
              stops: stops,
              coordinates: stops.map((s) => [s.lat, s.lon]).toList(),
            );
          }
        });

        if (directions.isNotEmpty) {
          return LineRouteDetails(
            code: lineCode,
            name: lineCode,
            directions: directions,
            totalStops: directions.values.fold(0, (acc, d) => acc + d.stops.length),
          );
        }
      }
    } catch (_) {}
    return null;
  }

  List<BusVehicle> _enrichBusesWithLines(List<BusVehicle> list) {
    if (_doorToLine.isEmpty) return list;
    return list.map((b) {
      if (b.line.isNotEmpty) return b;
      final mappedLine = _doorToLine[b.id];
      if (mappedLine != null) {
        return BusVehicle(
          id: b.id,
          lat: b.lat,
          lon: b.lon,
          speed: b.speed,
          time: b.time,
          ageSeconds: b.ageSeconds,
          operator: b.operator,
          plate: b.plate,
          line: mappedLine,
          direction: b.direction,
          directionName: b.directionName,
          headsign: b.headsign,
          bearing: b.bearing,
        );
      }
      return b;
    }).toList();
  }
}
