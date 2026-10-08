import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../models/transit_models.dart';
import '../services/transit_api_service.dart';

class TransitProvider extends ChangeNotifier {
  final TransitApiService _apiService = TransitApiService();

  // State
  List<BusVehicle> _buses = [];
  List<BusVehicle> _fleetBuses = [];
  List<NearbyBusLine> _nearbyBusLines = [];
  LatLng _lastComputedCenter = const LatLng(0, 0);
  double _lastComputedZoom = 0;
  Timer? _dragDebounceTimer;
  bool _isLoading = false;
  String? _errorMessage;
  String? _cartoApiKey;

  // Offline banner & network state
  bool _isOffline = false;
  DateTime? _lastSuccessfulSync;

  // User Settings & Preferences
  ThemeMode _themeMode = ThemeMode.dark; // Default dark/night mode
  bool _autoRefreshEnabled = true; // App auto-sync enable/disable toggle
  int _refreshIntervalSec = 15; // 10s, 15s, 30s
  bool _highContrastTiles = true;

  // Selected Line Filter & Timetables
  String? _selectedLineCode;
  LineRouteDetails? _selectedLineRoute;
  String _selectedDirection = 'ALL'; // 'ALL', 'D', 'G'
  LineTimetable? _selectedLineTimetable;
  bool _isLoadingTimetable = false;

  // Selected Bus / Train / Bus Stop for Detail Sheets
  BusVehicle? _selectedBus;
  MetroTrainVehicle? _selectedTrain;
  BusStop? _selectedStop;

  // Layers & Map Modes
  bool _isNightMode = true; // Night mode enabled by default (Carto dark_all)
  bool _showBuses = true;
  bool _showMetroLines = true;
  bool _showMetroTrains = true;
  bool _showBusStops = true;

  // Metro Data & Colors
  Map<String, List<MetroStation>> _metroStations = {};
  Map<String, String> _metroColors = {};
  Map<String, Color> _metroLineColors = {};
  List<MetroTrainVehicle> _metroTrains = [];
  Timer? _trainTicker;

  // Bus Stops (~14,000 Istanbul bus stops database)
  List<BusStop> _busStops = [];

  // User GPS Location & Map Camera
  LatLng? _userLocation;
  LatLng _cameraCenter = const LatLng(41.0082, 28.9784);
  double _currentZoom = 13.0;
  StreamSubscription<Position>? _positionSubscription;

  // Auto-refresh timer
  Timer? _refreshTimer;
  DateTime? _lastUpdated;

  TransitProvider() {

    _init();
  }

  List<BusVehicle> get allBuses => _buses;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String? get cartoApiKey => _cartoApiKey;
  bool get isOffline => _isOffline;
  DateTime? get lastSuccessfulSync => _lastSuccessfulSync;

  // Preferences getters
  ThemeMode get themeMode => _themeMode;
  bool get autoRefreshEnabled => _autoRefreshEnabled;
  int get refreshIntervalSec => _refreshIntervalSec;
  bool get highContrastTiles => _highContrastTiles;

  String? get selectedLineCode => _selectedLineCode;
  LineRouteDetails? get selectedLineRoute => _selectedLineRoute;
  String get selectedDirection => _selectedDirection;
  LineTimetable? get selectedLineTimetable => _selectedLineTimetable;
  bool get isLoadingTimetable => _isLoadingTimetable;
  BusVehicle? get selectedBus => _selectedBus;
  MetroTrainVehicle? get selectedTrain => _selectedTrain;
  BusStop? get selectedStop => _selectedStop;


  bool get isNightMode => _isNightMode;
  bool get showBuses => _showBuses;
  bool get showMetroLines => _showMetroLines;
  bool get showMetroTrains => _showMetroTrains;
  bool get showBusStops => _showBusStops;

  Map<String, List<MetroStation>> get metroStations => _metroStations;
  Map<String, String> get metroColors => _metroColors;
  List<MetroTrainVehicle> get metroTrains => _metroTrains;
  List<BusStop> get busStops => _busStops;
  LatLng? get userLocation => _userLocation;
  LatLng get cameraCenter => _cameraCenter;
  double get currentZoom => _currentZoom;
  DateTime? get lastUpdated => _lastUpdated;
  int get activeBusCount => _buses.length;
  List<NearbyBusLine> get nearbyBusLines => _nearbyBusLines;

  /// Map Tile Layer URL: Switches between Carto Dark All and Light All Retina tiles
  String get tileUrl {
    final style = _isNightMode ? 'dark_all' : 'light_all';
    final keySuffix = (_cartoApiKey != null && _cartoApiKey!.isNotEmpty) ? '?key=$_cartoApiKey' : '';
    return 'https://{s}.basemaps.cartocdn.com/rastertiles/$style/{z}/{x}/{y}@2x.png$keySuffix';
  }

  /// Color Resolver for Metro and Transit lines
  Color getMetroLineColor(String lineCode) {
    final code = lineCode.trim().toUpperCase();
    if (_metroLineColors.containsKey(code)) {
      return _metroLineColors[code]!;
    }
    if (code.startsWith('34')) {
      return const Color(0xFFE11D48); // Metrobüs vibrant rose
    }
    if (code.startsWith('M')) {
      return const Color(0xFF0284C7);
    }
    if (code.startsWith('T')) {
      return const Color(0xFFF97316);
    }
    if (code.startsWith('F')) {
      return const Color(0xFF7C7358);
    }
    return const Color(0xFF0284C7);
  }

  /// Crucial Performance Filter:
  /// When a line is selected, show that line's buses.
  /// When viewing the entire fleet, prevent crash by only rendering buses within 5 km of camera or user,
  /// and don't render clutter if zoomed out too far (< 12.0).
  List<BusVehicle> get visibleBuses {
    if (!_showBuses) return [];

    if (_selectedLineCode != null) {
      if (_selectedDirection == 'ALL') return _buses;
      return _buses.where((b) => b.direction.isEmpty || b.direction == _selectedDirection).toList();
    }

    // Zoom-dependent density control:
    final center = _userLocation ?? _cameraCenter;
    const double radiusMeters = 5000; // 5 km radius

    final nearBuses = _buses.where((bus) {
      final d = _distanceMeters(center.latitude, center.longitude, bus.lat, bus.lon);
      return d <= radiusMeters;
    }).toList();

    if (_currentZoom < 12.0) {
      return nearBuses.take(40).toList();
    }
    return nearBuses;
  }

  /// Viewport filtered bus stops for peak 60 FPS performance
  List<BusStop> get visibleBusStops {
    if (!_showBusStops || _busStops.isEmpty) return [];
    if (_currentZoom < 13.5) return [];

    final center = _cameraCenter;
    const double radiusMeters = 3500; // 3.5 km around viewport center

    return _busStops.where((s) {
      return _distanceMeters(center.latitude, center.longitude, s.lat, s.lon) <= radiusMeters;
    }).take(250).toList();
  }

  /// Calculate live approaching buses for an inspected bus stop
  List<Map<String, dynamic>> getApproachingBusesForStop(BusStop stop) {
    final result = <Map<String, dynamic>>[];
    for (final bus in _buses) {
      final dist = _distanceMeters(bus.lat, bus.lon, stop.lat, stop.lon);
      if (dist <= 4500) { // within 4.5 km
        final speedMs = bus.speed > 5 ? (bus.speed / 3.6) : 6.0;
        final estSec = math.max(30, (dist / speedMs).round());
        result.add({
          'bus': bus,
          'dist_m': dist.round(),
          'est_sec': estSec,
        });
      }
    }
    result.sort((a, b) => (a['dist_m'] as int).compareTo(b['dist_m'] as int));
    return result.take(12).toList();
  }

  List<LineInfo> get allLines => _apiService.allLines;

  List<String> get popularLines => [
        '500T',
        '14BK',
        '15B',
        '34G',
        '34AS',
        '15F',
        '11US',
        '16D',
        '19F',
        '14R',
        '129T',
        '522',
        'E-10',
        '25G',
      ];

  Future<void> _init() async {
    _isLoading = true;
    notifyListeners();

    await _apiService.loadLocalAssets();
    _metroStations = _apiService.metroStations;
    _metroColors = _apiService.metroColors;
    _busStops = _apiService.busStops;

    _metroLineColors = {};
    _metroColors.forEach((k, v) {
      _metroLineColors[k] = TransitApiService.parseColorString(v);
    });

    _cartoApiKey = await _apiService.fetchConfigCartoKey();

    _initMetroTrainSimulation();

    await refreshFleet();

    _restartRefreshTimer();

    _initLocation();
  }

  void _restartRefreshTimer() {
    _refreshTimer?.cancel();
    if (_autoRefreshEnabled) {
      _refreshTimer = Timer.periodic(Duration(seconds: _refreshIntervalSec), (_) {
        if (_autoRefreshEnabled) {
          refreshFleet(silent: true);
        }
      });
    }
  }


  void updateCameraPosition(LatLng center, double zoom) {
    _cameraCenter = center;
    _currentZoom = zoom;

    final distMoved = _distanceMeters(
      _lastComputedCenter.latitude,
      _lastComputedCenter.longitude,
      center.latitude,
      center.longitude,
    );
    final zoomDiff = (_lastComputedZoom - zoom).abs();

    if (distMoved > 250 || zoomDiff > 0.35) {
      _computeNearbyLines();
      notifyListeners();
    } else {
      _dragDebounceTimer?.cancel();
      _dragDebounceTimer = Timer(const Duration(milliseconds: 140), () {
        _computeNearbyLines();
        notifyListeners();
      });
    }
  }

  void _computeNearbyLines() {
    _lastComputedCenter = _cameraCenter;
    _lastComputedZoom = _currentZoom;

    final pool = _fleetBuses.isNotEmpty ? _fleetBuses : _buses;
    if (pool.isEmpty) {
      if (_nearbyBusLines.isEmpty) {
        _nearbyBusLines = popularLines
            .map((l) => NearbyBusLine(lineCode: l, busCount: 0, distanceMeters: 0))
            .toList();
      }
      return;
    }

    // Dynamic viewport radius according to current map zoom
    final double viewRadius = (4500.0 * math.pow(2.0, 13.0 - _currentZoom)).clamp(700.0, 10000.0);
    const double expandedRadius = 8000.0;

    final map = <String, _LineStats>{};

    for (final bus in pool) {
      final code = bus.line.trim().toUpperCase();
      if (code.isEmpty) continue;

      final dist = _distanceMeters(
        _cameraCenter.latitude,
        _cameraCenter.longitude,
        bus.lat,
        bus.lon,
      );

      final stats = map.putIfAbsent(code, () => _LineStats(code));
      if (dist <= viewRadius) {
        stats.inViewCount++;
      }
      if (dist <= expandedRadius) {
        stats.nearbyCount++;
      }
      if (dist < stats.minDistance) {
        stats.minDistance = dist;
      }
    }

    // 1. Lines with vehicles directly in field view radius, sorted by closest distance to center
    final inViewLines = map.values.where((s) => s.inViewCount > 0).toList();
    inViewLines.sort((a, b) => a.minDistance.compareTo(b.minDistance));

    final results = <NearbyBusLine>[];
    for (final s in inViewLines) {
      results.add(NearbyBusLine(
        lineCode: s.code,
        busCount: s.inViewCount,
        distanceMeters: s.minDistance,
      ));
    }

    // 2. If fewer than 12 lines directly in viewport, supplement with closest nearby lines
    if (results.length < 12) {
      final remaining = map.values
          .where((s) => s.inViewCount == 0 && s.nearbyCount > 0)
          .toList();
      remaining.sort((a, b) => a.minDistance.compareTo(b.minDistance));

      for (final s in remaining) {
        if (results.length >= 16) break;
        results.add(NearbyBusLine(
          lineCode: s.code,
          busCount: s.nearbyCount,
          distanceMeters: s.minDistance,
        ));
      }
    }

    // Fallback if none found
    if (results.isEmpty) {
      results.addAll(popularLines.map(
        (l) => NearbyBusLine(lineCode: l, busCount: 0, distanceMeters: 0),
      ));
    }

    _nearbyBusLines = results;
  }

  Future<void> refreshFleet({bool silent = false}) async {
    if (!silent) {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      List<BusVehicle> raw;
      if (_selectedLineCode != null) {
        raw = await _apiService.fetchBusesForLine(_selectedLineCode!);
      } else {
        raw = await _apiService.fetchFleetBuses();
        _fleetBuses = raw;
      }
      _buses = _enrichBusesWithNextStops(raw);
      _lastUpdated = DateTime.now();
      _lastSuccessfulSync = DateTime.now();
      _isOffline = false;
      _errorMessage = null;
      _computeNearbyLines();

      // Keep active selected bus updated with latest telemetry
      if (_selectedBus != null) {
        final match = _buses.where((b) => b.id == _selectedBus!.id).firstOrNull;
        if (match != null) {
          _selectedBus = match;
        }
      }
    } catch (_) {
      _isOffline = true;
      if (!silent) {
        _errorMessage = 'İnternet bağlantısı kurulamadı. Çevrimdışı modda son önbellek gösteriliyor.';
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Calculates destination, upcoming next stop and live ETA for buses
  List<BusVehicle> _enrichBusesWithNextStops(List<BusVehicle> list) {
    if (list.isEmpty) return list;

    return list.map((bus) {
      String dest = bus.destination;
      String nextStop = bus.nextStop;
      int? etaSec = bus.nextStopEtaSec;
      int? nextDistM = bus.nextStopDistM;
      String dirName = bus.directionName;
      String headsign = bus.headsign;

      // 1. If line route is currently loaded and matches this bus line
      final route = (_selectedLineCode != null &&
              bus.line.toUpperCase() == _selectedLineCode!.toUpperCase())
          ? _selectedLineRoute
          : null;

      if (route != null && route.directions.isNotEmpty) {
        LineDirectionRoute? matchedDir;
        if (bus.direction.isNotEmpty && route.directions.containsKey(bus.direction)) {
          matchedDir = route.directions[bus.direction];
        } else if (route.directions.containsKey('D')) {
          matchedDir = route.directions['D'];
        } else if (route.directions.isNotEmpty) {
          matchedDir = route.directions.values.first;
        }

        if (matchedDir != null) {
          if (dest.isEmpty) {
            dest = matchedDir.destination.isNotEmpty ? matchedDir.destination : matchedDir.name;
          }
          if (dirName.isEmpty) dirName = matchedDir.name;
          if (headsign.isEmpty) headsign = matchedDir.headsign;

          final stops = matchedDir.stops;
          if (stops.isNotEmpty) {
            // Find closest upcoming stop along the route
            double closestDist = double.infinity;
            int closestIdx = -1;

            for (int i = 0; i < stops.length; i++) {
              final s = stops[i];
              final d = _distanceMeters(bus.lat, bus.lon, s.lat, s.lon);
              if (d < closestDist) {
                closestDist = d;
                closestIdx = i;
              }
            }

            if (closestIdx != -1) {
              // If within 60 meters, bus is at this stop; next stop is the following one
              BusStop targetStop = stops[closestIdx];
              double targetDist = closestDist;

              if (closestDist < 60 && closestIdx + 1 < stops.length) {
                targetStop = stops[closestIdx + 1];
                targetDist = _distanceMeters(bus.lat, bus.lon, targetStop.lat, targetStop.lon);
              }

              nextStop = targetStop.name;
              nextDistM = targetDist.round();

              // Realistic urban bus speed (accounting for traffic and dwell)
              final effectiveSpeedKmh = bus.speed > 12
                  ? math.max(16.0, bus.speed * 0.9)
                  : (bus.speed > 3 ? math.max(12.0, bus.speed * 1.2) : 15.0);
              final speedMs = (effectiveSpeedKmh * 1000) / 3600;

              if (closestDist <= 45 && bus.speed <= 5) {
                etaSec = 0; // At the stop
              } else {
                etaSec = math.max(15, (targetDist / speedMs).round());
              }
            }
          }
        }
      }

      // 2. Fallback: Find nearest bus stop in Istanbul bus stops database
      if (nextStop.isEmpty && _busStops.isNotEmpty) {
        double minD = double.infinity;
        BusStop? nearest;

        for (final s in _busStops) {
          final d = _distanceMeters(bus.lat, bus.lon, s.lat, s.lon);
          if (d < minD && d < 3000) {
            minD = d;
            nearest = s;
          }
        }

        if (nearest != null) {
          nextStop = nearest.name;
          nextDistM = minD.round();
          final speedMs = bus.speed > 5 ? (bus.speed / 3.6) : 5.0;
          etaSec = math.max(20, (minD / speedMs).round());
        }
      }

      if (dest.isEmpty) {
        dest = headsign.isNotEmpty
            ? headsign
            : (bus.direction == 'D' ? 'Dönüş İstikameti' : (bus.direction == 'G' ? 'Gidiş İstikameti' : ''));
      }

      return bus.copyWith(
        destination: dest,
        nextStop: nextStop,
        nextStopEtaSec: etaSec,
        nextStopDistM: nextDistM,
        directionName: dirName,
        headsign: headsign,
      );
    }).toList();
  }

  Future<void> selectLine(String? lineCode) async {
    if (lineCode == null || lineCode.isEmpty) {
      _selectedLineCode = null;
      _selectedLineRoute = null;
      _selectedLineTimetable = null;
      _selectedDirection = 'ALL';
      _selectedBus = null;
      await refreshFleet();
      return;
    }

    final upper = lineCode.trim().toUpperCase();
    _selectedLineCode = upper;
    _selectedBus = null;
    _selectedTrain = null;
    _selectedStop = null;
    _selectedLineTimetable = null;
    _isLoading = true;
    notifyListeners();

    try {
      _selectedLineRoute = await _apiService.fetchLineRoute(upper);
      final raw = await _apiService.fetchBusesForLine(upper);
      _buses = _enrichBusesWithNextStops(raw);
      _lastUpdated = DateTime.now();
      _lastSuccessfulSync = DateTime.now();
      _isOffline = false;
      _computeNearbyLines();
    } catch (_) {
      _isOffline = true;
      _errorMessage = 'Hat güzergahı alınamadı: $upper';
    } finally {
      _isLoading = false;
      notifyListeners();
    }

    // Eagerly prefetch timetable for this line in the background
    loadTimetableForLine(upper);
  }

  Future<LineTimetable?> loadTimetableForLine(String lineCode) async {
    _isLoadingTimetable = true;
    notifyListeners();
    try {
      final timetable = await _apiService.fetchLineTimetable(lineCode);
      if (_selectedLineCode == lineCode.toUpperCase()) {
        _selectedLineTimetable = timetable;
      }
      return timetable;
    } catch (_) {
      return null;
    } finally {
      _isLoadingTimetable = false;
      notifyListeners();
    }
  }


  void setDirectionFilter(String dir) {
    _selectedDirection = dir;
    notifyListeners();
  }

  void selectBus(BusVehicle? bus) {
    _selectedBus = bus;
    if (bus != null) {
      _selectedTrain = null;
      _selectedStop = null;
    }
    notifyListeners();
  }

  void selectTrain(MetroTrainVehicle? train) {
    _selectedTrain = train;
    if (train != null) {
      _selectedBus = null;
      _selectedStop = null;
    }
    notifyListeners();
  }

  void selectBusStop(BusStop? stop) {
    _selectedStop = stop;
    if (stop != null) {
      _selectedBus = null;
      _selectedTrain = null;
    }
    notifyListeners();
  }

  void toggleNightMode() {
    _isNightMode = !_isNightMode;
    _themeMode = _isNightMode ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    _isNightMode = (mode == ThemeMode.dark);
    notifyListeners();
  }

  void toggleAutoRefresh([bool? enabled]) {
    _autoRefreshEnabled = enabled ?? !_autoRefreshEnabled;
    _restartRefreshTimer();
    notifyListeners();
  }

  void setRefreshInterval(int seconds) {
    _refreshIntervalSec = seconds;
    _restartRefreshTimer();
    notifyListeners();
  }

  void toggleHighContrastTiles([bool? enabled]) {
    _highContrastTiles = enabled ?? !_highContrastTiles;
    notifyListeners();
  }

  void toggleBuses() {
    _showBuses = !_showBuses;
    notifyListeners();
  }

  void toggleMetroLines() {
    _showMetroLines = !_showMetroLines;
    notifyListeners();
  }

  void toggleMetroTrains() {
    _showMetroTrains = !_showMetroTrains;
    notifyListeners();
  }

  void toggleBusStops() {
    _showBusStops = !_showBusStops;
    notifyListeners();
  }


  // ─── 60 FPS METRO TRAIN SIMULATION ENGINE ───
  void _initMetroTrainSimulation() {
    _metroTrains = [];
    final rng = math.Random(42);

    _metroStations.forEach((lineCode, stations) {
      if (stations.length < 2) return;
      final trainCount = math.max(2, math.min(5, (stations.length / 4).floor()));

      // Official Metro Kinematics
      String systemType = 'Standart Metro';
      double accRate = 0.89;
      double decRate = 1.04;
      String specText = 'Standart Metro (Ort. Hızlanma: 0,89 • Ort. Fren: 1,04 m/s²)';
      double baseMaxSpeed = 75.0;

      if (lineCode == 'M5' || lineCode == 'M8') {
        systemType = 'Sürücüsüz Metro';
        accRate = 1.05;
        decRate = 1.15;
        specText = 'Sürücüsüz (Hızlanma: 1,0-1,1 • Fren: 1,1-1,2 m/s²)';
        baseMaxSpeed = 80.0;
      } else if (lineCode.startsWith('M1') || lineCode.startsWith('T')) {
        systemType = lineCode.startsWith('M1') ? 'Hafif Metro' : 'Tramvay';
        accRate = 1.10;
        decRate = 1.20;
        specText = 'Hafif Metro / Tramvay (Hızlanma: 1,0-1,2 • Fren: 1,1-1,3 m/s²)';
        baseMaxSpeed = lineCode.startsWith('T') ? 48.0 : 70.0;
      } else if (lineCode.startsWith('F') || lineCode.startsWith('TF')) {
        systemType = lineCode.startsWith('F') ? 'Füniküler' : 'Teleferik';
        accRate = 0.75;
        decRate = 0.85;
        specText = 'Kablolu Sistem (Hızlanma: 0,7-0,8 • Fren: 0,8-0,9 m/s²)';
        baseMaxSpeed = 30.0;
      }

      final lineColor = getMetroLineColor(lineCode);

      for (int i = 0; i < trainCount; i++) {
        final dir = i % 2 == 0 ? 1 : -1;
        final initialSeg = math.min(stations.length - 2, math.max(0, ((stations.length - 1) * (i / trainCount)).floor()));

        final sFrom = dir == 1 ? stations[initialSeg] : stations[initialSeg + 1];
        final sTo = dir == 1 ? stations[initialSeg + 1] : stations[initialSeg];

        final maxSpeed = baseMaxSpeed + rng.nextInt(4);
        final distM = math.max(350.0, _distanceMeters(sFrom.lat, sFrom.lon, sTo.lat, sTo.lon));
        final segDuration = math.max(25.0, (distM / ((maxSpeed / 3.6) * 0.85)));
        final initProg = ((i * 0.33) % 0.85) + 0.05;

        final remMeters = distM * (1.0 - initProg);
        final etaSec = math.max(1.0, remMeters / ((maxSpeed / 3.6) * 0.85));

        _metroTrains.add(MetroTrainVehicle(
          id: '$lineCode-${i + 1}',
          lineCode: lineCode,
          systemType: systemType,
          color: lineColor,
          stations: stations,
          dir: dir,
          segIdx: initialSeg,
          progress: initProg,
          currentSpeed: maxSpeed * 0.85,
          currentAcc: 0.0,
          accRate: accRate,
          decRate: decRate,
          specText: specText,
          currentLat: sFrom.lat + (sTo.lat - sFrom.lat) * initProg,
          currentLon: sFrom.lon + (sTo.lon - sFrom.lon) * initProg,
          segDurationSec: segDuration,
          timeInSegSec: segDuration * initProg,
          maxSpeed: maxSpeed,
          targetStationName: sTo.name,
          prevStationName: sFrom.name,
          remainingMeters: remMeters,
          etaSec: etaSec,
        ));
      }
    });

    // Run tick every 100ms for ultra-smooth movement on map
    _trainTicker?.cancel();
    _trainTicker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!_showMetroLines || !_showMetroTrains) return;
      _stepTrains(0.1);
    });
  }

  void _stepTrains(double dt) {
    bool hasMoved = false;

    for (final t in _metroTrains) {
      final stns = t.stations;
      if (stns.length < 2) continue;

      if (t.state == 'AT_STATION') {
        t.dwellRemaining -= dt;
        t.currentSpeed = 0.0;
        t.currentAcc = 0.0;
        t.remainingMeters = 0.0;
        t.etaSec = t.dwellRemaining;

        if (t.dwellRemaining <= 0) {
          t.dwellRemaining = 0;
          // Reverse direction at terminal stations
          if (t.dir == 1) {
            if (t.segIdx >= stns.length - 2) {
              t.dir = -1;
              t.segIdx = stns.length - 2;
            } else {
              t.segIdx += 1;
            }
          } else {
            if (t.segIdx <= 0) {
              t.dir = 1;
              t.segIdx = 0;
            } else {
              t.segIdx -= 1;
            }
          }

          final nextFrom = t.dir == 1 ? stns[t.segIdx] : stns[t.segIdx + 1];
          final nextTo = t.dir == 1 ? stns[t.segIdx + 1] : stns[t.segIdx];
          final distM = math.max(350.0, _distanceMeters(nextFrom.lat, nextFrom.lon, nextTo.lat, nextTo.lon));

          t.segDurationSec = math.max(25.0, distM / ((t.maxSpeed / 3.6) * 0.85));
          t.timeInSegSec = 0;
          t.progress = 0;
          t.state = 'ACCELERATING';
          t.currentAcc = t.accRate;
          t.currentSpeed = 15.0;
          t.prevStationName = nextFrom.name;
          t.targetStationName = nextTo.name;
          t.remainingMeters = distM;
          t.etaSec = distM / (t.maxSpeed / 3.6);
        }
      } else {
        t.timeInSegSec += dt;
        t.progress = math.min(1.0, t.timeInSegSec / t.segDurationSec);

        final sFrom = t.dir == 1 ? stns[t.segIdx] : stns[t.segIdx + 1];
        final sTo = t.dir == 1 ? stns[t.segIdx + 1] : stns[t.segIdx];

        if (t.progress >= 1.0) {
          t.progress = 1.0;
          t.state = 'AT_STATION';
          t.currentSpeed = 0;
          t.currentAcc = 0.0;
          t.dwellRemaining = 12.0;
          t.currentLat = sTo.lat;
          t.currentLon = sTo.lon;
          t.remainingMeters = 0.0;
          t.etaSec = 0.0;
        } else {
          t.currentLat = sFrom.lat + (sTo.lat - sFrom.lat) * t.progress;
          t.currentLon = sFrom.lon + (sTo.lon - sFrom.lon) * t.progress;

          final remMeters = _distanceMeters(t.currentLat, t.currentLon, sTo.lat, sTo.lon);
          t.remainingMeters = remMeters;

          // Kinematics phase transitions
          if (t.progress < 0.20) {
            t.state = 'ACCELERATING';
            t.currentAcc = t.accRate;
            t.currentSpeed = math.max(15.0, t.maxSpeed * (0.2 + 0.8 * (t.progress / 0.20)));
          } else if (t.progress > 0.80) {
            t.state = 'DECELERATING';
            t.currentAcc = -t.decRate;
            t.currentSpeed = math.max(12.0, t.maxSpeed * (1.0 - (t.progress - 0.80) / 0.20 * 0.8));
          } else {
            t.state = 'CRUISING';
            t.currentAcc = 0.0;
            t.currentSpeed = t.maxSpeed;
          }

          final spdMs = math.max(4.0, t.currentSpeed / 3.6);
          t.etaSec = math.max(1.0, remMeters / spdMs);
        }
        hasMoved = true;
      }

      // Synchronize inspected train reference so the live sheet auto-updates
      if (_selectedTrain != null && _selectedTrain!.id == t.id) {
        _selectedTrain = t;
      }
    }

    if (hasMoved) {
      notifyListeners();
    }
  }

  // Location handling
  Future<void> _initLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        _userLocation = LatLng(pos.latitude, pos.longitude);
        _cameraCenter = _userLocation!;
        notifyListeners();

        _positionSubscription = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 15,
          ),
        ).listen((Position position) {
          _userLocation = LatLng(position.latitude, position.longitude);
          notifyListeners();
        });
      }
    } catch (_) {}
  }

  Future<LatLng?> locateUser() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        _userLocation = LatLng(pos.latitude, pos.longitude);
        _cameraCenter = _userLocation!;
        notifyListeners();
        return _userLocation;
      }
    } catch (_) {}
    return null;
  }

  double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const double R = 6371000;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) *
        math.sin(dLon / 2) * math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return R * c;
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _trainTicker?.cancel();
    _dragDebounceTimer?.cancel();
    _positionSubscription?.cancel();
    super.dispose();
  }
}

class _LineStats {
  final String code;
  int inViewCount = 0;
  int nearbyCount = 0;
  double minDistance = double.infinity;

  _LineStats(this.code);
}
