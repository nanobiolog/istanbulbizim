import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import '../models/network_models.dart';

/// Offline transit network bundled with the app: rail lines (real track geometry), stations with
/// plan data, rail projects, ferries (piers, sea paths, timetables) and vehicle photos.
/// Built by tools/build_transit_data.py.
class NetworkRepository {
  List<RailLine> lines = const [];
  Map<String, RailLine> lineByCode = const {};
  Map<String, NetworkStation> stations = const {};
  List<RailProject> projects = const [];

  Map<String, FerryOperator> operators = const {};
  Map<String, Pier> piers = const {};
  List<FerryLine> ferryLines = const [];
  Map<String, List<LatLng>> legs = const {};
  List<(String, List<LatLng>)> referenceRoutes = const [];

  Map<String, List<VehiclePhoto>> media = const {};
  String railAttribution = '';
  String ferryAttribution = '';
  bool loaded = false;

  Future<void> load() async {
    if (loaded) return;
    final raw = await Future.wait([
      _safeLoad('assets/data/rail_network.json'),
      _safeLoad('assets/data/ferry_network.json'),
      _safeLoad('assets/data/vehicle_media.json'),
    ]);
    final parsed = await compute(_parse, raw);
    lines = parsed.lines;
    lineByCode = {for (final l in lines) l.code: l};
    stations = parsed.stations;
    projects = parsed.projects;
    operators = parsed.operators;
    piers = parsed.piers;
    ferryLines = parsed.ferryLines;
    legs = parsed.legs;
    referenceRoutes = parsed.refRoutes;
    media = parsed.media;
    railAttribution = parsed.railAttribution;
    ferryAttribution = parsed.ferryAttribution;
    loaded = true;
  }

  static Future<String> _safeLoad(String path) async {
    try {
      return await rootBundle.loadString(path);
    } catch (_) {
      return '{}';
    }
  }

  static _Parsed _parse(List<String> raw) {
    final p = _Parsed();
    try {
      final rail = jsonDecode(raw[0]) as Map<String, dynamic>;
      p.railAttribution = rail['attribution']?.toString() ?? '';
      p.lines = (rail['lines'] as List? ?? const [])
          .map((l) => RailLine.fromJson(l as Map<String, dynamic>))
          .where((l) => l.variants.isNotEmpty)
          .toList();
      final st = rail['stations'] as Map<String, dynamic>? ?? const {};
      p.stations = {for (final e in st.entries) e.key: NetworkStation.fromJson(e.key, e.value as Map<String, dynamic>)};
      p.projects = (rail['projects'] as List? ?? const [])
          .map((x) => RailProject.fromJson(x as Map<String, dynamic>))
          .toList();
    } catch (_) {}
    try {
      final fer = jsonDecode(raw[1]) as Map<String, dynamic>;
      p.ferryAttribution = fer['attribution']?.toString() ?? '';
      final ops = fer['operators'] as Map<String, dynamic>? ?? const {};
      p.operators = {
        for (final e in ops.entries)
          e.key: FerryOperator(
            e.key,
            (e.value as Map)['name']?.toString() ?? e.key,
            e.value['short']?.toString() ?? '',
            hexColor(e.value['color']?.toString(), const Color(0xFF0B5CAD)),
            e.value['kind']?.toString() == 'İBB',
            e.value['url']?.toString() ?? '',
          ),
      };
      final pr = fer['piers'] as Map<String, dynamic>? ?? const {};
      p.piers = {
        for (final e in pr.entries)
          e.key: Pier(
            e.key,
            (e.value as Map)['name']?.toString() ?? '',
            e.value['full']?.toString() ?? '',
            LatLng((e.value['lat'] as num).toDouble(), (e.value['lon'] as num).toDouble()),
            ((e.value['ops'] as List?) ?? const []).map((x) => x.toString()).toList(),
          ),
      };
      p.ferryLines = (fer['lines'] as List? ?? const [])
          .map((l) => FerryLine.fromJson(l as Map<String, dynamic>))
          .where((l) => l.trips.isNotEmpty)
          .toList();
      final lg = fer['legs'] as Map<String, dynamic>? ?? const {};
      p.legs = {for (final e in lg.entries) e.key: decodePolyline(e.value.toString())};
      p.refRoutes = (fer['ref_routes'] as List? ?? const [])
          .map((r) => ((r as Map)['name']?.toString() ?? '', decodePolyline(r['path']?.toString() ?? '')))
          .toList();
    } catch (_) {}
    try {
      final med = jsonDecode(raw[2]) as Map<String, dynamic>;
      final items = med['items'] as Map<String, dynamic>? ?? const {};
      p.media = {
        for (final e in items.entries)
          e.key: (e.value as List).map((x) => VehiclePhoto.fromJson(x as Map<String, dynamic>)).toList(),
      };
    } catch (_) {}
    return p;
  }

  /// Sea path between two piers (falls back to a straight hop).
  List<LatLng> legPath(String a, String b) {
    final f = legs['$a|$b'];
    if (f != null && f.length >= 2) return f;
    final r = legs['$b|$a'];
    if (r != null && r.length >= 2) return r.reversed.toList();
    final pa = piers[a]?.pos, pb = piers[b]?.pos;
    if (pa == null || pb == null) return const [];
    return [pa, pb];
  }

  List<RailLine> linesAt(NetworkStation s) =>
      s.lines.map((c) => lineByCode[c]).whereType<RailLine>().toList();

  NetworkStation? nearestStation(LatLng p, {double maxM = 1200}) {
    NetworkStation? best;
    var bd = maxM;
    for (final s in stations.values) {
      final d = haversine(p.latitude, p.longitude, s.pos.latitude, s.pos.longitude);
      if (d < bd) {
        bd = d;
        best = s;
      }
    }
    return best;
  }

  List<VehiclePhoto> photos(String key) => media[key] ?? const [];
}

class _Parsed {
  List<RailLine> lines = const [];
  Map<String, NetworkStation> stations = const {};
  List<RailProject> projects = const [];
  Map<String, FerryOperator> operators = const {};
  Map<String, Pier> piers = const {};
  List<FerryLine> ferryLines = const [];
  Map<String, List<LatLng>> legs = const {};
  List<(String, List<LatLng>)> refRoutes = const [];
  Map<String, List<VehiclePhoto>> media = const {};
  String railAttribution = '';
  String ferryAttribution = '';
}
