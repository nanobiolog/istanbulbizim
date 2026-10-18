import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/network_models.dart';
import '../models/transit_models.dart';
import '../services/app_clock.dart';
import '../services/schedule_engine.dart';
import '../services/transit_provider.dart';
import '../theme/app_theme.dart';
import '../three_d/scene_views.dart';
import 'ar_navigation_screen.dart';
import 'map3d_screen.dart';
import 'station_view_screen.dart';
import 'station_walk_screen.dart';
import '../widgets/bus_stop_detail_sheet.dart';
import '../widgets/layers_bottom_sheet.dart';
import '../widgets/line_search_modal.dart';
import '../widgets/minimal_bottom_nav_card.dart';
import '../widgets/quick_action_pills.dart';
import '../widgets/settings_bottom_sheet.dart';
import '../widgets/station_sheet.dart';
import '../widgets/transit_sheets.dart';
import '../widgets/vehicle_showcase.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  late final MapController _mapController;
  late final AnimationController _pingPulseController;

  static final LatLng istanbulCenter = const LatLng(41.0082, 28.9784);
  static const double initialZoom = 12.4;
  double _currentZoom = initialZoom;
  LiveVessel? _liveSel;
  bool _deepLinkDone = false;

  /// ?istasyon=Yenikapı&hat=B1&gorunum=kesit|yuru  ·  ?iskele=Kadıköy  ·  ?saat=08:30
  void _handleDeepLink(TransitProvider provider) {
    if (_deepLinkDone || !provider.network.loaded) return;
    _deepLinkDone = true;
    if (provider.liteMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          duration: Duration(seconds: 8),
          content: Text('Hafif mod: tarayıcıda donanım hızlandırma (WebGL) kapalı, harita daha seyrek güncelleniyor. '
              'Daha akıcı kullanım için tarayıcı ayarlarından “donanım hızlandırma”yı açın.'),
        ));
      });
    }
    final q = Uri.base.queryParameters;
    AppClock.pinTimeOfDay(q['saat'] ?? q['time']);
    String fold(String s) => s
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('i̇', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c');
    final stName = q['istasyon'] ?? q['station'];
    final pierName = q['iskele'] ?? q['pier'];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (stName != null) {
        final want = fold(stName);
        final line = (q['hat'] ?? q['line'])?.toUpperCase();
        final code = line == null ? null : provider.railCodeFor(line);
        final cands = provider.network.stations.values.where((s) => fold(s.name) == want).toList()
          ..sort((a, b) => (code != null && b.lines.contains(code) ? 1 : 0) - (code != null && a.lines.contains(code) ? 1 : 0));
        if (cands.isEmpty) return;
        final st = cands.first;
        _openStation(provider, st, line: code != null && st.lines.contains(code) ? code : null);
        final view = q['gorunum'] ?? q['view'];
        if (view == 'kesit' || view == 'reveal') provider.toggleReveal(true);
        if ((view == 'yuru' || view == 'walk') && provider.engine != null && provider.selectedStationPlan != null) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => StationWalkScreen(plan: provider.selectedStationPlan!, repo: provider.network, engine: provider.engine!),
          ));
        }
      } else if ((q['hat'] ?? q['line']) != null && provider.railCodeFor(q['hat'] ?? q['line']!) != null) {
        _onPickLine(provider, q['hat'] ?? q['line']!);
      } else if (pierName != null) {
        final want = fold(pierName);
        int served(Pier p) => provider.network.ferryLines.where((l) => l.piers.contains(p.id)).length;
        final cands = provider.network.piers.values.where((p) => fold(p.name).startsWith(want)).toList()
          ..sort((a, b) => served(b).compareTo(served(a)));
        final p = cands.firstOrNull;
        if (p != null) _openPier(provider, p);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _pingPulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
  }

  @override
  void dispose() {
    _pingPulseController.dispose();
    super.dispose();
  }

  void _animatedMapMove(LatLng dest, double destZoom) {
    final latTween = Tween<double>(begin: _mapController.camera.center.latitude, end: dest.latitude);
    final lngTween = Tween<double>(begin: _mapController.camera.center.longitude, end: dest.longitude);
    final zoomTween = Tween<double>(begin: _mapController.camera.zoom, end: destZoom);
    final controller = AnimationController(duration: const Duration(milliseconds: 520), vsync: this);
    final animation = CurvedAnimation(parent: controller, curve: Curves.fastOutSlowIn);
    controller.addListener(() {
      _mapController.move(LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)), zoomTween.evaluate(animation));
    });
    animation.addStatusListener((status) {
      if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) controller.dispose();
    });
    controller.forward();
  }

  /// Moves so [p] sits in the visible area above a bottom sheet of [sheetFraction] of the screen.
  void _focusAbove(LatLng p, double zoom, {double sheetFraction = 0.5}) {
    final h = MediaQuery.of(context).size.height;
    final px = h * sheetFraction / 2;
    final mpp = 156543.03392 * math.cos(p.latitude * math.pi / 180) / math.pow(2, zoom);
    final dLat = px * mpp / 111320.0;
    _animatedMapMove(LatLng(p.latitude - dLat, p.longitude), zoom);
  }

  void _openSearch(TransitProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LineSearchModal(
        popularLines: provider.popularLines,
        onSelectLine: (line) => _onPickLine(provider, line),
      ),
    );
  }

  void _onPickLine(TransitProvider provider, String line) {
    final rail = provider.railCodeFor(line);
    if (rail != null) {
      provider.selectRailLine(rail);
      _fitPoints(provider.network.lineByCode[rail]!.variants.first.path.points, bottomPad: 380);
      return;
    }
    provider.selectLine(line);
    Future.delayed(const Duration(milliseconds: 350), () => _fitLineRouteOnMap(provider));
  }

  void _fitPoints(List<LatLng> pts, {double bottomPad = 240}) {
    if (pts.length < 2) return;
    _mapController.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(pts),
      padding: EdgeInsets.only(top: 120, bottom: bottomPad, left: 40, right: 70),
    ));
  }

  void _openSheet(Widget Function(BuildContext) builder) {
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent, builder: builder);
  }

  // ─── 3D live map · station view (walking route) · AR wayfinding ───
  void _open3D(TransitProvider provider, {String? followTrainId, MetroStation? station, LatLng? center}) {
    final cam = _mapController.camera;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Map3DScreen(
        center: station != null ? LatLng(station.lat, station.lon) : (center ?? cam.center),
        zoom: math.max(cam.zoom, 14.8),
        followTrainId: followTrainId,
        focusStation: station,
      ),
    ));
  }

  /// The timetable station (old station list) that corresponds to a network station.
  MetroStation? _metroStationFor(TransitProvider provider, NetworkStation st, String? line) {
    MetroStation? best;
    var bd = 800.0;
    provider.metroStations.forEach((code, list) {
      if (line != null && provider.metroStations.containsKey(line) && code != line) return;
      for (final m in list) {
        final d = haversine(st.pos.latitude, st.pos.longitude, m.lat, m.lon);
        if (d < bd) {
          bd = d;
          best = m;
        }
      }
    });
    return best;
  }

  void _openStationView(MetroStation st) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => StationViewScreen(station: st)));
  }

  /// The timetable train closest to a scheduled train (for the 3D "ride along" camera).
  String? _followIdFor(TransitProvider provider, ScheduledTrain t) {
    String? id;
    var bd = 1500.0;
    for (final m in provider.metroTrains) {
      if (m.lineCode != t.line.code) continue;
      final d = haversine(t.pos.latitude, t.pos.longitude, m.currentLat, m.currentLon);
      if (d < bd) {
        bd = d;
        id = m.id;
      }
    }
    return id;
  }

  /// AR toward the selected stop, else the nearest rail station (or stop) to the user.
  Future<void> _openAr(TransitProvider provider) async {
    final stop = provider.selectedStop;
    if (stop != null) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ArNavigationScreen(targetName: stop.name, target: LatLng(stop.lat, stop.lon), targetStop: stop),
      ));
      return;
    }
    final me = provider.userLocation ?? await provider.locateUser();
    if (!mounted) return;
    if (me == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('AR yol tarifi için konum izni gerekli.')));
      return;
    }
    final st = provider.nearestStations(me, limit: 1, maxM: 4000);
    if (st.isNotEmpty) {
      final s = st.first.station;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ArNavigationScreen(targetName: s.name, target: LatLng(s.lat, s.lon), targetLine: s.lineCode),
      ));
      return;
    }
    final bs = provider.nearestBusStops(me, limit: 1, maxM: 1500);
    if (bs.isNotEmpty) {
      final b = bs.first.stop;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ArNavigationScreen(targetName: b.name, target: LatLng(b.lat, b.lon), targetStop: b),
      ));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Yakında istasyon veya durak bulunamadı.')));
  }

  void _fitLineRouteOnMap(TransitProvider provider) {
    final route = provider.selectedLineRoute;
    if (route == null || route.directions.isEmpty) return;
    final all = <LatLng>[];
    route.directions.forEach((_, dir) {
      for (final stop in dir.stops) {
        all.add(LatLng(stop.lat, stop.lon));
      }
    });
    _fitPoints(all, bottomPad: 220);
  }

  void _openStation(TransitProvider provider, NetworkStation st, {String? line}) {
    _liveSel = null;
    provider.selectStation(st, line: line);
    _focusAbove(st.pos, math.max(_currentZoom, 15.6), sheetFraction: 0.62);
  }

  void _openPier(TransitProvider provider, Pier pier) {
    _liveSel = null;
    provider.selectPier(pier);
    _focusAbove(pier.pos, math.max(_currentZoom, 15.0), sheetFraction: 0.6);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TransitProvider>();
    _handleDeepLink(provider);
    if (provider.hasDetailSelection) _liveSel = null;
    final night = provider.isNightMode;
    final reveal = provider.revealStation;
    final plan = provider.selectedStationPlan;
    final wide = MediaQuery.of(context).size.width > 760;

    return Scaffold(
      backgroundColor: night ? const Color(0xFF090D16) : AppTheme.background,
      body: Stack(
        children: [
          // ─── 1. MAP ───
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: istanbulCenter,
              initialZoom: initialZoom,
              minZoom: 8.0,
              maxZoom: 19,
              interactionOptions: InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                cursorKeyboardRotationOptions: CursorKeyboardRotationOptions.disabled(),
              ),
              onMapReady: () {
                final c = _mapController.camera;
                provider.updateCameraPosition(c.center, c.zoom);
              },
              onPositionChanged: (camera, _) {
                _currentZoom = camera.zoom;
                provider.updateCameraPosition(camera.center, camera.zoom);
              },
              onTap: (_, _) {
                if (provider.hasDetailSelection || _liveSel != null) {
                  setState(() => _liveSel = null);
                  provider.clearAllSelections();
                } else if (provider.selectedRailLine != null) {
                  provider.selectRailLine(null);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: provider.tileUrl,
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.istanbulbizim.mobile_app',
                maxZoom: 19,
              ),
              if (provider.showFerries && (!provider.liteMode || _currentZoom >= 12)) PolylineLayer(polylines: _ferryPolylines(provider)),
              if (provider.showProjects) PolylineLayer(polylines: _projectPolylines(provider)),
              if (provider.showMetroLines) PolylineLayer(polylines: _railPolylines(provider)),
              if (provider.selectedLineRoute != null) PolylineLayer(polylines: _buildLineRoutePolylines(provider)),
              if (provider.showBusStops && provider.selectedLineRoute == null) MarkerLayer(markers: _buildGeneralBusStopMarkers(provider)),
              if (provider.selectedLineRoute != null) MarkerLayer(markers: _buildLineBusStopMarkers(provider)),
              if (provider.showProjects && _currentZoom >= 11.5) MarkerLayer(markers: _projectStationMarkers(provider)),
              if (provider.showFerries && _currentZoom >= 12.3) MarkerLayer(markers: _pierMarkers(provider)),
              if (provider.showMetroLines && _currentZoom >= 11) MarkerLayer(markers: _stationMarkers(provider)),
              if (provider.showEntrances && _currentZoom >= 16) MarkerLayer(markers: _entranceMarkers(provider)),
              // Moving vehicles repaint on their own tick; nothing else rebuilds when they move.
              ValueListenableBuilder<int>(
                valueListenable: provider.vehicleTick,
                builder: (context, _, _) => MarkerLayer(markers: [
                  if (provider.showMetroLines && provider.showMetroTrains && _currentZoom >= 11.3) ..._trainMarkers(provider),
                  if (provider.showFerries && _currentZoom >= 10.5) ..._vesselMarkers(provider),
                ]),
              ),
              if (provider.showBuses) MarkerLayer(markers: _buildBusMarkers(provider)),
              if (provider.userLocation != null)
                MarkerLayer(markers: [
                  Marker(point: provider.userLocation!, width: 44, height: 44, child: _buildUserLocationMarker()),
                ]),
            ],
          ),

          // ─── 2. STATION CUT-AWAY (Reveal) ───
          if (reveal && plan != null && provider.engine != null)
            Positioned.fill(
              child: StationRevealView(plan: plan, engine: provider.engine!, focus: provider.revealFocus, night: night),
            ),

          // ─── 3. OFFLINE BANNER ───
          if (provider.isOffline)
            Positioned(
              top: MediaQuery.of(context).padding.top + 4,
              left: 14,
              right: 14,
              child: _offlineBanner(provider),
            ),

          // ─── 4. SEARCH + NEARBY LINES ───
          if (!reveal)
            Positioned(
              top: MediaQuery.of(context).padding.top + (provider.isOffline ? 52 : 8),
              left: 0,
              right: 64,
              child: QuickActionPills(
                nearbyLines: provider.nearbyBusLines,
                selectedLine: provider.selectedLineCode ?? provider.selectedRailLine?.code,
                onSelectLine: (line) => _onPickLine(provider, line),
                onClearLine: () {
                  provider.selectRailLine(null);
                  provider.selectLine(null);
                },
                onSearchTap: () => _openSearch(provider),
                showMetro: provider.showMetroLines,
                onToggleMetro: () => provider.toggleMetroLines(),
                showTrains: provider.showMetroTrains,
                onToggleTrains: () => provider.toggleMetroTrains(),
                isNightMode: night,
              ),
            ),

          // ─── 5. RIGHT CONTROL RAIL ───
          Positioned(
            right: 12,
            top: MediaQuery.of(context).padding.top + (provider.isOffline ? 52 : 8),
            child: _ControlRail(
              night: night,
              reveal: reveal,
              wide: wide,
              onSettings: () => _openSheet((_) => SettingsBottomSheet(provider: provider, onClose: () => Navigator.pop(context))),
              onLayers: () => _openSheet((_) => LayersBottomSheet(provider: provider, onClose: () => Navigator.pop(context))),
              onTheme: provider.toggleNightMode,
              on3d: () {
                if (provider.selectedStation != null) {
                  provider.toggleReveal();
                  return;
                }
                final st = provider.network.nearestStation(_mapController.camera.center, maxM: 4000);
                if (st != null) {
                  _openStation(provider, st);
                  provider.toggleReveal(true);
                }
              },
              onFit: () {
                provider.clearAllSelections();
                _animatedMapMove(istanbulCenter, 11.2);
              },
              onZoomIn: () => _animatedMapMove(_mapController.camera.center, math.min(_mapController.camera.zoom + 1, 19)),
              onZoomOut: () => _animatedMapMove(_mapController.camera.center, math.max(_mapController.camera.zoom - 1, 8)),
              onLocate: () async {
                final loc = await provider.locateUser();
                _animatedMapMove(loc ?? istanbulCenter, loc != null ? 15.5 : initialZoom);
              },
              on3dMap: () => _open3D(provider),
              onAr: () => _openAr(provider),
            ),
          ),

          // ─── 6. BOTTOM SHEETS ───
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (child, anim) => SlideTransition(
                    position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(anim),
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(_sheetKey(provider)),
                    child: ValueListenableBuilder<int>(
                      valueListenable: provider.clock,
                      builder: (context, _, _) => _bottomSheet(provider),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _sheetKey(TransitProvider p) {
    if (p.selectedStation != null) return 'st-${p.selectedStation!.id}';
    if (p.selectedPier != null) return 'pier-${p.selectedPier!.id}';
    if (_liveSel != null) return 'ais-${_liveSel!.mmsi}';
    if (p.selectedVessel != null) return 'vessel';
    if (p.selectedTrain != null) return 'train';
    if (p.selectedStop != null) return 'stop';
    if (p.selectedRailLine != null) return 'rail-${p.selectedRailLine!.code}';
    return 'nav';
  }

  Widget _bottomSheet(TransitProvider provider) {
    if (provider.selectedStation != null && provider.selectedStationPlan != null) {
      return StationSheet(
        provider: provider,
        onClose: () => provider.selectStation(null),
        onFocusMap: (p) {
          provider.toggleReveal(false);
          _focusAbove(LatLng(p.lat, p.lon), 17.2, sheetFraction: 0.6);
        },
        onOpenStationView: () {
          final ms = _metroStationFor(provider, provider.selectedStation!, provider.selectedStationLine?.code);
          if (ms != null) _openStationView(ms);
        },
      );
    }
    if (provider.selectedPier != null) return PierSheet(provider: provider, onClose: () => provider.selectPier(null));
    if (_liveSel != null) {
      return LiveVesselSheet(vessel: _liveSel!, provider: provider, onClose: () => setState(() => _liveSel = null));
    }
    if (provider.selectedVessel != null) {
      return VesselSheet(
        provider: provider,
        onClose: () => provider.selectVessel(null),
        onOpenPier: (p) => _openPier(provider, p),
      );
    }
    if (provider.selectedTrain != null) {
      return TrainSheet(
        provider: provider,
        onClose: () => provider.selectScheduledTrain(null),
        onOpenStation: (st) => _openStation(provider, st, line: provider.selectedTrain?.line.code),
        onFollow3D: () {
          final t = provider.selectedTrain;
          if (t != null) _open3D(provider, followTrainId: _followIdFor(provider, t), center: t.pos);
        },
      );
    }
    if (provider.selectedStop != null) {
      return BusStopDetailSheet(
        stop: provider.selectedStop!,
        provider: provider,
        onClose: () => provider.selectBusStop(null),
        onOpenAr: () => _openAr(provider),
        onSelectLine: (line) {
          provider.selectBusStop(null);
          _onPickLine(provider, line);
        },
      );
    }
    if (provider.selectedRailLine != null) {
      return RailLineSheet(
        provider: provider,
        onClose: () => provider.selectRailLine(null),
        onOpenStation: (st) => _openStation(provider, st, line: provider.selectedRailLine?.code),
      );
    }
    return MinimalBottomNavCard(
      selectedBus: provider.selectedBus,
      activeLine: provider.selectedLineCode,
      routeDetails: provider.selectedLineRoute,
      visibleBusCount: provider.visibleBuses.length,
      totalBusCount: provider.activeBusCount,
      selectedDirection: provider.selectedDirection,
      lastUpdated: provider.lastUpdated,
      isNightMode: provider.isNightMode,
      timetable: provider.selectedLineTimetable,
      isLoadingTimetable: provider.isLoadingTimetable,
      onToggleTimetable: () {
        final line = provider.selectedBus?.line ?? provider.selectedLineCode;
        if (line != null && line.isNotEmpty) provider.loadTimetableForLine(line);
      },
      onDirectionChanged: (dir) => provider.setDirectionFilter(dir),
      onClearSelection: () {
        if (provider.selectedBus != null) {
          provider.selectBus(null);
        } else {
          provider.selectLine(null);
        }
      },
      onSearchTap: () => _openSearch(provider),
      vehicleMedia: provider.selectedBus == null
          ? null
          : VehicleShowcase(
              look: VehicleLook.bus(provider.selectedBus!.line),
              photos: provider.network.photos(VehicleLook.bus(provider.selectedBus!.line).mediaKey),
              height: 140,
            ),
    );
  }

  Widget _offlineBanner(TransitProvider provider) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.accentBlack.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        ),
        child: Row(children: [
          const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              provider.lastSuccessfulSync != null
                  ? 'Çevrimdışı · son veri ${provider.lastSuccessfulSync!.hour.toString().padLeft(2, '0')}:${provider.lastSuccessfulSync!.minute.toString().padLeft(2, '0')} · tren ve vapur tarifeleri çalışıyor'
                  : 'Çevrimdışı · tren ve vapur tarifeleri çalışıyor',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          GestureDetector(
            onTap: () => provider.refreshFleet(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
              child: const Text('Tekrar Dene', style: TextStyle(color: AppTheme.accentBlack, fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      );

  // ─── viewport culling ───
  bool _inView(LatLng p, {double pad = 0.15}) {
    final b = _mapController.camera.visibleBounds;
    final dLat = (b.north - b.south) * pad, dLon = (b.east - b.west) * pad;
    return p.latitude >= b.south - dLat && p.latitude <= b.north + dLat && p.longitude >= b.west - dLon && p.longitude <= b.east + dLon;
  }

  // Polylines change only with zoom bucket / selection / theme: cache them so flutter_map gets the
  // same objects between rebuilds instead of re-creating hundreds of thousands of points.
  final Map<String, List<Polyline>> _polyCache = {};
  List<Polyline> _cachedPolys(String key, List<Polyline> Function() build) {
    final hit = _polyCache[key];
    if (hit != null) return hit;
    if (_polyCache.length > 24) _polyCache.clear();
    return _polyCache[key] = build();
  }

  String get _zoomBucket => _currentZoom < 11 ? 'a' : (_currentZoom < 12 ? 'b' : (_currentZoom < 13 ? 'c' : (_currentZoom < 15 ? 'd' : 'e')));

  // ─── RAIL ───
  List<Polyline> _railPolylines(TransitProvider provider) => _cachedPolys(
      'rail|$_zoomBucket|${provider.selectedRailLine?.code}|${provider.selectedStation?.id}|${provider.isNightMode}|${provider.network.lines.length}',
      () => _buildRailPolylines(provider));

  List<Polyline> _buildRailPolylines(TransitProvider provider) {
    final out = <Polyline>[];
    final z = _currentZoom;
    final hl = provider.selectedRailLine?.code;
    final selSt = provider.selectedStation;
    final w = z < 11 ? 2.4 : (z < 13 ? 3.4 : (z < 15 ? 4.6 : 6.0));
    for (final line in provider.network.lines) {
      final dim = (hl != null && hl != line.code) || (selSt != null && !selSt.lines.contains(line.code));
      final color = dim ? line.color.withValues(alpha: 0.28) : line.color;
      final width = line.isMarmaray ? w * 1.25 : (line.mode == RailMode.tram ? w * 0.8 : w);
      final drawn = <String>{};
      for (final v in line.variants) {
        // one polyline per distinct corridor (main + branches / short-turns that leave it)
        final key = v.stops.map((s) => s.stationId).toSet().difference(drawn);
        if (drawn.isNotEmpty && key.length < 2) continue;
        drawn.addAll(v.stops.map((s) => s.stationId));
        out.add(Polyline(
          points: v.path.points,
          strokeWidth: width,
          color: color,
          borderStrokeWidth: z >= 13 && !dim ? 1.4 : 0,
          borderColor: provider.isNightMode ? const Color(0xCC0B1220) : Colors.white.withValues(alpha: 0.9),
          pattern: line.mode == RailMode.cable ? const StrokePattern.dotted() : const StrokePattern.solid(),
        ));
      }
    }
    // Marmaray on top (it shares corridors with T6/M11 at Halkalı / Kazlıçeşme)
    out.sort((a, b) => a.strokeWidth.compareTo(b.strokeWidth));
    return out;
  }

  List<Marker> _stationMarkers(TransitProvider provider) {
    final out = <Marker>[];
    final z = _currentZoom;
    final net = provider.network;
    final hl = provider.selectedRailLine?.code;
    final showLabel = z >= (provider.liteMode ? 15.0 : 14.2);
    for (final st in net.stations.values) {
      if (!_inView(st.pos)) continue;
      if (hl != null && !st.lines.contains(hl) && z < 14) continue;
      final selected = provider.selectedStation?.id == st.id;
      final colors = st.lines.map((c) => net.lineByCode[c]?.color ?? Colors.grey).toList();
      final interchange = st.lines.length > 1;
      if (!interchange && z < 12.2 && !selected) continue;
      final size = selected ? 26.0 : (interchange ? (z < 13 ? 14.0 : 18.0) : (z < 13 ? 10.0 : 14.0));
      final dot = Container(
        width: interchange ? size + (colors.length - 1) * 6 : size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(size),
          border: Border.all(color: selected ? AppTheme.accentBlack : (interchange ? AppTheme.accentBlack : colors.first), width: selected ? 3 : 2.4),
          boxShadow: selected ? const [BoxShadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 1))] : null,
        ),
        child: interchange && size >= 14
            ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (final c in colors.take(5)) Container(width: 4.5, height: 4.5, margin: const EdgeInsets.symmetric(horizontal: 0.6), decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              ])
            : null,
      );
      final label = showLabel || selected
          ? Container(
              margin: const EdgeInsets.only(left: 4),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                color: provider.isNightMode ? const Color(0xE60F172A) : Colors.white.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: colors.first.withValues(alpha: 0.6)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(st.name,
                    style: TextStyle(
                        color: provider.isNightMode ? Colors.white : AppTheme.textPrimary, fontSize: 11.5, fontWeight: FontWeight.w800)),
                if (z >= 15.5 && st.kind == StationKind.underground) ...[
                  const SizedBox(width: 4),
                  Text('${st.depth.round()} m', style: TextStyle(color: colors.first, fontSize: 10.5, fontWeight: FontWeight.w800)),
                ],
              ]),
            )
          : null;
      out.add(Marker(
        point: st.pos,
        width: label == null ? 46 : 220,
        height: 30,
        alignment: label == null ? Alignment.center : const Alignment(0.79, 0),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => _openStation(provider, st, line: hl != null && st.lines.contains(hl) ? hl : null),
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: label == null ? MainAxisAlignment.center : MainAxisAlignment.start, children: [
            if (label != null) const SizedBox(width: 0),
            dot,
            ?label,
          ]),
        ),
      ));
    }
    return out;
  }

  List<Marker> _entranceMarkers(TransitProvider provider) {
    final out = <Marker>[];
    final sel = provider.selectedStation;
    for (final st in provider.network.stations.values) {
      if (st.entrances.isEmpty || !_inView(st.pos, pad: 0.05)) continue;
      if (sel != null && sel.id != st.id && _currentZoom < 17) continue;
      for (var i = 0; i < st.entrances.length; i++) {
        final e = st.entrances[i];
        final label = e.ref.isNotEmpty ? 'Giriş ${e.ref}' : (e.name.isNotEmpty ? e.label : 'Giriş ${i + 1}');
        out.add(Marker(
          point: e.pos,
          width: 120,
          height: 26,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(13),
                boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(e.wheelchair ? Icons.accessible_rounded : Icons.directions_walk_rounded, size: 13, color: AppTheme.accentBlack),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(label,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.accentBlack, fontSize: 11, fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
          ),
        ));
      }
    }
    return out;
  }

  List<Marker> _trainMarkers(TransitProvider provider) {
    final out = <Marker>[];
    final z = _currentZoom;
    final hl = provider.selectedRailLine?.code;
    final selId = provider.selectedTrain?.id;
    final detailed = z >= 15;
    for (final t in provider.scheduledTrains) {
      if (!_inView(t.pos, pad: 0.05)) continue;
      if (hl != null && t.line.code != hl) continue;
      final sel = t.id == selId;
      if (z < (provider.liteMode ? 14.5 : 13.4) && !sel) {
        out.add(Marker(
          point: t.pos,
          width: 18,
          height: 18,
          child: GestureDetector(
            onTap: () {
              _liveSel = null;
              provider.selectScheduledTrain(t);
              _focusAbove(t.pos, 14.5, sheetFraction: 0.55);
            },
            child: Center(
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: t.line.color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.8),
                ),
              ),
            ),
          ),
        ));
        continue;
      }
      final text = detailed
          ? '${t.line.code} · ${t.atStation ? 'istasyonda' : formatCountdown(Duration(seconds: t.etaSec.round()))}'
          : t.line.code;
      out.add(Marker(
        point: t.pos,
        width: detailed ? 150 : 64,
        height: 28,
        child: GestureDetector(
          onTap: () {
            _liveSel = null;
            provider.selectScheduledTrain(t);
            _focusAbove(t.pos, math.max(z, 14.5), sheetFraction: 0.55);
          },
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
              decoration: BoxDecoration(
                color: t.line.color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: sel ? const Color(0xFFFDE047) : Colors.white, width: sel ? 2.4 : 1.6),
                boxShadow: sel ? [BoxShadow(color: t.line.color.withValues(alpha: 0.45), blurRadius: 12, offset: const Offset(0, 2))] : null,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Transform.rotate(
                  angle: (t.heading - 90) * math.pi / 180,
                  child: Icon(t.atStation ? Icons.pause_rounded : Icons.arrow_forward_rounded, size: 11, color: Colors.white),
                ),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(text,
                      maxLines: 1, overflow: TextOverflow.clip,
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900)),
                ),
              ]),
            ),
          ),
        ),
      ));
    }
    return out;
  }

  // ─── FERRIES ───
  List<Polyline> _ferryPolylines(TransitProvider provider) => _cachedPolys(
      'ferry|${_currentZoom < 12}|${provider.selectedPier?.id}|${provider.selectedVessel?.trip.hashCode}',
      () => _buildFerryPolylines(provider));

  List<Polyline> _buildFerryPolylines(TransitProvider provider) {
    final out = <Polyline>[];
    final net = provider.network;
    final sel = provider.selectedVessel;
    final selPier = provider.selectedPier?.id;
    final w = _currentZoom < 12 ? 1.3 : 2.2;
    for (final e in net.legs.entries) {
      if (e.value.length < 2) continue;
      final ids = e.key.split('|');
      final ops = {...?net.piers[ids[0]]?.operators, ...?net.piers[ids[1]]?.operators};
      final onlyPrivate = !ops.contains('sh');
      final hot = selPier != null && ids.contains(selPier);
      out.add(Polyline(
        points: e.value,
        strokeWidth: hot ? w + 1.2 : w,
        color: (hot ? const Color(0xFF0EA5E9) : (onlyPrivate ? const Color(0xFF14B8A6) : const Color(0xFF3B82F6)))
            .withValues(alpha: hot ? 0.95 : (_currentZoom < 12 ? 0.32 : 0.48)),
        pattern: StrokePattern.dashed(segments: const [9, 6]),
      ));
    }
    if (sel != null) {
      for (var i = 0; i < sel.trip.piers.length - 1; i++) {
        out.add(Polyline(
          points: net.legPath(sel.trip.piers[i], sel.trip.piers[i + 1]),
          strokeWidth: 4,
          color: sel.op?.color ?? const Color(0xFF0B5CAD),
        ));
      }
    }
    return out;
  }

  List<Marker> _pierMarkers(TransitProvider provider) {
    final out = <Marker>[];
    final net = provider.network;
    final showLabel = _currentZoom >= 14;
    for (final p in net.piers.values) {
      if (!_inView(p.pos)) continue;
      final op = net.operators[p.operators.first];
      final selected = provider.selectedPier?.id == p.id;
      final color = op?.color ?? const Color(0xFF0B5CAD);
      out.add(Marker(
        point: p.pos,
        width: showLabel || selected ? 180 : 30,
        height: 30,
        alignment: showLabel || selected ? const Alignment(0.83, 0) : Alignment.center,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => _openPier(provider, p),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: selected ? 26 : 20,
              height: selected ? 26 : 20,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Icon(Icons.anchor_rounded, size: selected ? 15 : 12, color: Colors.white),
            ),
            if (showLabel || selected)
              Flexible(
                child: Container(
                  margin: const EdgeInsets.only(left: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: provider.isNightMode ? const Color(0xE60F172A) : Colors.white.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${p.name}${op != null && op.id != 'sh' ? ' · ${op.short}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: provider.isNightMode ? Colors.white : AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
        ),
      ));
    }
    return out;
  }

  List<Marker> _vesselMarkers(TransitProvider provider) {
    final out = <Marker>[];
    final net = provider.network;
    final live = provider.liveVessels;
    final selId = provider.selectedVessel?.id;
    Widget boat(Color color, double heading, String text, bool sel, {bool liveDot = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sel ? const Color(0xFFFDE047) : Colors.white, width: sel ? 2.4 : 1.6),
            boxShadow: sel ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 6, offset: const Offset(0, 2))] : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Transform.rotate(
              angle: heading * math.pi / 180,
              child: const Icon(Icons.navigation_rounded, size: 11, color: Colors.white),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.directions_boat_filled_rounded, size: 12, color: Colors.white),
            if (text.isNotEmpty) ...[
              const SizedBox(width: 3),
              Flexible(
                child: Text(text,
                    maxLines: 1, overflow: TextOverflow.clip, style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w800)),
              ),
            ],
            if (liveDot) ...[
              const SizedBox(width: 3),
              Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFF4ADE80), shape: BoxShape.circle)),
            ],
          ]),
        );
    if (live.isNotEmpty) {
      for (final v in live) {
        if (!_inView(v.pos, pad: 0.05)) continue;
        final op = net.operators[v.operatorId];
        out.add(Marker(
          point: v.pos,
          width: _currentZoom >= 14 ? 140 : 48,
          height: 26,
          child: GestureDetector(
            onTap: () {
              provider.clearAllSelections();
              setState(() => _liveSel = v);
            },
            child: Center(
                child: boat(op?.color ?? const Color(0xFF0B5CAD), v.cog, _currentZoom >= 14 ? v.name : '', _liveSel?.mmsi == v.mmsi,
                    liveDot: true)),
          ),
        ));
      }
      return out;
    }
    for (final v in provider.scheduledVessels) {
      if (!_inView(v.pos, pad: 0.05)) continue;
      final sel = v.id == selId;
      final dest = net.piers[v.trip.piers.last]?.name ?? '';
      if (_currentZoom < 12.8 && !sel) {
        if (v.docked) continue;
        out.add(Marker(
          point: v.pos,
          width: 20,
          height: 20,
          child: GestureDetector(
            onTap: () {
              provider.selectVessel(v);
              _focusAbove(v.pos, 13.5, sheetFraction: 0.55);
            },
            child: Center(
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: v.op?.color ?? const Color(0xFF0B5CAD),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.6),
                ),
                child: const Icon(Icons.directions_boat_filled_rounded, size: 8, color: Colors.white),
              ),
            ),
          ),
        ));
        continue;
      }
      out.add(Marker(
        point: v.pos,
        width: _currentZoom >= 14 ? 150 : 46,
        height: 26,
        child: GestureDetector(
          onTap: () {
            _liveSel = null;
            provider.selectVessel(v);
            _focusAbove(v.pos, math.max(_currentZoom, 13.5), sheetFraction: 0.55);
          },
          child: Center(child: boat(v.op?.color ?? const Color(0xFF0B5CAD), v.heading, _currentZoom >= 14 ? '→ $dest' : '', sel)),
        ),
      ));
    }
    return out;
  }

  // ─── PROJECTS (rail under construction) ───
  List<Polyline> _projectPolylines(TransitProvider provider) =>
      _cachedPolys('proj|${_currentZoom < 12}', () => _buildProjectPolylines(provider));

  List<Polyline> _buildProjectPolylines(TransitProvider provider) => [
        for (final p in provider.network.projects)
          for (final seg in p.segments)
            Polyline(
              points: seg,
              strokeWidth: _currentZoom < 12 ? 2.4 : 3.6,
              color: p.color.withValues(alpha: 0.85),
              pattern: StrokePattern.dashed(segments: const [6, 5]),
            ),
      ];

  List<Marker> _projectStationMarkers(TransitProvider provider) {
    final out = <Marker>[];
    for (final p in provider.network.projects) {
      for (final (name, pos) in p.stations) {
        if (!_inView(pos)) continue;
        out.add(Marker(
          point: pos,
          width: _currentZoom >= 14 ? 170 : 16,
          height: 22,
          alignment: _currentZoom >= 14 ? const Alignment(0.82, 0) : Alignment.center,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: p.color, width: 2.4),
              ),
            ),
            if (_currentZoom >= 14)
              Flexible(
                child: Container(
                  margin: const EdgeInsets.only(left: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(6)),
                  child: Text('$name · inşaat',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFF374151), fontSize: 10, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
        ));
      }
    }
    return out;
  }

  // ─── BUSES (unchanged behaviour) ───
  List<Marker> _buildBusMarkers(TransitProvider provider) {
    final markers = <Marker>[];
    for (final bus in provider.visibleBuses) {
      final isSelected = provider.selectedBus?.id == bus.id;
      final point = LatLng(bus.lat, bus.lon);
      markers.add(Marker(
        point: point,
        width: isSelected ? 52 : 42,
        height: isSelected ? 52 : 42,
        alignment: Alignment.center,
        child: GestureDetector(
          onTap: () {
            _liveSel = null;
            provider.selectBus(bus);
            _animatedMapMove(point, 15.5);
          },
          child: _buildBusMarkerWidget(bus, isSelected),
        ),
      ));
    }
    return markers;
  }

  Widget _buildBusMarkerWidget(BusVehicle bus, bool isSelected) {
    final hasBearing = bus.bearing != null && bus.speed > 2.0;
    return Stack(alignment: Alignment.center, children: [
      if (hasBearing)
        Transform.rotate(
          angle: (bus.bearing! * math.pi / 180),
          child: Align(
            alignment: Alignment.topCenter,
            child: Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : AppTheme.accentBlack,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 3)],
              ),
            ),
          ),
        ),
      Container(
        width: isSelected ? 44 : 34,
        height: isSelected ? 44 : 34,
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.accentBlack : Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isSelected ? 0.35 : 0.18),
              blurRadius: isSelected ? 10 : 5,
              spreadRadius: isSelected ? 2 : 0,
              offset: const Offset(0, 2),
            ),
          ],
          border: Border.all(color: isSelected ? Colors.white : AppTheme.accentBlack, width: isSelected ? 2.5 : 1.8),
        ),
        child: Center(
          child: bus.line.isNotEmpty
              ? Text(bus.line,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                      color: isSelected ? Colors.white : AppTheme.accentBlack, fontSize: bus.line.length > 3 ? 9 : 11, fontWeight: FontWeight.w900))
              : Icon(Icons.directions_bus_rounded, color: isSelected ? Colors.white : AppTheme.accentBlack, size: 16),
        ),
      ),
      Positioned(
        bottom: 1,
        right: 1,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: bus.speedColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: [BoxShadow(color: bus.speedColor.withValues(alpha: 0.6), blurRadius: 3)],
          ),
        ),
      ),
    ]);
  }

  Widget _buildUserLocationMarker() {
    return AnimatedBuilder(
      animation: _pingPulseController,
      builder: (context, child) {
        final scale = 0.75 + (_pingPulseController.value * 0.5);
        final opacity = (1.0 - _pingPulseController.value).clamp(0.0, 1.0);
        return Stack(alignment: Alignment.center, children: [
          Transform.scale(
            scale: scale,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: const Color(0xFF007AFF).withValues(alpha: opacity * 0.38), shape: BoxShape.circle),
            ),
          ),
          Container(width: 26, height: 26, decoration: BoxDecoration(color: const Color(0xFF007AFF).withValues(alpha: 0.22), shape: BoxShape.circle)),
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: const Color(0xFF007AFF).withValues(alpha: 0.55), blurRadius: 8, spreadRadius: 1, offset: const Offset(0, 1))],
            ),
            child: Center(
              child: Container(width: 13, height: 13, decoration: const BoxDecoration(color: Color(0xFF007AFF), shape: BoxShape.circle)),
            ),
          ),
        ]);
      },
    );
  }

  List<Polyline> _buildLineRoutePolylines(TransitProvider provider) {
    final route = provider.selectedLineRoute;
    if (route == null) return [];
    final polylines = <Polyline>[];
    final selectedDir = provider.selectedDirection;
    route.directions.forEach((key, dir) {
      if (selectedDir != 'ALL' && key != selectedDir) return;
      final pts = dir.coordinates.map((c) => LatLng(c[0], c[1])).toList();
      if (pts.length < 2) return;
      final color = key == 'G' ? AppTheme.directionPurple : AppTheme.directionCyan;
      polylines.add(Polyline(points: pts, strokeWidth: 8.0, color: color.withValues(alpha: 0.35)));
      polylines.add(Polyline(points: pts, strokeWidth: 4.5, color: color));
    });
    return polylines;
  }

  List<Marker> _buildGeneralBusStopMarkers(TransitProvider provider) {
    if (_currentZoom < 13.5) return [];
    final markers = <Marker>[];
    for (final stop in provider.visibleBusStops) {
      final isSelected = provider.selectedStop?.code == stop.code;
      final point = LatLng(stop.lat, stop.lon);
      markers.add(Marker(
        point: point,
        width: isSelected ? 38 : 30,
        height: isSelected ? 38 : 30,
        alignment: Alignment.center,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _liveSel = null;
            provider.selectBusStop(stop);
            _animatedMapMove(point, math.max(_currentZoom, 15.0));
          },
          child: Center(
            child: Container(
              width: isSelected ? 24 : 16,
              height: isSelected ? 24 : 16,
              decoration: BoxDecoration(
                color: isSelected ? AppTheme.accentBlack : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: isSelected ? Colors.white : AppTheme.accentBlack, width: isSelected ? 2.5 : 1.8),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isSelected ? 0.35 : 0.18), blurRadius: isSelected ? 8 : 4)],
              ),
              child: Center(
                child: isSelected
                    ? const Icon(Icons.directions_bus_rounded, color: Colors.white, size: 13)
                    : Container(width: 5, height: 5, decoration: const BoxDecoration(color: AppTheme.accentBlack, shape: BoxShape.circle)),
              ),
            ),
          ),
        ),
      ));
    }
    return markers;
  }

  List<Marker> _buildLineBusStopMarkers(TransitProvider provider) {
    final route = provider.selectedLineRoute;
    if (route == null) return [];
    final markers = <Marker>[];
    final selectedDir = provider.selectedDirection;
    route.directions.forEach((key, dir) {
      if (selectedDir != 'ALL' && key != selectedDir) return;
      final color = key == 'G' ? AppTheme.directionPurple : AppTheme.directionCyan;
      for (int i = 0; i < dir.stops.length; i++) {
        final stop = dir.stops[i];
        final isTerminal = i == 0 || i == dir.stops.length - 1;
        markers.add(Marker(
          point: LatLng(stop.lat, stop.lon),
          width: isTerminal ? 36 : 28,
          height: isTerminal ? 36 : 28,
          alignment: Alignment.center,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => provider.selectBusStop(stop),
            child: Center(
              child: Container(
                width: isTerminal ? 22 : 14,
                height: isTerminal ? 22 : 14,
                decoration: BoxDecoration(
                  color: isTerminal ? color : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 2.2),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                ),
                child: isTerminal
                    ? Center(
                        child: Text(i == 0 ? 'A' : 'B',
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900)),
                      )
                    : null,
              ),
            ),
          ),
        ));
      }
    });
    return markers;
  }
}

/// Single vertical control capsule (settings · layers · theme · 3D · fit · locate), like the
/// reference video. Zoom buttons only appear on wide (desktop web) screens.
class _ControlRail extends StatelessWidget {
  final bool night, reveal, wide;
  final VoidCallback onSettings, onLayers, onTheme, on3d, onFit, onLocate, onZoomIn, onZoomOut, on3dMap, onAr;
  const _ControlRail({
    required this.night,
    required this.reveal,
    required this.wide,
    required this.onSettings,
    required this.onLayers,
    required this.onTheme,
    required this.on3d,
    required this.onFit,
    required this.onLocate,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.on3dMap,
    required this.onAr,
  });

  @override
  Widget build(BuildContext context) {
    final fg = night ? Colors.white : AppTheme.accentBlack;
    Widget btn(Widget child, VoidCallback onTap, String tip) => Tooltip(
          message: tip,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: SizedBox(width: 46, height: 46, child: Center(child: child)),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: night ? const Color(0xE61E2430) : Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: night ? Colors.white12 : AppTheme.borderLight),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 4))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        btn(Icon(Icons.settings_rounded, color: fg, size: 21), onSettings, 'Ayarlar'),
        btn(Icon(Icons.layers_rounded, color: fg, size: 21), onLayers, 'Katmanlar'),
        btn(Icon(night ? Icons.dark_mode_rounded : Icons.light_mode_rounded, color: fg, size: 21), onTheme, 'Harita teması'),
        btn(
          Text('3D',
              style: TextStyle(color: reveal ? const Color(0xFF3B82F6) : fg, fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: -0.3)),
          on3d,
          'İstasyon kesiti (3D)',
        ),
        btn(Icon(Icons.location_city_rounded, color: fg, size: 21), on3dMap, '3D canlı harita'),
        btn(Icon(Icons.view_in_ar_rounded, color: fg, size: 21), onAr, 'AR yol tarifi'),
        if (wide) ...[
          btn(Icon(Icons.add_rounded, color: fg, size: 22), onZoomIn, 'Yakınlaş'),
          btn(Icon(Icons.remove_rounded, color: fg, size: 22), onZoomOut, 'Uzaklaş'),
        ],
        btn(Icon(Icons.open_in_full_rounded, color: fg, size: 19), onFit, 'Tüm İstanbul'),
        btn(const Icon(Icons.near_me_rounded, color: Color(0xFF3B82F6), size: 21), onLocate, 'Konumum'),
      ]),
    );
  }
}
