import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/transit_models.dart';
import '../services/transit_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/bus_stop_detail_sheet.dart';
import '../widgets/floating_map_controls.dart';
import '../widgets/layers_bottom_sheet.dart';
import '../widgets/line_search_modal.dart';
import '../widgets/metro_train_detail_sheet.dart';
import '../widgets/minimal_bottom_nav_card.dart';
import '../widgets/quick_action_pills.dart';
import '../widgets/settings_bottom_sheet.dart';

class MapScreen extends StatefulWidget {

  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  late final MapController _mapController;

  static final LatLng istanbulCenter = const LatLng(41.0082, 28.9784);
  static const double initialZoom = 13.0;
  double _currentZoom = initialZoom;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
  }

  void _animatedMapMove(LatLng destLocation, double destZoom) {
    final latTween = Tween<double>(
      begin: _mapController.camera.center.latitude,
      end: destLocation.latitude,
    );
    final lngTween = Tween<double>(
      begin: _mapController.camera.center.longitude,
      end: destLocation.longitude,
    );
    final zoomTween = Tween<double>(
      begin: _mapController.camera.zoom,
      end: destZoom,
    );

    final controller = AnimationController(
      duration: const Duration(milliseconds: 450),
      vsync: this,
    );

    final Animation<double> animation = CurvedAnimation(
      parent: controller,
      curve: Curves.fastOutSlowIn,
    );

    controller.addListener(() {
      _mapController.move(
        LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)),
        zoomTween.evaluate(animation),
      );
    });

    animation.addStatusListener((status) {
      if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
        controller.dispose();
      }
    });

    controller.forward();
  }

  void _openSearch(TransitProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LineSearchModal(
        popularLines: provider.popularLines,
        onSelectLine: (line) {
          provider.selectLine(line);
          Future.delayed(const Duration(milliseconds: 350), () {
            _fitLineRouteOnMap(provider);
          });
        },
      ),
    );
  }

  void _openLayersSheet(TransitProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LayersBottomSheet(
        provider: provider,
        onClose: () => Navigator.pop(context),
      ),
    );
  }

  void _openSettingsSheet(TransitProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SettingsBottomSheet(
        provider: provider,
        onClose: () => Navigator.pop(context),
      ),
    );
  }


  void _fitLineRouteOnMap(TransitProvider provider) {
    final route = provider.selectedLineRoute;
    if (route == null || route.directions.isEmpty) return;

    final allCoords = <LatLng>[];
    route.directions.forEach((_, dir) {
      for (final stop in dir.stops) {
        allCoords.add(LatLng(stop.lat, stop.lon));
      }
    });

    if (allCoords.isNotEmpty) {
      final bounds = LatLngBounds.fromPoints(allCoords);
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.only(top: 140, bottom: 220, left: 40, right: 40),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TransitProvider>();

    return Scaffold(
      backgroundColor: provider.isNightMode ? const Color(0xFF090D16) : AppTheme.background,
      body: Stack(
        children: [
          // ─── 1. ULTRA-FAST HIGH PERFORMANCE FLUTTER MAP ───
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: istanbulCenter,
              initialZoom: initialZoom,
              initialRotation: 0.0,
              minZoom: 8.0,
              maxZoom: 18.5,
              interactionOptions: InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                cursorKeyboardRotationOptions:
                    CursorKeyboardRotationOptions.disabled(),
              ),
              onPositionChanged: (camera, _) {
                _currentZoom = camera.zoom;
                provider.updateCameraPosition(camera.center, camera.zoom);
              },
              onTap: (_, _) {
                if (provider.selectedBus != null) {
                  provider.selectBus(null);
                }
                if (provider.selectedTrain != null) {
                  provider.selectTrain(null);
                }
                if (provider.selectedStop != null) {
                  provider.selectBusStop(null);
                }
              },
            ),
            children: [
              // Carto Retina Base Map (Switches between Dark All and Light All)
              TileLayer(
                urlTemplate: provider.tileUrl,
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.istanbulbizim.mobile_app',
                maxZoom: 19,
              ),

              // Metro Line Polylines in official vibrant line colors
              if (provider.showMetroLines)
                PolylineLayer(
                  polylines: _buildMetroPolylines(provider),
                ),

              // Selected Bus Line Road Snapped Polylines (Vibrant Cyan D / Purple G)
              if (provider.selectedLineRoute != null)
                PolylineLayer(
                  polylines: _buildLineRoutePolylines(provider),
                ),

              // Bus Stops Layer across Istanbul (when enabled & zoomed in)
              if (provider.showBusStops && provider.selectedLineRoute == null)
                MarkerLayer(
                  markers: _buildGeneralBusStopMarkers(provider),
                ),

              // Bus Stop Markers for selected line
              if (provider.selectedLineRoute != null)
                MarkerLayer(
                  markers: _buildLineBusStopMarkers(provider),
                ),

              // Metro Station Markers with line-colored borders
              if (provider.showMetroLines)
                MarkerLayer(
                  markers: _buildMetroStationMarkers(provider),
                ),

              // 60 FPS Moving Metro Trains Layer (Clickable & Colored, visible when zoomed in)
              if (provider.showMetroLines && provider.showMetroTrains && _currentZoom >= 12.0)
                MarkerLayer(
                  markers: _buildMetroTrainMarkers(provider),
                ),

              // Bus Vehicle Markers (with traffic speed indicators)
              if (provider.showBuses)
                MarkerLayer(
                  markers: _buildBusMarkers(provider),
                ),

              // User Current GPS Location Marker
              if (provider.userLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: provider.userLocation!,
                      width: 44,
                      height: 44,
                      child: _buildUserLocationMarker(),
                    ),
                  ],
                ),
            ],
          ),

          // ─── 2. OFFLINE BANNER (Top of screen when disconnected or API unreachable - Minimal B&W) ───
          if (provider.isOffline)
            Positioned(
              top: MediaQuery.of(context).padding.top + 4,
              left: 14,
              right: 14,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.accentBlack.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.2),
                    width: 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Çevrimdışı Mod (Bağlantı Yok)',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            provider.lastSuccessfulSync != null
                              ? 'Önbelleğe alınan son sefer saatleri & konumlar gösteriliyor (${provider.lastSuccessfulSync!.hour.toString().padLeft(2, '0')}:${provider.lastSuccessfulSync!.minute.toString().padLeft(2, '0')})'
                              : 'Önbellekteki veriler ve hat tarifeleri aktif.',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () => provider.refreshFleet(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Tekrar Dene',
                          style: TextStyle(
                            color: AppTheme.accentBlack,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ─── 3. CLOSEST BUS LINES IN FIELD VIEW AREA (Dynamic fast-select pills) ───
          Positioned(
            top: MediaQuery.of(context).padding.top + (provider.isOffline ? 48 : 8),
            left: 0,
            right: 0,
            child: QuickActionPills(
              nearbyLines: provider.nearbyBusLines,
              selectedLine: provider.selectedLineCode,
              onSelectLine: (line) {
                provider.selectLine(line);
                Future.delayed(const Duration(milliseconds: 350), () {
                  _fitLineRouteOnMap(provider);
                });
              },
              onClearLine: () => provider.selectLine(null),
              onSearchTap: () => _openSearch(provider),
              showMetro: provider.showMetroLines,
              onToggleMetro: () => provider.toggleMetroLines(),
              showTrains: provider.showMetroTrains,
              onToggleTrains: () => provider.toggleMetroTrains(),
              isNightMode: provider.isNightMode,
            ),
          ),

          // ─── 4. FLOATING MAP CONTROLS (Right side - dynamically adjusted so never overflowed) ───
          Positioned(
            right: 16,
            bottom: provider.selectedStop != null
                ? 380
                : (provider.selectedTrain != null
                    ? 320
                    : (provider.selectedBus != null
                        ? 225
                        : (provider.selectedLineCode != null ? 185 : 110))),
            child: FloatingMapControls(
              isRefreshing: provider.isLoading,
              hasUserLocation: provider.userLocation != null,
              isNightMode: provider.isNightMode,
              onOpenSettings: () => _openSettingsSheet(provider),
              onToggleNightMode: () => provider.toggleNightMode(),
              onOpenLayers: () => _openLayersSheet(provider),
              onRefresh: () => provider.refreshFleet(),
              onZoomIn: () {
                _animatedMapMove(
                  _mapController.camera.center,
                  math.min(_mapController.camera.zoom + 1.0, 18.5),
                );
              },
              onZoomOut: () {
                _animatedMapMove(
                  _mapController.camera.center,
                  math.max(_mapController.camera.zoom - 1.0, 8.0),
                );
              },
              onRecenter: () async {
                _mapController.rotate(0.0);
                final loc = await provider.locateUser();
                if (loc != null) {
                  _animatedMapMove(loc, 15.5);
                } else {
                  _animatedMapMove(istanbulCenter, initialZoom);
                }
              },
            ),
          ),

          // ─── 5. BOTTOM NAVIGATION SHEET / INSPECTION MODAL ───
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: provider.selectedTrain != null
                ? MetroTrainDetailSheet(
                    train: provider.selectedTrain!,
                    onClose: () => provider.selectTrain(null),
                  )
                : provider.selectedStop != null
                    ? BusStopDetailSheet(
                        stop: provider.selectedStop!,
                        provider: provider,
                        onClose: () => provider.selectBusStop(null),
                        onSelectLine: (line) {
                          provider.selectBusStop(null);
                          provider.selectLine(line);
                          Future.delayed(const Duration(milliseconds: 350), () {
                            _fitLineRouteOnMap(provider);
                          });
                        },
                      )
                    : MinimalBottomNavCard(
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
                          if (line != null && line.isNotEmpty) {
                            provider.loadTimetableForLine(line);
                          }
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
                      ),
          ),

        ],
      ),
    );
  }

  // ─── BUS VEHICLE MARKERS BUILDER (with directional heading arrow & speed aura) ───
  List<Marker> _buildBusMarkers(TransitProvider provider) {
    final markers = <Marker>[];
    final visibleList = provider.visibleBuses;

    for (final bus in visibleList) {
      final isSelected = provider.selectedBus?.id == bus.id;
      final point = LatLng(bus.lat, bus.lon);

      markers.add(
        Marker(
          point: point,
          width: isSelected ? 52 : 42,
          height: isSelected ? 52 : 42,
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: () {
              provider.selectBus(bus);
              _animatedMapMove(point, 15.5);
            },
            child: _buildBusMarkerWidget(bus, isSelected),
          ),
        ),
      );
    }
    return markers;
  }

  Widget _buildBusMarkerWidget(BusVehicle bus, bool isSelected) {
    final hasBearing = bus.bearing != null && bus.speed > 2.0;

    return Stack(
      alignment: Alignment.center,
      children: [
        // Directional Heading Pointer Arrow (if vehicle has bearing and moving)
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
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 3,
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Outer circular badge
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
            border: Border.all(
              color: isSelected ? Colors.white : AppTheme.accentBlack,
              width: isSelected ? 2.5 : 1.8,
            ),
          ),
          child: Center(
            child: bus.line.isNotEmpty
                ? Text(
                    bus.line,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      color: isSelected ? Colors.white : AppTheme.accentBlack,
                      fontSize: bus.line.length > 3 ? 9 : 11,
                      fontWeight: FontWeight.w900,
                    ),
                  )
                : Icon(
                    Icons.directions_bus_rounded,
                    color: isSelected ? Colors.white : AppTheme.accentBlack,
                    size: 16,
                  ),
          ),
        ),

        // Traffic speed indicator dot (Green: >15 km/s, Amber: 5-15 km/s, Slate: stopped)
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
              boxShadow: [
                BoxShadow(
                  color: bus.speedColor.withValues(alpha: 0.6),
                  blurRadius: 3,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ─── 60 FPS MOVING METRO TRAINS LAYER BUILDER (Clickable & Colored) ───
  List<Marker> _buildMetroTrainMarkers(TransitProvider provider) {
    final markers = <Marker>[];

    for (final train in provider.metroTrains) {
      final point = LatLng(train.currentLat, train.currentLon);
      final isSelected = provider.selectedTrain?.id == train.id;

      markers.add(
        Marker(
          point: point,
          width: isSelected ? 72 : 64,
          height: isSelected ? 36 : 30,
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: () {
              provider.selectTrain(train);
              _animatedMapMove(point, math.max(_currentZoom, 14.5));
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: train.color,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? const Color(0xFFFEF08A) : Colors.white,
                  width: isSelected ? 2.2 : 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: train.color.withValues(alpha: isSelected ? 0.8 : 0.45),
                    blurRadius: isSelected ? 12 : 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🚆', style: TextStyle(fontSize: 11)),
                  const SizedBox(width: 3),
                  Text(
                    train.lineCode,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    train.arrowIcon,
                    style: TextStyle(
                      color: train.state == 'ACCELERATING'
                          ? const Color(0xFF86EFAC)
                          : (train.state == 'DECELERATING'
                              ? const Color(0xFFFCA5A5)
                              : Colors.white70),
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return markers;
  }

  // ─── USER LOCATION MARKER BUILDER ───
  Widget _buildUserLocationMarker() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
        ),
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: AppTheme.accentBlack,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ─── METRO POLYLINES & STATIONS (Official Vibrant Colors) ───
  List<Polyline> _buildMetroPolylines(TransitProvider provider) {
    if (_currentZoom < 10.5) return [];

    final polylines = <Polyline>[];
    final isZoomedOut = _currentZoom < 12.5;

    provider.metroStations.forEach((lineCode, stations) {
      if (stations.length < 2) return;
      final points = stations.map((s) => LatLng(s.lat, s.lon)).toList();
      final color = provider.getMetroLineColor(lineCode);

      // Glowing Underlay Track (only when sufficiently zoomed in)
      if (!isZoomedOut) {
        polylines.add(
          Polyline(
            points: points,
            strokeWidth: 6.0,
            color: color.withValues(alpha: 0.35),
          ),
        );
      }

      // Main Crisp Polyline in Official Line Color
      polylines.add(
        Polyline(
          points: points,
          strokeWidth: isZoomedOut ? 2.5 : 3.8,
          color: color,
          borderStrokeWidth: isZoomedOut ? 0.0 : 1.0,
          borderColor: Colors.white.withValues(alpha: 0.8),
        ),
      );
    });

    return polylines;
  }

  List<Marker> _buildMetroStationMarkers(TransitProvider provider) {
    if (_currentZoom < 13.0) return [];

    final markers = <Marker>[];
    provider.metroStations.forEach((lineCode, stations) {
      final color = provider.getMetroLineColor(lineCode);
      for (final st in stations) {
        markers.add(
          Marker(
            point: LatLng(st.lat, st.lon),
            width: 16,
            height: 16,
            alignment: Alignment.center,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.4),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: Center(
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        );
      }
    });

    return markers;
  }

  // ─── LINE ROUTE POLYLINES & STOPS (Curved road-snapped lines with distinct colors) ───
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

      // Glow Underlay
      polylines.add(
        Polyline(
          points: pts,
          strokeWidth: 8.0,
          color: color.withValues(alpha: 0.35),
        ),
      );

      // Main Road-Snapped Route Line
      polylines.add(
        Polyline(
          points: pts,
          strokeWidth: 4.5,
          color: color,
        ),
      );
    });

    return polylines;
  }

  // ─── GENERAL BUS STOPS MARKERS (Across Istanbul) ───
  List<Marker> _buildGeneralBusStopMarkers(TransitProvider provider) {
    if (_currentZoom < 13.5) return [];

    final stops = provider.visibleBusStops;
    final markers = <Marker>[];

    for (final stop in stops) {
      final isSelected = provider.selectedStop?.code == stop.code;
      final point = LatLng(stop.lat, stop.lon);

      markers.add(
        Marker(
          point: point,
          width: isSelected ? 28 : 20,
          height: isSelected ? 28 : 20,
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: () {
              provider.selectBusStop(stop);
              _animatedMapMove(point, math.max(_currentZoom, 15.0));
            },
            child: Container(
              decoration: BoxDecoration(
                color: isSelected ? AppTheme.accentBlack : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? Colors.white : AppTheme.accentBlack,
                  width: isSelected ? 2.5 : 1.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isSelected ? 0.35 : 0.18),
                    blurRadius: isSelected ? 8 : 4,
                  ),
                ],
              ),
              child: Center(
                child: isSelected
                    ? const Icon(Icons.directions_bus_rounded, color: Colors.white, size: 14)
                    : Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: AppTheme.accentBlack,
                          shape: BoxShape.circle,
                        ),
                      ),
              ),
            ),
          ),
        ),
      );
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

        markers.add(
          Marker(
            point: LatLng(stop.lat, stop.lon),
            width: isTerminal ? 24 : 14,
            height: isTerminal ? 24 : 14,
            alignment: Alignment.center,
            child: GestureDetector(
              onTap: () {
                provider.selectBusStop(stop);
              },
              child: Container(
                decoration: BoxDecoration(
                  color: isTerminal ? color : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 2.5),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                ),
                child: isTerminal
                    ? Center(
                        child: Text(
                          i == 0 ? 'A' : 'B',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
          ),
        );
      }
    });

    return markers;
  }
}
