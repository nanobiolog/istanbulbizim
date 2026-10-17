import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:provider/provider.dart';

import '../models/transit_models.dart';
import '../services/rail_engine.dart' show istanbulClock, bearingDeg;
import '../services/transit_provider.dart';
import '../services/walking_directions_service.dart';
import '../theme/app_theme.dart';
import 'station_view_screen.dart';

/// Tilted 3D city view: extruded buildings, rail lines, timetable-driven trains as 3D blocks
/// and live buses, with a "ride along" camera that follows a train.
class Map3DScreen extends StatefulWidget {
  final ll.LatLng center;
  final double zoom;
  final double bearing;
  final double tilt;
  final String? followTrainId;
  final MetroStation? focusStation;
  final WalkRoute? route;

  const Map3DScreen({
    super.key,
    required this.center,
    this.zoom = 15.2,
    this.bearing = -20,
    this.tilt = 60,
    this.followTrainId,
    this.focusStation,
    this.route,
  });

  @override
  State<Map3DScreen> createState() => _Map3DScreenState();
}

class _Map3DScreenState extends State<Map3DScreen> {
  // OpenFreeMap (no key, OpenMapTiles schema with building heights); CARTO GL as fallback.
  static const _darkStyles = [
    'https://tiles.openfreemap.org/styles/dark',
    'https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json',
  ];
  static const _lightStyles = [
    'https://tiles.openfreemap.org/styles/liberty',
    'https://basemaps.cartocdn.com/gl/voyager-gl-style/style.json',
  ];

  MapLibreMapController? _c;
  int _styleIdx = 0;
  bool _styleReady = false;
  Timer? _styleTimeout;
  Timer? _tick;
  bool _pushing = false;
  String? _followId;
  String? _selectedTrainId;
  MetroStation? _selectedStation;
  bool _tilted = true;
  bool _hasLocation = false;
  double _zoom = 15;

  late final TransitProvider _p = context.read<TransitProvider>();
  bool get _night => _p.isNightMode;
  List<String> get _styles => _night ? _darkStyles : _lightStyles;

  @override
  void initState() {
    super.initState();
    _followId = widget.followTrainId;
    _selectedTrainId = widget.followTrainId;
    _selectedStation = widget.focusStation;
    _zoom = widget.zoom;
    _armStyleTimeout();
    _checkLocation();
  }

  @override
  void dispose() {
    _styleTimeout?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _checkLocation() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (mounted) setState(() => _hasLocation = perm == LocationPermission.always || perm == LocationPermission.whileInUse);
    } catch (_) {}
  }

  void _armStyleTimeout() {
    _styleTimeout?.cancel();
    _styleTimeout = Timer(const Duration(seconds: 12), () {
      if (!_styleReady && _styleIdx + 1 < _styles.length && mounted) {
        setState(() => _styleIdx++); // style host unreachable: try the next one
        _armStyleTimeout();
      }
    });
  }

  static String _hex(Color c) {
    final v = c.toARGB32() & 0xFFFFFF;
    return '#${v.toRadixString(16).padLeft(6, '0')}';
  }

  Future<void> _onStyleLoaded() async {
    final c = _c;
    if (c == null) return;
    _styleReady = true;
    _styleTimeout?.cancel();

    await _addBuildings(c);
    await _addRail(c);
    if (widget.route != null) await _addRoute(c, widget.route!);
    await _addLiveLayers(c);

    c.onFeatureTapped.add(_onFeatureTap);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 1000), (_) => _pushLive());
    await _pushLive();

    final st = widget.focusStation;
    if (st != null) _flyToStation(st);
  }

  Future<void> _addBuildings(MapLibreMapController c) async {
    final colors = _night
        ? ['interpolate', ['linear'], ['coalesce', ['get', 'render_height'], 10], 0, '#1e293b', 40, '#334155', 150, '#64748b']
        : ['interpolate', ['linear'], ['coalesce', ['get', 'render_height'], 10], 0, '#e2e8f0', 40, '#cbd5e1', 150, '#94a3b8'];
    // Native MapLibre accepts a layer on a missing source silently, so pick a source that exists.
    var sources = const <String>['openmaptiles', 'carto'];
    var layers = const <String>[];
    try {
      final ids = (await c.getSourceIds()).map((e) => e.toString()).toList();
      if (ids.isNotEmpty) sources = sources.where(ids.contains).toList();
      layers = (await c.getLayerIds()).map((e) => e.toString()).toList();
    } catch (_) {} // web: listing unsupported, fall through to the first candidate
    if (sources.isEmpty) return; // keep whatever buildings the style draws itself
    try {
      await c.addFillExtrusionLayer(
        sources.first,
        'ib-buildings-3d',
        FillExtrusionLayerProperties(
          fillExtrusionColor: colors,
          fillExtrusionHeight: ['interpolate', ['linear'], ['zoom'], 13.5, 0, 15, ['coalesce', ['get', 'render_height'], 8]],
          fillExtrusionBase: ['coalesce', ['get', 'render_min_height'], 0],
          fillExtrusionOpacity: 0.88,
        ),
        sourceLayer: 'building',
        minzoom: 13.5,
        enableInteraction: false,
      );
    } catch (_) {
      return;
    }
    // Ours replaces the style's own extrusions so both themes look the same.
    for (final id in layers.where((l) => l != 'ib-buildings-3d' && l.contains('building') && (l.contains('3d') || l.contains('extru')))) {
      try {
        await c.setLayerVisibility(id, false);
      } catch (_) {}
    }
  }

  Future<void> _addRail(MapLibreMapController c) async {
    final lines = <Map<String, dynamic>>[];
    final stations = <Map<String, dynamic>>[];
    _p.metroStations.forEach((code, list) {
      if (list.length < 2) return;
      final color = _hex(_p.getMetroLineColor(code));
      lines.add({
        'type': 'Feature',
        'id': 'line:$code',
        'properties': {'code': code, 'color': color},
        'geometry': {
          'type': 'LineString',
          'coordinates': list.map((s) => [s.lon, s.lat]).toList(),
        },
      });
      for (var i = 0; i < list.length; i++) {
        stations.add({
          'type': 'Feature',
          'id': 'st:$code:$i',
          'properties': {'name': list[i].name, 'color': color, 'code': code},
          'geometry': {
            'type': 'Point',
            'coordinates': [list[i].lon, list[i].lat]
          },
        });
      }
    });
    await c.addGeoJsonSource('ib-rail', {'type': 'FeatureCollection', 'features': lines}, promoteId: 'code');
    await c.addLineLayer(
      'ib-rail',
      'ib-rail-glow',
      LineLayerProperties(
        lineColor: ['get', 'color'],
        lineWidth: ['interpolate', ['linear'], ['zoom'], 10, 4, 16, 14],
        lineOpacity: 0.28,
        lineBlur: 3,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      enableInteraction: false,
    );
    await c.addLineLayer(
      'ib-rail',
      'ib-rail-line',
      LineLayerProperties(
        lineColor: ['get', 'color'],
        lineWidth: ['interpolate', ['linear'], ['zoom'], 10, 2, 16, 6],
        lineCap: 'round',
        lineJoin: 'round',
      ),
      enableInteraction: false,
    );
    await c.addGeoJsonSource('ib-stations', {'type': 'FeatureCollection', 'features': stations});
    await c.addCircleLayer(
      'ib-stations',
      'ib-stations-dot',
      CircleLayerProperties(
        circleRadius: ['interpolate', ['linear'], ['zoom'], 11, 2.5, 16, 7],
        circleColor: '#ffffff',
        circleStrokeColor: ['get', 'color'],
        circleStrokeWidth: 2.5,
        circlePitchAlignment: 'map',
      ),
      minzoom: 11,
    );
    await c.addSymbolLayer(
      'ib-stations',
      'ib-stations-label',
      SymbolLayerProperties(
        textField: ['get', 'name'],
        textFont: ['Noto Sans Bold'],
        textSize: ['interpolate', ['linear'], ['zoom'], 13, 10, 17, 14],
        textOffset: [0, 1.3],
        textAnchor: 'top',
        textColor: _night ? '#f8fafc' : '#0f172a',
        textHaloColor: _night ? '#0b132b' : '#ffffff',
        textHaloWidth: 1.6,
        textOptional: true,
      ),
      minzoom: 13,
      enableInteraction: false,
    );
  }

  Future<void> _addRoute(MapLibreMapController c, WalkRoute r) async {
    await c.addGeoJsonSource('ib-walk', {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'id': 'walk',
          'properties': <String, dynamic>{},
          'geometry': {'type': 'LineString', 'coordinates': r.points.map((p) => [p.longitude, p.latitude]).toList()},
        }
      ],
    });
    await c.addLineLayer(
      'ib-walk',
      'ib-walk-line',
      const LineLayerProperties(
        lineColor: '#38bdf8',
        lineWidth: ['interpolate', ['linear'], ['zoom'], 12, 3, 18, 8],
        lineDasharray: [1.2, 1.2],
        lineCap: 'round',
        lineJoin: 'round',
      ),
      enableInteraction: false,
    );
  }

  Future<void> _addLiveLayers(MapLibreMapController c) async {
    const empty = {'type': 'FeatureCollection', 'features': <Map<String, dynamic>>[]};
    await c.addGeoJsonSource('ib-buses', empty);
    await c.addGeoJsonSource('ib-bus-boxes', empty);
    await c.addGeoJsonSource('ib-trains', empty);
    await c.addGeoJsonSource('ib-train-labels', empty);

    await c.addCircleLayer(
      'ib-buses',
      'ib-buses-dot',
      const CircleLayerProperties(
        circleRadius: ['interpolate', ['linear'], ['zoom'], 12, 3, 15, 6],
        circleColor: ['get', 'color'],
        circleStrokeColor: '#09090b',
        circleStrokeWidth: 1.5,
      ),
      maxzoom: 15,
    );
    await c.addFillExtrusionLayer(
      'ib-bus-boxes',
      'ib-buses-3d',
      const FillExtrusionLayerProperties(
        fillExtrusionColor: ['get', 'color'],
        fillExtrusionHeight: ['get', 'h'],
        fillExtrusionBase: 0,
        fillExtrusionOpacity: 0.95,
      ),
      minzoom: 14.5,
    );
    await c.addSymbolLayer(
      'ib-buses',
      'ib-buses-label',
      SymbolLayerProperties(
        textField: ['get', 'line'],
        textFont: ['Noto Sans Bold'],
        textSize: 11,
        textOffset: [0, -1.4],
        textColor: _night ? '#f8fafc' : '#09090b',
        textHaloColor: _night ? '#09090b' : '#ffffff',
        textHaloWidth: 1.5,
        textOptional: true,
      ),
      minzoom: 14,
      enableInteraction: false,
    );
    await c.addFillExtrusionLayer(
      'ib-trains',
      'ib-trains-3d',
      const FillExtrusionLayerProperties(
        fillExtrusionColor: ['get', 'color'],
        fillExtrusionHeight: ['get', 'h'],
        fillExtrusionBase: ['get', 'b'],
        fillExtrusionOpacity: 0.97,
      ),
    );
    await c.addSymbolLayer(
      'ib-train-labels',
      'ib-trains-label',
      SymbolLayerProperties(
        textField: ['get', 'label'],
        textFont: ['Noto Sans Bold'],
        textSize: ['interpolate', ['linear'], ['zoom'], 12, 10, 16, 13],
        textOffset: [0, -1.6],
        textColor: '#ffffff',
        textHaloColor: ['get', 'color'],
        textHaloWidth: 2.2,
        textAllowOverlap: false,
        textOptional: true,
      ),
      minzoom: 12,
    );
  }

  /// Oriented rectangle (GeoJSON ring) centred on a vehicle, [len] × [wid] metres.
  static List<List<double>> _box(double lat, double lon, double bearing, double len, double wid) {
    final b = bearing * math.pi / 180;
    final ux = math.sin(b), uy = math.cos(b); // along-track (east, north)
    final vx = math.cos(b), vy = -math.sin(b); // across-track
    final kx = 111320 * math.cos(lat * math.pi / 180), ky = 110540.0;
    List<double> pt(double a, double w) => [lon + (ux * a + vx * w) / kx, lat + (uy * a + vy * w) / ky];
    final h = len / 2, ww = wid / 2;
    return [pt(h, ww), pt(h, -ww), pt(-h, -ww), pt(-h, ww), pt(h, ww)];
  }

  static double _trainLength(String code) {
    if (code == 'B1') return 230;
    if (code.startsWith('TF')) return 10;
    if (code.startsWith('F')) return 35;
    if (code.startsWith('T')) return 55;
    if (code == 'M1A' || code == 'M1B') return 75;
    return 90;
  }

  Future<void> _pushLive() async {
    final c = _c;
    if (c == null || !_styleReady || _pushing || !mounted) return;
    _pushing = true;
    try {
      final cam = c.cameraPosition;
      final target = cam?.target ?? LatLng(widget.center.latitude, widget.center.longitude);
      _zoom = cam?.zoom ?? _zoom;
      // Exaggerate vehicles when zoomed out so they stay readable in 3D.
      final k = math.pow(2, 15.5 - _zoom).toDouble().clamp(1.0, 6.0);
      final radius = (6000 * math.pow(2, 14 - _zoom)).toDouble().clamp(1500.0, 25000.0);
      double dist(double lat, double lon) => _distM(target.latitude, target.longitude, lat, lon);

      final trainBoxes = <Map<String, dynamic>>[];
      final trainLabels = <Map<String, dynamic>>[];
      MetroTrainVehicle? follow;
      for (final t in _p.metroTrains) {
        if (t.id == _followId) follow = t;
        if (t.id != _selectedTrainId && dist(t.currentLat, t.currentLon) > radius) continue;
        final color = _hex(t.color);
        final selected = t.id == _selectedTrainId;
        trainBoxes.add({
          'type': 'Feature',
          'id': 'tr:${t.id}',
          'properties': {'color': selected ? '#fef08a' : color, 'h': 12 + 4 * k, 'b': 2},
          'geometry': {
            'type': 'Polygon',
            'coordinates': [_box(t.currentLat, t.currentLon, t.bearing, _trainLength(t.lineCode) * k, 9 * k)]
          },
        });
        trainLabels.add({
          'type': 'Feature',
          'id': 'tl:${t.id}',
          'properties': {'label': t.lineCode == 'B1' ? 'MARMARAY' : t.lineCode, 'color': color},
          'geometry': {
            'type': 'Point',
            'coordinates': [t.currentLon, t.currentLat]
          },
        });
      }

      final busDots = <Map<String, dynamic>>[];
      final busBoxes = <Map<String, dynamic>>[];
      final busRadius = math.min(radius, 3500.0);
      for (final b in _p.allBuses) {
        if (busDots.length >= 300) break;
        if (dist(b.lat, b.lon) > busRadius) continue;
        final color = _hex(b.speedColor);
        busDots.add({
          'type': 'Feature',
          'id': 'bus:${b.id}',
          'properties': {'color': color, 'line': b.line},
          'geometry': {
            'type': 'Point',
            'coordinates': [b.lon, b.lat]
          },
        });
        busBoxes.add({
          'type': 'Feature',
          'id': 'bb:${b.id}',
          'properties': {'color': color, 'h': 4 + 2 * k},
          'geometry': {
            'type': 'Polygon',
            'coordinates': [_box(b.lat, b.lon, b.bearing ?? 0, 13 * k, 4 * k)]
          },
        });
      }

      await c.setGeoJsonSource('ib-trains', {'type': 'FeatureCollection', 'features': trainBoxes});
      await c.setGeoJsonSource('ib-train-labels', {'type': 'FeatureCollection', 'features': trainLabels});
      await c.setGeoJsonSource('ib-buses', {'type': 'FeatureCollection', 'features': busDots});
      await c.setGeoJsonSource('ib-bus-boxes', {'type': 'FeatureCollection', 'features': busBoxes});

      if (follow != null) {
        // Ride along: camera sits behind the train looking down the track.
        await c.animateCamera(
          CameraUpdate.newCameraPosition(CameraPosition(
            target: LatLng(follow.currentLat, follow.currentLon),
            zoom: math.max(_zoom, 15.8),
            tilt: 68,
            bearing: follow.bearing,
          )),
          duration: const Duration(milliseconds: 950),
        );
      }
      if (mounted) setState(() {});
    } catch (_) {
      // Layer not ready during a style swap: next tick retries.
    } finally {
      _pushing = false;
    }
  }

  static double _distM(double lat1, double lon1, double lat2, double lon2) {
    final kx = 111320 * math.cos(lat1 * math.pi / 180);
    final dx = (lon2 - lon1) * kx, dy = (lat2 - lat1) * 110540;
    return math.sqrt(dx * dx + dy * dy);
  }

  void _onFeatureTap(math.Point<double> point, LatLng coords, String id, String layerId, Annotation? annotation) {
    if (id.startsWith('tr:') || id.startsWith('tl:')) {
      setState(() {
        _selectedTrainId = id.substring(3);
        _selectedStation = null;
      });
      _pushLive();
    } else if (id.startsWith('st:')) {
      final parts = id.split(':');
      final list = _p.metroStations[parts[1]];
      final idx = int.tryParse(parts.length > 2 ? parts[2] : '') ?? -1;
      if (list != null && idx >= 0 && idx < list.length) {
        setState(() {
          _selectedStation = list[idx];
          _selectedTrainId = null;
          _followId = null;
        });
        _flyToStation(list[idx]);
      }
    }
  }

  void _flyToStation(MetroStation st) {
    final list = _p.metroStations[st.lineCode] ?? const <MetroStation>[];
    final i = list.indexWhere((s) => s.name == st.name);
    var bearing = 0.0;
    if (i >= 0 && list.length > 1) {
      final a = list[math.max(0, i - 1)], b = list[math.min(list.length - 1, i + 1)];
      bearing = bearingDeg(a.lat, a.lon, b.lat, b.lon) - 90; // look across the platform
    }
    _c?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: LatLng(st.lat, st.lon), zoom: 16.6, tilt: 62, bearing: bearing)),
      duration: const Duration(milliseconds: 1400),
    );
  }

  Future<void> _toggleTilt() async {
    final cam = _c?.cameraPosition;
    if (cam == null) return;
    setState(() => _tilted = !_tilted);
    await _c!.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: cam.target, zoom: cam.zoom, tilt: _tilted ? 60 : 0, bearing: _tilted ? cam.bearing : 0)),
      duration: const Duration(milliseconds: 700),
    );
  }

  Future<void> _goToMe() async {
    final loc = _p.userLocation ?? await _p.locateUser();
    if (loc == null) return;
    setState(() => _followId = null);
    await _c?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: LatLng(loc.latitude, loc.longitude), zoom: 16.4, tilt: 60, bearing: _c?.cameraPosition?.bearing ?? 0)),
      duration: const Duration(milliseconds: 1000),
    );
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final train = _selectedTrainId == null ? null : _p.metroTrains.where((t) => t.id == _selectedTrainId).firstOrNull;
    return Scaffold(
      backgroundColor: _night ? const Color(0xFF090D16) : AppTheme.background,
      body: Stack(
        children: [
          MapLibreMap(
            key: ValueKey(_styles[_styleIdx]),
            styleString: _styles[_styleIdx],
            initialCameraPosition: CameraPosition(
              target: LatLng(widget.center.latitude, widget.center.longitude),
              zoom: widget.zoom,
              tilt: widget.tilt,
              bearing: widget.bearing,
            ),
            onMapCreated: (c) => _c = c,
            onStyleLoadedCallback: _onStyleLoaded,
            trackCameraPosition: true,
            compassEnabled: true,
            tiltGesturesEnabled: true,
            rotateGesturesEnabled: true,
            myLocationEnabled: _hasLocation,
            minMaxZoomPreference: const MinMaxZoomPreference(9, 19.5),
            onCameraIdle: () => _pushLive(),
            onMapClick: (_, _) {
              if (_selectedTrainId != null || _selectedStation != null) {
                setState(() {
                  _selectedTrainId = null;
                  _selectedStation = null;
                  _followId = null;
                });
              }
            },
          ),
          if (!_styleReady)
            const Center(child: CircularProgressIndicator(color: Color(0xFF38BDF8))),

          // Top bar
          Positioned(
            top: top + 8,
            left: 12,
            right: 12,
            child: Row(
              children: [
                _RoundButton(icon: Icons.arrow_back_rounded, night: _night, onTap: () => Navigator.of(context).pop()),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: (_night ? AppTheme.cardDark : Colors.white).withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: _night ? AppTheme.cardBorderDark : AppTheme.borderLight),
                    ),
                    child: Text(
                      _followId != null
                          ? 'Trenle birlikte ilerliyorsunuz'
                          : '3D Canlı Harita • ${_p.metroTrains.length} tren • ${_p.activeBusCount} otobüs',
                      style: TextStyle(
                        color: _night ? AppTheme.textLight : AppTheme.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Right controls
          Positioned(
            right: 12,
            top: top + 70,
            child: Column(
              children: [
                _RoundButton(
                  icon: _tilted ? Icons.threed_rotation_rounded : Icons.map_rounded,
                  label: _tilted ? '2D' : '3D',
                  night: _night,
                  onTap: _toggleTilt,
                ),
                const SizedBox(height: 10),
                _RoundButton(icon: Icons.my_location_rounded, night: _night, onTap: _goToMe),
              ],
            ),
          ),

          // Bottom card: selected train / station
          if (train != null || _selectedStation != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.of(context).padding.bottom + 14,
              child: train != null ? _trainCard(train) : _stationCard(_selectedStation!),
            ),
        ],
      ),
    );
  }

  Widget _cardShell(Widget child) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.cardDark.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.cardBorderDark),
          boxShadow: AppTheme.hudShadow,
        ),
        child: child,
      );

  Widget _trainCard(MetroTrainVehicle t) {
    final next = t.upcoming.isNotEmpty ? t.upcoming.first : null;
    final following = _followId == t.id;
    return _cardShell(Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _LineBadge(code: t.lineCode, color: t.color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '➔ ${t.headsign}',
                style: const TextStyle(color: AppTheme.textLight, fontWeight: FontWeight.w800, fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${t.currentSpeed.round()} km/s',
              style: const TextStyle(color: AppTheme.textMutedDark, fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<int>(
          valueListenable: _p.clock,
          builder: (_, _, _) {
            final sec = next == null ? 0 : math.max(0, next.at.difference(DateTime.now()).inSeconds);
            return Text(
              next == null
                  ? 'Son durakta'
                  : 'Sonraki: ${next.name} • ${BusVehicle.formatEta(sec)} (${istanbulClock(next.at)})',
              style: const TextStyle(color: Color(0xFFFEF08A), fontWeight: FontWeight.w700, fontSize: 13),
            );
          },
        ),
        const SizedBox(height: 4),
        Text(
          t.official ? 'Resmî tarifeye göre konum' : 'Tahmini konum (sefer planı)',
          style: TextStyle(color: t.official ? AppTheme.statusLive : const Color(0xFFFCD34D), fontSize: 11, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ActionChip(
                icon: following ? Icons.stop_circle_outlined : Icons.videocam_rounded,
                label: following ? 'Takibi Bırak' : 'Trenle İlerle',
                onTap: () {
                  setState(() => _followId = following ? null : t.id);
                  _pushLive();
                },
              ),
            ),
          ],
        ),
      ],
    ));
  }

  Widget _stationCard(MetroStation st) {
    final lines = _p.linesAtStation(st);
    return _cardShell(Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.subway_rounded, color: Color(0xFF38BDF8), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                st.name,
                style: const TextStyle(color: AppTheme.textLight, fontWeight: FontWeight.w800, fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            for (final l in lines.take(4))
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: _LineBadge(code: l.line, color: _p.getMetroLineColor(l.line), small: true),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _ActionChip(
          icon: Icons.departure_board_rounded,
          label: 'İstasyon Görünümü & Yol Tarifi',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => StationViewScreen(station: st))),
        ),
      ],
    ));
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String? label;
  final bool night;
  final VoidCallback onTap;

  const _RoundButton({required this.icon, required this.night, required this.onTap, this.label});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: night ? AppTheme.cardDark : Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: night ? AppTheme.cardBorderDark : AppTheme.borderLight, width: 1.2),
        ),
        child: Center(
          child: label != null
              ? Text(label!, style: TextStyle(color: night ? Colors.white : AppTheme.accentBlack, fontWeight: FontWeight.w900, fontSize: 13))
              : Icon(icon, color: night ? Colors.white : AppTheme.accentBlack, size: 22),
        ),
      ),
    );
  }
}

class _LineBadge extends StatelessWidget {
  final String code;
  final Color color;
  final bool small;

  const _LineBadge({required this.code, required this.color, this.small = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: small ? 2 : 4),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
      child: Text(
        code == 'B1' ? 'MARMARAY' : code,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: small ? 10 : 13),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionChip({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: AppTheme.accentBlack),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(color: AppTheme.accentBlack, fontWeight: FontWeight.w800, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
