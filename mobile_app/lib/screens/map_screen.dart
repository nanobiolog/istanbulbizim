import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/transit_models.dart';
import '../services/transit_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/floating_map_controls.dart';
import '../widgets/line_search_modal.dart';
import '../widgets/minimal_bottom_nav_card.dart';
import '../widgets/minimal_hud_header.dart';
import '../widgets/quick_action_pills.dart';

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
    final cartoKey = provider.cartoApiKey ?? '';

    // Carto tile URL template: if CARTO key is known, append ?key=, otherwise use standard Carto raster
    final tileUrl = cartoKey.isNotEmpty
        ? 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}@2x.png?key=$cartoKey'
        : 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}@2x.png';

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          // ─── 1. ULTRA-FAST HIGH PERFORMANCE FLUTTER MAP ───
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: istanbulCenter,
              initialZoom: initialZoom,
              minZoom: 8.0,
              maxZoom: 18.5,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              onPositionChanged: (camera, _) {
                _currentZoom = camera.zoom;
                provider.updateCameraPosition(camera.center, camera.zoom);
              },
              onTap: (_, _) {
                if (provider.selectedBus != null) {
                  provider.selectBus(null);
                }
              },
            ),
            children: [
              // Clean Carto Voyager Tiles
              TileLayer(
                urlTemplate: tileUrl,
                userAgentPackageName: 'com.istanbulbizim.mobile_app',
                maxZoom: 19,
                subdomains: const ['a', 'b', 'c', 'd'],
              ),

              // Metro Line Polylines (if enabled)
              if (provider.showMetroLines)
                PolylineLayer(
                  polylines: _buildMetroPolylines(provider),
                ),

              // Selected Bus Line Road Snapped Polylines
              if (provider.selectedLineRoute != null)
                PolylineLayer(
                  polylines: _buildLineRoutePolylines(provider),
                ),

              // Metro Station Markers
              if (provider.showMetroLines)
                MarkerLayer(
                  markers: _buildMetroStationMarkers(provider),
                ),

              // 60 FPS Moving Metro Trains Layer
              if (provider.showMetroLines && provider.showMetroTrains)
                MarkerLayer(
                  markers: _buildMetroTrainMarkers(provider),
                ),

              // Bus Stop Markers for selected line
              if (provider.selectedLineRoute != null)
                MarkerLayer(
                  markers: _buildBusStopMarkers(provider),
                ),

              // Bus Vehicle Markers (Filtered to 5km vicinity or selected line)
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

          // ─── 2. TOP HUD NAVIGATION HEADER (Pure Black Pill banner) ───
          Positioned(
            top: MediaQuery.of(context).padding.top + 6,
            left: 0,
            right: 0,
            child: MinimalHudHeader(
              activeLine: provider.selectedLineCode,
              routeDetails: provider.selectedLineRoute,
              busCount: provider.selectedLineCode != null
                  ? provider.visibleBuses.length
                  : provider.activeBusCount,
              onClearLine: () => provider.selectLine(null),
              onSearchTap: () => _openSearch(provider),
            ),
          ),

          // ─── 3. QUICK ACTION PILLS (Under Header) ───
          Positioned(
            top: MediaQuery.of(context).padding.top + 84,
            left: 0,
            right: 0,
            child: QuickActionPills(
              popularLines: provider.popularLines,
              selectedLine: provider.selectedLineCode,
              onSelectLine: (line) {
                provider.selectLine(line);
                Future.delayed(const Duration(milliseconds: 350), () {
                  _fitLineRouteOnMap(provider);
                });
              },
              onClearLine: () => provider.selectLine(null),
              showMetro: provider.showMetroLines,
              onToggleMetro: () => provider.toggleMetroLines(),
              showTrains: provider.showMetroTrains,
              onToggleTrains: () => provider.toggleMetroTrains(),
            ),
          ),

          // ─── 4. FLOATING MAP CONTROLS (Right side) ───
          Positioned(
            right: 16,
            bottom: 140,
            child: FloatingMapControls(
              isRefreshing: provider.isLoading,
              hasUserLocation: provider.userLocation != null,
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
                final loc = await provider.locateUser();
                if (loc != null) {
                  _animatedMapMove(loc, 15.5);
                } else {
                  _animatedMapMove(istanbulCenter, initialZoom);
                }
              },
            ),
          ),

          // ─── 5. BOTTOM NAVIGATION SHEET (Monochrome & Tactile) ───
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: MinimalBottomNavCard(
              selectedBus: provider.selectedBus,
              activeLine: provider.selectedLineCode,
              routeDetails: provider.selectedLineRoute,
              visibleBusCount: provider.visibleBuses.length,
              totalBusCount: provider.activeBusCount,
              selectedDirection: provider.selectedDirection,
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

  // ─── BUS VEHICLE MARKERS BUILDER (High-contrast Black & White) ───
  List<Marker> _buildBusMarkers(TransitProvider provider) {
    final markers = <Marker>[];
    final visibleList = provider.visibleBuses;

    for (final bus in visibleList) {
      final isSelected = provider.selectedBus?.id == bus.id;
      final point = LatLng(bus.lat, bus.lon);

      markers.add(
        Marker(
          point: point,
          width: isSelected ? 48 : 38,
          height: isSelected ? 48 : 38,
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
    return Stack(
      alignment: Alignment.center,
      children: [
        // Outer monochrome circular badge
        Container(
          width: isSelected ? 44 : 34,
          height: isSelected ? 44 : 34,
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.accentBlack : Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isSelected ? 0.35 : 0.15),
                blurRadius: isSelected ? 10 : 4,
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

        // Small indicator dot showing moving vs stopped
        Positioned(
          bottom: 1,
          right: 1,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: bus.speed > 3 ? AppTheme.accentBlack : AppTheme.borderMedium,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.2),
            ),
          ),
        ),
      ],
    );
  }

  // ─── 60 FPS MOVING METRO TRAINS LAYER BUILDER ───
  List<Marker> _buildMetroTrainMarkers(TransitProvider provider) {
    final markers = <Marker>[];

    for (final train in provider.metroTrains) {
      final point = LatLng(train.currentLat, train.currentLon);

      markers.add(
        Marker(
          point: point,
          width: 64,
          height: 32,
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.accentBlack,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.train_rounded,
                  color: Colors.white,
                  size: 13,
                ),
                const SizedBox(width: 3),
                Text(
                  train.lineCode,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 10,
                  ),
                ),
              ],
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
            color: Colors.black.withValues(alpha: 0.08),
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
                color: Colors.black.withValues(alpha: 0.25),
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

  // ─── METRO POLYLINES & STATIONS (Clean Monochrome) ───
  List<Polyline> _buildMetroPolylines(TransitProvider provider) {
    final polylines = <Polyline>[];

    provider.metroStations.forEach((_, stations) {
      if (stations.length < 2) return;
      final points = stations.map((s) => LatLng(s.lat, s.lon)).toList();

      polylines.add(
        Polyline(
          points: points,
          strokeWidth: 3.5,
          color: const Color(0xFF27272A), // Dark charcoal/black track
          borderStrokeWidth: 1.5,
          borderColor: Colors.white.withValues(alpha: 0.9),
        ),
      );
    });

    return polylines;
  }

  List<Marker> _buildMetroStationMarkers(TransitProvider provider) {
    if (_currentZoom < 13.5) return [];

    final markers = <Marker>[];
    provider.metroStations.forEach((_, stations) {
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
                border: Border.all(color: AppTheme.accentBlack, width: 2.0),
                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 3)],
              ),
            ),
          ),
        );
      }
    });

    return markers;
  }

  // ─── LINE ROUTE POLYLINES & STOPS (Curved road-snapped lines) ───
  List<Polyline> _buildLineRoutePolylines(TransitProvider provider) {
    final route = provider.selectedLineRoute;
    if (route == null) return [];

    final polylines = <Polyline>[];
    final selectedDir = provider.selectedDirection;

    route.directions.forEach((key, dir) {
      if (selectedDir != 'ALL' && key != selectedDir) return;

      final pts = dir.coordinates.map((c) => LatLng(c[0], c[1])).toList();
      if (pts.length < 2) return;

      // Glow Underlay
      polylines.add(
        Polyline(
          points: pts,
          strokeWidth: 8.0,
          color: Colors.black.withValues(alpha: 0.12),
        ),
      );

      // Main Road-Snapped Route Line
      polylines.add(
        Polyline(
          points: pts,
          strokeWidth: 4.5,
          color: AppTheme.accentBlack,
        ),
      );
    });

    return polylines;
  }

  List<Marker> _buildBusStopMarkers(TransitProvider provider) {
    final route = provider.selectedLineRoute;
    if (route == null) return [];

    final markers = <Marker>[];
    final selectedDir = provider.selectedDirection;

    route.directions.forEach((key, dir) {
      if (selectedDir != 'ALL' && key != selectedDir) return;

      for (int i = 0; i < dir.stops.length; i++) {
        final stop = dir.stops[i];
        final isTerminal = i == 0 || i == dir.stops.length - 1;

        markers.add(
          Marker(
            point: LatLng(stop.lat, stop.lon),
            width: isTerminal ? 24 : 14,
            height: isTerminal ? 24 : 14,
            alignment: Alignment.center,
            child: Container(
              decoration: BoxDecoration(
                color: isTerminal ? AppTheme.accentBlack : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.accentBlack, width: 2.5),
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
        );
      }
    });

    return markers;
  }
}
