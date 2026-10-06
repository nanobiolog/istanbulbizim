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

  // Selected Bus for Detail Sheet
  BusVehicle? _selectedBus;

  // Metro Overlay & 60fps Train Simulation
  bool _showMetroLines = true;
  bool _showMetroTrains = true;
  Map<String, List<MetroStation>> _metroStations = {};
  Map<String, String> _metroColors = {};
  List<MetroTrainVehicle> _metroTrains = [];
  Timer? _trainTicker;

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
  bool get showMetroLines => _showMetroLines;
  bool get showMetroTrains => _showMetroTrains;
  Map<String, List<MetroStation>> get metroStations => _metroStations;
  Map<String, String> get metroColors => _metroColors;
  List<MetroTrainVehicle> get metroTrains => _metroTrains;
  LatLng? get userLocation => _userLocation;
  LatLng get cameraCenter => _cameraCenter;
  double get currentZoom => _currentZoom;
  DateTime? get lastUpdated => _lastUpdated;
  int get activeBusCount => _buses.length;

  /// Map Tile Layer URL: Uses Cloudflare Worker proxy which attaches CARTO_API_KEY from Cloudflare secrets
  String get tileUrl {
    // If worker URL is active, fetch through Cloudflare Worker proxy with secrets attached
    return '${TransitApiService.defaultWorkerUrl}/tile/voyager/{z}/{x}/{y}@2x.png';
  }

  /// Crucial Performance Filter:
  /// When a line is selected, show that line's buses.
  /// When viewing the entire fleet, prevent crash by only rendering buses within 5 km of camera or user,
  /// and don't render clutter if zoomed out too far (< 12.0).
  List<BusVehicle> get visibleBuses {
    if (_selectedLineCode != null) {
      if (_selectedDirection == 'ALL') return _buses;
      return _buses.where((b) => b.direction.isEmpty || b.direction == _selectedDirection).toList();
    }

    // Zoom-dependent density control:
    // If zoomed out completely, render at most 25 landmark buses to prevent canvas freeze
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

  List<String> get popularLines => [
        '500T',
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
    _isLoading = true;
    notifyListeners();

    try {
      // 1. Fetch line route & stops with OSRM road snapping
      _selectedLineRoute = await _apiService.fetchLineRoute(upper);
      // 2. Fetch buses for this line
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

  // ─── 60 FPS METRO TRAIN SIMULATION ENGINE ───
  void _initMetroTrainSimulation() {
    _metroTrains = [];
    final rng = math.Random(42);

    _metroStations.forEach((lineCode, stations) {
      if (stations.length < 2) return;
      final trainCount = math.max(2, math.min(5, (stations.length / 4).floor()));

      for (int i = 0; i < trainCount; i++) {
        final dir = i % 2 == 0 ? 1 : -1;
        final initialSeg = math.min(stations.length - 2, math.max(0, ((stations.length - 1) * (i / trainCount)).floor()));

        final sFrom = dir == 1 ? stations[initialSeg] : stations[initialSeg + 1];
        final sTo = dir == 1 ? stations[initialSeg + 1] : stations[initialSeg];

        final maxSpeed = lineCode.startsWith('T')
            ? 45.0 + rng.nextInt(8)
            : (lineCode.startsWith('F') || lineCode.startsWith('TF'))
                ? 30.0 + rng.nextInt(5)
                : 75.0 + rng.nextInt(10);

        final distM = math.max(350.0, _distanceMeters(sFrom.lat, sFrom.lon, sTo.lat, sTo.lon));
        final segDuration = math.max(25.0, (distM / ((maxSpeed / 3.6) * 0.85)));
        final initProg = ((i * 0.33) % 0.85) + 0.05;

        _metroTrains.add(MetroTrainVehicle(
          id: '$lineCode-${i + 1}',
          lineCode: lineCode,
          systemType: lineCode.startsWith('M') ? 'Metro' : (lineCode.startsWith('T') ? 'Tramvay' : 'Raylı'),
          color: const Color(0xFF18181B), // Crisp monochrome black & white
          stations: stations,
          dir: dir,
          segIdx: initialSeg,
          progress: initProg,
          currentSpeed: maxSpeed * 0.85,
          currentLat: sFrom.lat + (sTo.lat - sFrom.lat) * initProg,
          currentLon: sFrom.lon + (sTo.lon - sFrom.lon) * initProg,
          segDurationSec: segDuration,
          timeInSegSec: segDuration * initProg,
          maxSpeed: maxSpeed,
          targetStationName: sTo.name,
          prevStationName: sFrom.name,
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
          t.prevStationName = nextFrom.name;
          t.targetStationName = nextTo.name;
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
          t.dwellRemaining = 12.0;
          t.currentLat = sTo.lat;
          t.currentLon = sTo.lon;
        } else {
          t.currentLat = sFrom.lat + (sTo.lat - sFrom.lat) * t.progress;
          t.currentLon = sFrom.lon + (sTo.lon - sFrom.lon) * t.progress;
        }
        hasMoved = true;
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
