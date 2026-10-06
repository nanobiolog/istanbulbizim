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
  bool _isLoading = false;
  String? _errorMessage;
  String? _cartoApiKey;

  // Selected Line Filter
  String? _selectedLineCode;
  LineRouteDetails? _selectedLineRoute;
  String _selectedDirection = 'ALL'; // 'ALL', 'D', 'G'

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
  String? get selectedLineCode => _selectedLineCode;
  LineRouteDetails? get selectedLineRoute => _selectedLineRoute;
  String get selectedDirection => _selectedDirection;
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

    // Start background sync every 15 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      refreshFleet(silent: true);
    });

    _initLocation();
  }

  void updateCameraPosition(LatLng center, double zoom) {
    _cameraCenter = center;
    _currentZoom = zoom;
    notifyListeners();
  }

  Future<void> refreshFleet({bool silent = false}) async {
    if (!silent) {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      if (_selectedLineCode != null) {
        _buses = await _apiService.fetchBusesForLine(_selectedLineCode!);
      } else {
        _buses = await _apiService.fetchFleetBuses();
      }
      _lastUpdated = DateTime.now();
      _errorMessage = null;
    } catch (_) {
      if (!silent) {
        _errorMessage = 'Veriler güncellenirken hata oluştu';
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> selectLine(String? lineCode) async {
    if (lineCode == null || lineCode.isEmpty) {
      _selectedLineCode = null;
      _selectedLineRoute = null;
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
    _isLoading = true;
    notifyListeners();

    try {
      _selectedLineRoute = await _apiService.fetchLineRoute(upper);
      _buses = await _apiService.fetchBusesForLine(upper);
      _lastUpdated = DateTime.now();
    } catch (_) {
      _errorMessage = 'Hat güzergahı alınamadı: $upper';
    } finally {
      _isLoading = false;
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
    _positionSubscription?.cancel();
    super.dispose();
  }
}
