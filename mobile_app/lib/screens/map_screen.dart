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

  // Istanbul Center (Sultanahmet / Bosphorus area)
  static final LatLng istanbulCenter = const LatLng(41.0082, 28.9784);
  static const double initialZoom = 12.8;

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
      duration: const Duration(milliseconds: 500),
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
          // Wait for line route to load and frame map
          Future.delayed(const Duration(milliseconds: 400), () {
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
              onPositionChanged: (camera, hasGesture) {
                if (_currentZoom != camera.zoom) {
                  setState(() {
                    _currentZoom = camera.zoom;
                  });
                }
              },
              onTap: (_, _) {
                if (provider.selectedBus != null) {
                  provider.selectBus(null);
                }
              },
            ),
            children: [
              // Clean Carto Voyager / Positron Tiles (Crisp, Retina-sharp)
              TileLayer(
                urlTemplate: 'https://a.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}@2x.png',
                userAgentPackageName: 'com.istanbulbizim.mobile_app',
                maxZoom: 19,
                subdomains: const ['a', 'b', 'c', 'd'],
              ),

              // Metro Line Polylines (if enabled)
              if (provider.showMetroLines)
                PolylineLayer(
                  polylines: _buildMetroPolylines(provider),
                ),

              // Selected Bus Line Official Route Polylines
              if (provider.selectedLineRoute != null)
                PolylineLayer(
                  polylines: _buildLineRoutePolylines(provider),
                ),

              // Metro Station Markers
              if (provider.showMetroLines)
                MarkerLayer(
                  markers: _buildMetroStationMarkers(provider),
                ),

              // Bus Stop Markers for selected line
              if (provider.selectedLineRoute != null)
                MarkerLayer(
                  markers: _buildBusStopMarkers(provider),
                ),

              // Bus Vehicle Markers (Live GPS with direction arrows and speed colors)
              MarkerLayer(
                markers: _buildBusMarkers(provider),
              ),

              // User Current GPS Location Marker
              if (provider.userLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: provider.userLocation!,
                      width: 48,
                      height: 48,
                      child: _buildUserLocationMarker(),
                    ),
                  ],
                ),
            ],
          ),

          // ─── 2. TOP HUD NAVIGATION HEADER (Dark Pill banner) ───
          Positioned(
            top: MediaQuery.of(context).padding.top + 6,
            left: 0,
            right: 0,
            child: MinimalHudHeader(
              activeLine: provider.selectedLineCode,
              routeDetails: provider.selectedLineRoute,
              busCount: provider.activeBusCount,
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
                Future.delayed(const Duration(milliseconds: 400), () {
                  _fitLineRouteOnMap(provider);
                });
              },
              onClearLine: () => provider.selectLine(null),
              showMetro: provider.showMetroLines,
              onToggleMetro: () => provider.toggleMetroLines(),
            ),
          ),

          // ─── 4. FLOATING MAP CONTROLS (Right side: Recenter, Zoom, Sync) ───
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

          // ─── 5. BOTTOM NAVIGATION SHEET (Minimalist Big Buttons & Direction Switch) ───
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: MinimalBottomNavCard(
              selectedBus: provider.selectedBus,
              activeLine: provider.selectedLineCode,
              routeDetails: provider.selectedLineRoute,
              busCount: provider.activeBusCount,
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

  // ─── BUS VEHICLE MARKERS BUILDER ───
  List<Marker> _buildBusMarkers(TransitProvider provider) {
    final markers = <Marker>[];
    final selectedDir = provider.selectedDirection;

    for (final bus in provider.buses) {
      if (selectedDir != 'ALL' && bus.direction.isNotEmpty && bus.direction != selectedDir) {
        continue;
      }

      final isSelected = provider.selectedBus?.id == bus.id;
      final point = LatLng(bus.lat, bus.lon);

      markers.add(
        Marker(
          point: point,
          width: isSelected ? 54 : 44,
          height: isSelected ? 54 : 44,
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
    final baseColor = bus.speedColor;

    return Stack(
      alignment: Alignment.center,
      children: [
        // Outer glow/shadow
        Container(
          width: isSelected ? 50 : 40,
          height: isSelected ? 50 : 40,
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.accentBlack : Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: baseColor.withOpacity(0.4),
                blurRadius: isSelected ? 12 : 6,
                spreadRadius: isSelected ? 3 : 1,
              ),
            ],
            border: Border.all(
              color: baseColor,
              width: isSelected ? 3 : 2,
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (bus.line.isNotEmpty) ...[
                  Text(
                    bus.line,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      color: isSelected ? Colors.white : AppTheme.accentBlack,
                      fontSize: bus.line.length > 3 ? 9 : 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ] else ...[
                  Icon(
                    Icons.directions_bus_rounded,
                    color: isSelected ? Colors.white : AppTheme.accentBlack,
                    size: 18,
                  ),
                ],
              ],
            ),
          ),
        ),

        // Mini speed indicator dot
        Positioned(
          bottom: 2,
          right: 2,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: baseColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  // ─── USER LOCATION MARKER BUILDER (Radar circle) ───
  Widget _buildUserLocationMarker() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppTheme.accentBlue.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
        ),
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppTheme.accentBlue.withOpacity(0.4),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: 14,
              height: 14,
              decoration: const BoxDecoration(
                color: AppTheme.accentBlue,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ─── METRO POLYLINES & STATIONS ───
  List<Polyline> _buildMetroPolylines(TransitProvider provider) {
    final polylines = <Polyline>[];

    provider.metroStations.forEach((line, stations) {
      if (stations.length < 2) return;
      final points = stations.map((s) => LatLng(s.lat, s.lon)).toList();
      final color = _parseColor(provider.metroColors[line] ?? 'rgb(0,153,68)');

      polylines.add(
        Polyline(
          points: points,
          strokeWidth: 3.5,
          color: color.withOpacity(0.85),
          borderStrokeWidth: 1.5,
          borderColor: Colors.white.withOpacity(0.9),
        ),
      );
    });

    return polylines;
  }

  double _currentZoom = initialZoom;

  List<Marker> _buildMetroStationMarkers(TransitProvider provider) {
    // Show only when zoomed in past 13.5 to prevent clutter
    if (_currentZoom < 13.5) return [];

    final markers = <Marker>[];
    provider.metroStations.forEach((line, stations) {
      final color = _parseColor(provider.metroColors[line] ?? 'rgb(0,153,68)');
      for (final st in stations) {
        markers.add(
          Marker(
            point: LatLng(st.lat, st.lon),
            width: 20,
            height: 20,
            alignment: Alignment.center,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 2.5),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
              ),
            ),
          ),
        );
      }
    });

    return markers;
  }

  // ─── LINE ROUTE POLYLINES & STOPS ───
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
          color: color.withOpacity(0.3),
        ),
      );

      // Main Route Line
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

  List<Marker> _buildBusStopMarkers(TransitProvider provider) {
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
        );
      }
    });

    return markers;
  }

  Color _parseColor(String rgbString) {
    try {
      final cleaned = rgbString.replaceAll('rgb(', '').replaceAll(')', '').trim();
      final parts = cleaned.split(',');
      if (parts.length >= 3) {
        return Color.fromRGBO(
          int.parse(parts[0].trim()),
          int.parse(parts[1].trim()),
          int.parse(parts[2].trim()),
          1.0,
        );
      }
    } catch (_) {}
    return const Color(0xFF009944);
  }
}
