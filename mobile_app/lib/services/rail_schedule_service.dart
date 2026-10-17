import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/rail_models.dart';
import 'rail_engine.dart';

/// Loads one day's train schedule per rail line: memory → device cache → Worker (`/rail/schedule`)
/// → Metro İstanbul API directly → Marmaray plan / frequency estimate. Never returns null for a line
/// with stations, so the map always has trains; [RailSchedule.official] says how much to trust them.
class RailScheduleService {
  static const String metroApi = 'https://api.ibb.gov.tr/MetroIstanbul/api/MetroMobile/V2';
  static const int _maxSamplesPerDir = 14;

  final http.Client _client;
  final String Function() baseUrl;
  final Map<String, RailSchedule> _memo = {};
  final Map<String, Future<RailSchedule>> _inflight = {};
  SharedPreferences? _prefs;

  RailScheduleService({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();

  Future<SharedPreferences?> _p() async {
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  RailSchedule? cached(String code, RailServiceDay day) => _memo['$code:${day.dateKey}'];

  Future<RailSchedule> load(String code, List<RailStation> stations, RailServiceDay day) {
    final key = '$code:${day.dateKey}';
    final mem = _memo[key];
    if (mem != null) return Future.value(mem);
    return _inflight[key] ??= _load(code, stations, day).whenComplete(() => _inflight.remove(key));
  }

  Future<RailSchedule> _load(String code, List<RailStation> stations, RailServiceDay day) async {
    final key = '$code:${day.dateKey}';
    final prefs = await _p();

    // 1. Device cache for this service day (official schedules only; estimates are cheap to redo).
    try {
      final raw = prefs?.getString('rail_v1:$code');
      if (raw != null) {
        final s = RailSchedule.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (s.serviceDate == day.dateKey && s.official && _fits(s, stations)) {
          return _memo[key] = s;
        }
      }
    } catch (_) {}

    // 2. Worker: shared, KV-cached build from the official timetables.
    if (code != 'B1') {
      try {
        final res = await _client
            .get(Uri.parse('${baseUrl()}/rail/schedule?line=${Uri.encodeComponent(code)}'))
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final s = RailSchedule.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
          if (s.directions.isNotEmpty && _fits(s, stations)) {
            await _persist(prefs, code, s);
            return _memo[key] = s;
          }
        }
      } catch (_) {}

      // 3. Same algorithm on the device straight from Metro İstanbul.
      try {
        final s = await _buildFromMetroApi(code, stations, day);
        if (s != null) {
          await _persist(prefs, code, s);
          return _memo[key] = s;
        }
      } catch (_) {}
    }

    // 4. Marmaray plan or frequency estimate (not cached on disk so a later launch retries).
    return _memo[key] = buildEstimatedSchedule(code, stations, day);
  }

  bool _fits(RailSchedule s, List<RailStation> stations) =>
      s.stations.length == stations.length && s.directions.every((d) => d.offsets.length == stations.length);

  Future<void> _persist(SharedPreferences? prefs, String code, RailSchedule s) async {
    try {
      await prefs?.setString('rail_v1:$code', jsonEncode(s.toJson()));
    } catch (_) {}
  }

  /// Live disruption notices per line (Metro İstanbul GetServiceStatuses).
  Future<Map<String, List<RailStatusItem>>?> loadStatus() async {
    try {
      final res = await _client.get(Uri.parse('${baseUrl()}/rail/status')).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final j = jsonDecode(utf8.decode(res.bodyBytes));
        if (j is Map && j['ok'] != false && j['items'] is List) {
          return _groupStatus((j['items'] as List)
              .whereType<Map>()
              .map((e) => RailStatusItem.fromJson(Map<String, dynamic>.from(e)))
              .toList());
        }
      }
    } catch (_) {}
    try {
      final rows = await _metro('GetServiceStatuses');
      if (rows is List) {
        final items = <RailStatusItem>[];
        for (final r in rows.whereType<Map>()) {
          final m = Map<String, dynamic>.from(r);
          final desc = (_pick(m, ['Description', 'Message', 'Text', 'Title']) ?? '').toString().trim();
          final active = _pick(m, ['IsActive', 'Active']);
          if (active == false || desc.isEmpty) continue;
          final lineName = (_pick(m, ['LineName', 'Line', 'Name']) ?? '').toString();
          items.add(RailStatusItem(
            line: railLineFromText(lineName).isNotEmpty ? railLineFromText(lineName) : railLineFromText(desc),
            message: desc,
            updated: (_pick(m, ['UpdateDate', 'UpdatedDate', 'CreateDate', 'Date']) ?? '').toString(),
          ));
        }
        return _groupStatus(items);
      }
    } catch (_) {}
    return null;
  }

  Map<String, List<RailStatusItem>> _groupStatus(List<RailStatusItem> items) {
    final out = <String, List<RailStatusItem>>{};
    for (final it in items) {
      if (it.line.isEmpty) continue;
      out.putIfAbsent(it.line, () => []).add(it);
    }
    return out;
  }

  /// Exact official departures at one station (Worker `/rail/departures`); null when unreachable.
  Future<List<RailDeparture>?> officialDepartures(String code, String station, RailServiceDay day) async {
    try {
      final res = await _client
          .get(Uri.parse('${baseUrl()}/rail/departures?line=${Uri.encodeComponent(code)}&station=${Uri.encodeComponent(station)}'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is! Map || j['departures'] is! List || j['service_date'] != day.dateKey) return null;
      final official = j['official'] == true;
      final out = <RailDeparture>[];
      for (final d in (j['departures'] as List).whereType<Map>()) {
        for (final t in (d['times'] as List? ?? const [])) {
          final sec = (t as num).toInt();
          if (sec < day.nowSec - 20) continue;
          out.add(RailDeparture(
            line: code,
            dir: d['dir']?.toString() ?? 'G',
            headsign: d['headsign']?.toString() ?? '',
            at: day.at(sec),
            official: official,
          ));
        }
      }
      out.sort((a, b) => a.at.compareTo(b.at));
      return out;
    } catch (_) {
      return null;
    }
  }

  // ── Direct Metro İstanbul build (mirror of buildMetroRailSchedule in src/rail.js) ──

  Future<dynamic> _metro(String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$metroApi/$path');
    final headers = {'Content-Type': 'application/json', 'Accept': 'application/json'};
    final res = body == null
        ? await _client.get(uri, headers: headers).timeout(const Duration(seconds: 10))
        : await _client.post(uri, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('Metro $path HTTP ${res.statusCode}');
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    if (j is Map && j['Success'] == false) throw Exception('Metro $path failed');
    return j is Map && j.containsKey('Data') ? j['Data'] : j;
  }

  static dynamic _pick(Map<String, dynamic> o, List<String> names) {
    final lower = <String, dynamic>{};
    o.forEach((k, v) => lower[k.toLowerCase()] = v);
    for (final n in names) {
      final v = lower[n.toLowerCase()];
      if (v != null) return v;
    }
    return null;
  }

  static List<int> timesFrom(dynamic data) {
    final out = <int>{};
    void walk(dynamic node) {
      if (node is List) {
        node.forEach(walk);
        return;
      }
      if (node is! Map) return;
      final m = Map<String, dynamic>.from(node);
      final ti = _pick(m, ['TimeInfos']);
      if (ti != null) {
        walk(ti);
        return;
      }
      final times = _pick(m, ['Times']);
      if (times is List) {
        for (final x in times) {
          final s = x is Map ? (_pick(Map<String, dynamic>.from(x), ['Time', 'Hour', 'Saat']) ?? '').toString() : x.toString();
          final sec = railTimeToSec(s);
          if (sec != null) out.add(sec);
        }
      }
    }

    walk(data);
    return out.toList()..sort();
  }

  static List<String>? splitEnds(String name) {
    var parts = name.split(RegExp(r'\s*(?:->|→|=>|➔|>)\s*')).where((e) => e.isNotEmpty).toList();
    if (parts.length != 2) parts = name.split(RegExp(r'\s+[-–—]\s+')).where((e) => e.isNotEmpty).toList();
    if (parts.length != 2) parts = name.split(RegExp(r'\s*[-–—]\s*')).where((e) => e.isNotEmpty).toList();
    return parts.length >= 2 ? [parts.first, parts.last] : null;
  }

  Future<RailSchedule?> _buildFromMetroApi(String code, List<RailStation> stations, RailServiceDay day) async {
    final lines = await _metro('GetLines');
    if (lines is! List) return null;
    final want = railPlainName(code);
    Map<String, dynamic>? line;
    for (final l in lines.whereType<Map>()) {
      final m = Map<String, dynamic>.from(l);
      if (['Name', 'ShortName', 'Code', 'LineName', 'LineCode', 'Description']
          .any((k) => railPlainName((_pick(m, [k]) ?? '').toString()) == want)) {
        line = m;
        break;
      }
    }
    if (line == null) return null;
    final lineId = _pick(line, ['Id', 'LineId']);
    final results = await Future.wait([
      _metro('GetStationById/${Uri.encodeComponent('$lineId')}'),
      _metro('GetDirectionById/${Uri.encodeComponent('$lineId')}'),
    ]);
    final apiStations = (results[0] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .map((s) => (id: _pick(s, ['Id', 'StationId']), name: (_pick(s, ['Description', 'Name', 'StationName']) ?? '').toString()))
        .where((s) => s.id != null)
        .toList();
    final apiDirs = (results[1] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .map((d) => (id: _pick(d, ['DirectionId', 'Id']), name: (_pick(d, ['DirectionName', 'Name']) ?? '').toString()))
        .where((d) => d.id != null)
        .toList();
    if (apiStations.isEmpty || apiDirs.isEmpty) return null;

    final n = stations.length;
    final apiIdAt = List<dynamic>.filled(n, null);
    for (var i = 0; i < apiStations.length; i++) {
      var idx = railFindStation(stations, apiStations[i].name);
      if (idx < 0 && apiStations.length == n) idx = i;
      if (idx >= 0 && apiIdAt[idx] == null) apiIdAt[idx] = apiStations[i].id;
    }

    final patterns = <({dynamic id, int a, int b})>[];
    for (var i = 0; i < apiDirs.length; i++) {
      final ends = splitEnds(apiDirs[i].name);
      var a = ends == null ? -1 : railFindStation(stations, ends[0]);
      var b = ends == null ? -1 : railFindStation(stations, ends[1]);
      if (a < 0 || b < 0 || a == b) {
        if (i > 1) continue;
        a = i == 0 ? 0 : n - 1;
        b = i == 0 ? n - 1 : 0;
      }
      patterns.add((id: apiDirs[i].id, a: a, b: b));
    }

    final prof = railProfile(code);
    final directions = <RailDirection>[];
    for (final fwd in [true, false]) {
      final same = patterns.where((p) => (p.a < p.b) == fwd).toList()
        ..sort((x, y) => (y.b - y.a).abs().compareTo((x.b - x.a).abs()));
      if (same.isEmpty) continue;
      final main = same.first;
      final order = fwd ? stations : stations.reversed.toList();
      int pos(int idx) => fwd ? idx : n - 1 - idx;
      final prior = railPriorOffsets(order, prof);
      final originPos = pos(main.a), endPos = pos(main.b);

      final mid = [for (var p = originPos + 1; p < endPos; p++) p];
      final step = math.max(1, (mid.length / _maxSamplesPerDir).ceil());
      final picked = <int>[originPos];
      for (var k = 0; k < mid.length; k++) {
        if (k % step == step - 1 || k == mid.length - 1) picked.add(mid[k]);
      }
      final samples = <int, List<int>>{};
      await Future.wait(picked.map((p) async {
        final sid = apiIdAt[fwd ? p : n - 1 - p];
        if (sid == null) return;
        try {
          final t = timesFrom(await _metro('GetTimeTable', {'boardingStationId': sid, 'directionId': main.id}));
          if (t.isNotEmpty) samples[p] = t;
        } catch (_) {}
      }));
      final originTimes = samples[originPos];
      if (originTimes == null || originTimes.isEmpty) continue;

      final derived = railDeriveOffsets(prior, originPos, samples);
      final offsets = derived.offsets;
      final trips = originTimes.map((t) => RailTrip(t, originPos, endPos)).toList();
      for (final sp in same.skip(1).take(3)) {
        final sid = apiIdAt[sp.a];
        if (sid == null) continue;
        try {
          final times = timesFrom(await _metro('GetTimeTable', {'boardingStationId': sid, 'directionId': sp.id}));
          final a = pos(sp.a), b = pos(sp.b);
          final mainAtA = originTimes.map((t) => ((t + offsets[a] - offsets[originPos]) / 60).round()).toSet();
          for (final t in times) {
            if (!mainAtA.contains((t / 60).round())) trips.add(RailTrip(t, a, b));
          }
        } catch (_) {}
      }
      trips.sort((x, y) => (x.dep - offsets[x.from]).compareTo(y.dep - offsets[y.from]));
      directions.add(RailDirection(
        dir: fwd ? 'G' : 'D',
        forward: fwd,
        name: '${order[originPos].name} ➔ ${order[endPos].name}',
        headsign: order[endPos].name,
        offsets: offsets,
        timetablePoints: derived.matched + 1,
        trips: trips,
      ));
    }
    if (directions.isEmpty) return null;
    return RailSchedule(
      line: code,
      serviceDate: day.dateKey,
      dayType: day.dayType,
      official: true,
      source: 'Metro İstanbul resmî istasyon tarifeleri (cihazdan)',
      note: 'Konumlar resmî kalkış saatlerinden hesaplanır; anlık gecikmeler yansımaz.',
      dwellSec: prof.dwell.round(),
      stations: stations,
      directions: directions,
    );
  }
}

/// Line code mentioned in a Metro İstanbul notice ("M2 Yenikapı-Hacıosman" → M2).
String railLineFromText(String s) {
  var u = s.toUpperCase();
  const map = {'İ': 'I', 'Ş': 'S', 'Ğ': 'G', 'Ü': 'U', 'Ö': 'O', 'Ç': 'C'};
  map.forEach((k, v) => u = u.replaceAll(k, v));
  final m = RegExp(r'\b(TF[12]|M1[AB]|M\d{1,2}|T[1-5]|F[1-4]|B1)\b').firstMatch(u);
  if (m != null) return m.group(1)!;
  return u.contains('MARMARAY') ? 'B1' : '';
}
