import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../models/network_models.dart';
import '../models/rail_models.dart';
import '../models/transit_models.dart';
import '../services/app_clock.dart';
import '../services/eta_engine.dart';
import '../services/network_repository.dart';
import '../services/platform/web_caps.dart';
import '../services/rail_engine.dart';
import '../services/rail_schedule_service.dart';
import '../services/schedule_engine.dart';
import '../services/transit_api_service.dart';
import '../three_d/engine3d.dart' show Render3DQuality;
import '../three_d/station_scene.dart';

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
  int _refreshIntervalSec = 10; // 10s, 15s, 30s (cheap: conditional GET returns 304 between batches)
  bool _highContrastTiles = true;

  // Selected Line Filter & Timetables
  String? _selectedLineCode;
  LineRouteDetails? _selectedLineRoute;
  String _selectedDirection = 'ALL'; // 'ALL', 'D', 'G'
  LineTimetable? _selectedLineTimetable;
  bool _isLoadingTimetable = false;

  // Selected Bus / Train / Bus Stop / Station / Pier / Vessel for Detail Sheets
  BusVehicle? _selectedBus;
  String? _selectedTrainId;
  BusStop? _selectedStop;
  NetworkStation? _selectedStation;
  String? _selectedStationLine;
  Pier? _selectedPier;
  String? _selectedVesselId;
  int? _selectedLiveVesselMmsi;
  bool _followLocked = false;
  bool _revealStation = false;
  StationStage? _revealFocus;
  String? _selectedRailLine;

  // Layers & Map Modes (Buses & bus stops off by default until a line is chosen or toggled, keeping the map clean)
  bool _isNightMode = true; // Night mode enabled by default (Carto dark_all)
  bool _showBuses = false;
  bool _showMetroLines = true;
  bool _showMetroTrains = true;
  bool _showBusStops = false;
  bool _showFerries = true;
  bool _showProjects = false;
  bool _showEntrances = true;

  // Rail & ferry network (real track geometry, plans, timetables) + schedule engine
  final NetworkRepository network = NetworkRepository();
  ScheduleEngine? _engine;
  List<ScheduledTrain> _trains = const [];
  List<FerryVessel> _vessels = const [];
  List<LiveVessel> _liveVessels = const [];
  bool _aisConfigured = false;
  DateTime? _liveVesselsAt;
  Map<String, String> _metroColors = {};
  Map<String, Color> _metroLineColors = {};
  Timer? _trainTicker;
  Timer? _liveFerryTimer;

  /// Bumped whenever vehicle positions are recomputed. Only the vehicle layers listen to it, so
  /// moving trains and ferries never rebuild the rest of the screen.
  final ValueNotifier<int> vehicleTick = ValueNotifier<int>(0);

  /// No WebGL (software rendering in the browser): fewer updates, simpler markers.
  bool liteMode = false;
  DateTime _railStepAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Official timetables (Metro İstanbul / TCDD plan) for the 3D map, station view and AR screens
  Map<String, List<MetroStation>> _metroStations = {};
  List<MetroTrainVehicle> _metroTrains = [];
  late final RailScheduleService _rail = RailScheduleService(baseUrl: () => _apiService.baseUrl);
  Map<String, List<RailStation>> _railStations = {};
  final Map<String, RailSchedule> _railSchedules = {};
  Map<String, List<RailStatusItem>> _railStatus = {};
  RailServiceDay? _railDay;
  int _railLoadedCount = 0;

  // Bus Stops (~14,000 Istanbul bus stops database)
  List<BusStop> _busStops = [];

  // User GPS Location & Map Camera
  LatLng? _userLocation;
  LatLng _cameraCenter = const LatLng(41.0082, 28.9784);
  double _currentZoom = 12.4;
  StreamSubscription<Position>? _positionSubscription;

  /// Increments every second. Widgets that show countdowns/ages listen to this (not to the whole
  /// provider) so only the small text re-renders and numbers keep beating without any refetch.
  final ValueNotifier<int> clock = ValueNotifier<int>(0);
  Timer? _clockTimer;

  // Auto-refresh timer
  Timer? _refreshTimer;
  DateTime? _lastUpdated;

  TransitProvider() {
    liteMode = !gpuRenderingAvailable;
    Render3DQuality.lite = liteMode;
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      clock.value++;
      if (clock.value % 20 == 0) _refreshTraffic();
      if (clock.value % 180 == 0) _refreshRailStatus();
      if (clock.value % 300 == 0) _refreshHubData(full: clock.value % 21600 == 0);
    });
    _init();
  }

  TrafficSummary? get traffic => _apiService.traffic;
  TransitApiService get api => _apiService;

  Future<void> _refreshTraffic() async {
    await _apiService.refreshTraffic();
    notifyListeners();
  }

  /// Server ETAs for a stop (route + traffic aware). Null when the Worker is unreachable.
  Future<List<StopArrival>?> loadStopArrivals(BusStop stop) => _apiService.fetchStopArrivals(stop.code);

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
  BusStop? get selectedStop => _selectedStop;
  NetworkStation? get selectedStation => _selectedStation;
  Pier? get selectedPier => _selectedPier;
  bool get revealStation => _revealStation && _selectedStation != null;
  StationStage? get revealFocus => _revealFocus;
  ScheduleEngine? get engine => _engine;
  RailLine? get selectedRailLine => _selectedRailLine == null ? null : network.lineByCode[_selectedRailLine];

  /// Rail line code for a search term ("Marmaray" -> B1), or null if it is not a rail line.
  String? railCodeFor(String term) {
    final t = term.trim().toUpperCase();
    if (t == 'MARMARAY' || t == 'B1') return network.lineByCode.containsKey('B1') ? 'B1' : null;
    return network.lineByCode.containsKey(t) ? t : null;
  }

  void selectRailLine(String? code) {
    _clearSelections();
    _selectedRailLine = code;
    if (code != null && _selectedLineCode != null) {
      _selectedLineCode = null;
      _selectedLineRoute = null;
      _selectedLineTimetable = null;
      _selectedDirection = 'ALL';
      refreshFleet(silent: true);
    }
    notifyListeners();
  }

  /// The line the selected station is shown for (its deepest line by default).
  RailLine? get selectedStationLine {
    final st = _selectedStation;
    if (st == null) return null;
    return network.lineByCode[_selectedStationLine ?? st.primaryLine] ?? network.linesAt(st).firstOrNull;
  }

  StationPlan? get selectedStationPlan {
    final st = _selectedStation, l = selectedStationLine;
    return (st == null || l == null) ? null : StationPlan(st, l);
  }

  ScheduledTrain? get selectedTrain {
    final id = _selectedTrainId;
    if (id == null) return null;
    for (final t in _trains) {
      if (t.id == id) return t;
    }
    return _engine?.trainById(id, AppClock.now());
  }

  FerryVessel? get selectedVessel {
    final id = _selectedVesselId;
    if (id == null) return null;
    for (final v in _vessels) {
      if (v.id == id) return v;
    }
    return _engine?.vesselById(id, AppClock.now());
  }

  LiveVessel? get selectedLiveVessel {
    final mmsi = _selectedLiveVesselMmsi;
    if (mmsi == null) return null;
    for (final v in _liveVessels) {
      if (v.mmsi == mmsi) return v;
    }
    return null;
  }

  bool get hasFollowedVehicle =>
      _selectedBus != null ||
      _selectedTrainId != null ||
      _selectedVesselId != null ||
      _selectedLiveVesselMmsi != null;

  bool get isFollowingVehicle => _followLocked && followedVehiclePosition != null;

  void setFollowLocked(bool locked) {
    if (_followLocked == locked) return;
    _followLocked = locked;
    notifyListeners();
  }

  void toggleFollowLocked() {
    _followLocked = !_followLocked;
    notifyListeners();
  }

  /// Live interpolated coordinate of whichever vehicle is currently selected/followed.
  LatLng? get followedVehiclePosition {
    if (_selectedBus != null) {
      return LatLng(_selectedBus!.displayLat, _selectedBus!.displayLon);
    }
    if (_selectedTrainId != null) {
      return selectedTrain?.pos;
    }
    if (_selectedVesselId != null) {
      return selectedVessel?.pos;
    }
    if (_selectedLiveVesselMmsi != null) {
      final lv = selectedLiveVessel;
      if (lv != null) return lv.posAt(_liveVesselsAt, AppClock.now());
    }
    return null;
  }

  String? get followedVehicleLabel {
    if (_selectedBus != null) {
      final dest = _selectedBus!.destination.isNotEmpty ? ' → ${_selectedBus!.destination}' : '';
      return '${_selectedBus!.line}$dest';
    }
    if (_selectedTrainId != null) {
      final t = selectedTrain;
      if (t != null) return '${t.line.code} → ${t.variant.to}';
    }
    if (_selectedVesselId != null) {
      final v = selectedVessel;
      if (v != null) return '${v.op?.name ?? 'Vapur'} (${v.line.name})';
    }
    if (_selectedLiveVesselMmsi != null) {
      final lv = selectedLiveVessel;
      if (lv != null) return lv.name;
    }
    return null;
  }

  bool get isNightMode => _isNightMode;
  bool get showBuses => _showBuses;
  bool get showMetroLines => _showMetroLines;
  bool get showMetroTrains => _showMetroTrains;
  bool get showBusStops => _showBusStops;
  bool get showFerries => _showFerries;
  bool get showProjects => _showProjects;
  bool get showEntrances => _showEntrances;

  Map<String, String> get metroColors => _metroColors;
  Map<String, List<MetroStation>> get metroStations => _metroStations;
  /// Official-timetable trains for the 3D map / station view / AR. Computed on demand only.
  List<MetroTrainVehicle> get metroTrains {
    if (DateTime.now().difference(_railStepAt).inMilliseconds > 450) _stepRailVehicles();
    return _metroTrains;
  }
  List<ScheduledTrain> get scheduledTrains => _trains;
  List<FerryVessel> get scheduledVessels => _vessels;
  List<LiveVessel> get liveVessels => _liveVessels;
  bool get hasLiveFerries => _liveVessels.isNotEmpty;
  bool get aisConfigured => _aisConfigured;
  DateTime? get liveVesselsAt => _liveVesselsAt;
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
    final hasKey = _cartoApiKey != null && _cartoApiKey!.isNotEmpty;
    if (!hasKey) {
      // No key on this device yet (first ever launch, offline): go through the Worker tile proxy,
      // which holds the key server-side. Never shows a "key not found" state.
      return '${_apiService.baseUrl}/tile/$style/{z}/{x}/{y}@2x.png';
    }
    return 'https://{s}.basemaps.cartocdn.com/rastertiles/$style/{z}/{x}/{y}@2x.png?key=$_cartoApiKey';
  }

  /// Color Resolver for Metro and Transit lines
  Color getMetroLineColor(String lineCode) {
    final code = lineCode.trim().toUpperCase();
    final net = network.lineByCode[code == 'MARMARAY' ? 'B1' : code];
    if (net != null) return net.color;
    if (_metroLineColors.containsKey(code)) {
      return _metroLineColors[code]!;
    }
    if (code == 'B1' || code == 'MARMARAY') {
      return const Color(0xFFB4192D);
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

  // Cached visible bus list to avoid re-filtering 60 times a second during animations
  List<BusVehicle> _cachedVisibleBuses = [];
  LatLng _lastFilterCenter = const LatLng(0, 0);
  double _lastFilterZoom = 0;
  String? _lastFilterLine;
  String _lastFilterDir = 'ALL';

  /// Crucial Performance & De-Crowding Filter:
  /// - When a bus line is selected, always show that line's buses.
  /// - When no bus line is selected, only show buses if [_showBuses] ("Yakın Otobüsler") is enabled,
  ///   and apply spatial separation + tight viewport caps so the map never looks overcrowded.
  List<BusVehicle> get visibleBuses {
    if (_selectedLineCode == null && !_showBuses) {
      return _selectedBus != null ? [_selectedBus!] : const [];
    }

    // Recompute if filter parameters changed significantly (focus on map viewport center)
    final center = _cameraCenter;
    final distMoved = _distanceMeters(_lastFilterCenter.latitude, _lastFilterCenter.longitude, center.latitude, center.longitude);
    final zoomDiff = (_lastFilterZoom - _currentZoom).abs();

    if (_cachedVisibleBuses.isNotEmpty &&
        distMoved < 150 &&
        zoomDiff < 0.25 &&
        _lastFilterLine == _selectedLineCode &&
        _lastFilterDir == _selectedDirection) {
      return _cachedVisibleBuses;
    }

    _lastFilterCenter = center;
    _lastFilterZoom = _currentZoom;
    _lastFilterLine = _selectedLineCode;
    _lastFilterDir = _selectedDirection;

    if (_selectedLineCode != null) {
      if (_selectedDirection == 'ALL') {
        _cachedVisibleBuses = _buses;
      } else {
        _cachedVisibleBuses = _buses.where((b) => b.direction.isEmpty || b.direction == _selectedDirection).toList();
      }
      return _cachedVisibleBuses;
    }

    // Zoomed out the map belongs to the rail/ferry network; nearby buses appear from neighborhood level up.
    if (_currentZoom < 12.6) {
      _cachedVisibleBuses = _selectedBus != null ? [_selectedBus!] : const [];
      return _cachedVisibleBuses;
    }

    // Dynamic density control + spatial separation so general buses never overlap each other:
    final double radiusMeters = _currentZoom >= 14.5 ? 2800 : (_currentZoom >= 13.5 ? 2400 : 2000);
    final int maxBuses = _currentZoom >= 15.0 ? 32 : (_currentZoom >= 14.0 ? 24 : 16);
    final double minSeparationMeters = _currentZoom >= 15.0 ? 55 : (_currentZoom >= 14.0 ? 95 : 140);

    final candidates = <({BusVehicle bus, double dist})>[];
    for (final bus in _buses) {
      final d = _distanceMeters(center.latitude, center.longitude, bus.displayLat, bus.displayLon);
      if (d <= radiusMeters) {
        candidates.add((bus: bus, dist: d));
      }
    }
    candidates.sort((a, b) => a.dist.compareTo(b.dist));

    final nearBuses = <BusVehicle>[];
    if (_selectedBus != null) {
      nearBuses.add(_selectedBus!);
    }
    for (final c in candidates) {
      if (nearBuses.length >= maxBuses) break;
      if (_selectedBus != null && c.bus.id == _selectedBus!.id) continue;
      bool tooClose = false;
      for (final placed in nearBuses) {
        if (_distanceMeters(placed.displayLat, placed.displayLon, c.bus.displayLat, c.bus.displayLon) < minSeparationMeters) {
          tooClose = true;
          break;
        }
      }
      if (!tooClose) {
        nearBuses.add(c.bus);
      }
    }

    _cachedVisibleBuses = nearBuses;
    return _cachedVisibleBuses;
  }

  /// Viewport filtered bus stops using spatial grid indexing and separation for a clean map
  List<BusStop> get visibleBusStops {
    if (!_showBusStops || _busStops.isEmpty) {
      return _selectedStop != null ? [_selectedStop!] : const [];
    }
    if (_currentZoom < 14.2) {
      return _selectedStop != null ? [_selectedStop!] : const [];
    }

    final center = _cameraCenter;
    final double radiusMeters = _currentZoom >= 15.5 ? 1400 : 2000;
    final int maxStops = _currentZoom >= 15.5 ? 70 : 42;

    final grid = _apiService.busStopsGrid;
    final stopsList = <BusStop>[];
    final addedCodes = <String>{};

    // Always include selected stop so it never disappears on zoom or map movement
    if (_selectedStop != null) {
      stopsList.add(_selectedStop!);
      addedCodes.add(_selectedStop!.code);
    }

    if (grid.isNotEmpty) {
      final centerLatCell = (center.latitude * 50).floor();
      final centerLonCell = (center.longitude * 50).floor();

      // Center-outward order: center cell (0,0) first, then surrounding rings
      const offsets = [
        [0, 0],
        [0, 1], [1, 0], [0, -1], [-1, 0],
        [1, 1], [1, -1], [-1, 1], [-1, -1],
        [0, 2], [2, 0], [0, -2], [-2, 0],
        [1, 2], [2, 1], [-1, 2], [2, -1],
        [1, -2], [-2, 1], [-1, -2], [-2, -1],
      ];

      for (final off in offsets) {
        final dy = off[0];
        final dx = off[1];
        final cellKey = ((centerLatCell + dy) << 16) ^ ((centerLonCell + dx) & 0xFFFF);
        final inCell = grid[cellKey];
        if (inCell != null) {
          for (final s in inCell) {
            if (!addedCodes.contains(s.code)) {
              if (_distanceMeters(center.latitude, center.longitude, s.lat, s.lon) <= radiusMeters) {
                stopsList.add(s);
                addedCodes.add(s.code);
                if (stopsList.length >= maxStops) break;
              }
            }
          }
        }
        if (stopsList.length >= maxStops) break;
      }
    } else {
      for (final s in _busStops) {
        if (!addedCodes.contains(s.code)) {
          if (_distanceMeters(center.latitude, center.longitude, s.lat, s.lon) <= radiusMeters) {
            stopsList.add(s);
            addedCodes.add(s.code);
            if (stopsList.length >= maxStops) break;
          }
        }
      }
    }

    return stopsList;
  }

  /// Calculate live approaching buses for an inspected bus stop (ONLY for lines verified to serve this stop)
  List<Map<String, dynamic>> getApproachingBusesForStop(BusStop stop) {
    final result = <Map<String, dynamic>>[];
    final lineRoute = _selectedLineRoute;
    if (lineRoute != null) {
      // Line is selected: only show buses from this line that haven't passed the stop yet
      for (final bus in _buses) {
        if (bus.line == lineRoute.code) {
          final dist = _distanceMeters(bus.lat, bus.lon, stop.lat, stop.lon);
          if (dist <= 6000) {
            final speedMs = bus.speed > 5 ? (bus.speed / 3.6) : 6.0;
            final estSec = math.max(20, (dist / speedMs).round());
            result.add({
              'bus': bus,
              'dist_m': dist.round(),
              'est_sec': estSec,
            });
          }
        }
      }
    }
    result.sort((a, b) => (a['dist_m'] as int).compareTo(b['dist_m'] as int));
    return result.take(12).toList();
  }

  List<LineInfo> get allLines => _apiService.allLines;

  List<String> get popularLines => [
        'B1',
        'MARMARAY',
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

    // Key first (env / persisted) — synchronous-ish disk read, no network.
    await _apiService.loadPersisted();
    _cartoApiKey = _apiService.cartoApiKey;

    // Kick off the network bootstrap in parallel with local asset parsing: key + first fleet + traffic.
    final bootstrapFuture = _apiService.bootstrap();

    await Future.wait([_apiService.loadLocalAssets(), network.load()]);
    _metroColors = _apiService.metroColors;
    _metroStations = _apiService.metroStations;
    _busStops = _apiService.busStops;

    _metroLineColors = {};
    _metroColors.forEach((k, v) {
      _metroLineColors[k] = TransitApiService.parseColorString(v);
    });

    if (_disposed) return;
    _engine = ScheduleEngine(network);
    _initRailSchedules();
    _startScheduleTicker();
    notifyListeners();
    refreshLiveFerries();
    _refreshHubData(full: true);

    final boot = await bootstrapFuture;
    if (_apiService.cartoApiKey != null && _apiService.cartoApiKey != _cartoApiKey) {
      _cartoApiKey = _apiService.cartoApiKey; // refreshed key; tiles reload once, silently
    }
    if (boot != null && boot.isNotEmpty) {
      _fleetBuses = boot;
      _buses = _enrichBusesWithNextStops(boot);
      _lastUpdated = DateTime.now();
      _lastSuccessfulSync = _lastUpdated;
      _computeNearbyLines();
      _isLoading = false;
      notifyListeners();
    }

    await refreshFleet(silent: boot != null && boot.isNotEmpty);

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

    // Debounce recalculation during dragging / zooming to keep map 60 FPS silky smooth
    _dragDebounceTimer?.cancel();
    _dragDebounceTimer = Timer(const Duration(milliseconds: 220), () {
      final distMoved = _distanceMeters(
        _lastComputedCenter.latitude,
        _lastComputedCenter.longitude,
        _cameraCenter.latitude,
        _cameraCenter.longitude,
      );
      final zoomDiff = (_lastComputedZoom - _currentZoom).abs();

      if (distMoved > 200 || zoomDiff > 0.3) {
        _computeNearbyLines();
        notifyListeners();
      }
    });
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
        // Rail lines have no IETT vehicles; their trains come from the timetable engines.
        raw = _isRailLine(_selectedLineCode!) ? const [] : await _apiService.fetchBusesForLine(_selectedLineCode!);
      } else {
        raw = await _apiService.fetchFleetBuses();
      }
      final enriched = _enrichBusesWithNextStops(raw);
      _buses = enriched;
      if (_selectedLineCode == null) {
        _fleetBuses = enriched;
      }
      _cachedVisibleBuses = [];
      _lastUpdated = DateTime.now();
      _lastSuccessfulSync = DateTime.now();
      _isOffline = false;
      _errorMessage = null;
      _computeNearbyLines();

      // Keep active selected bus updated with latest telemetry and smooth motion state
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

  /// Calculates destination, upcoming next stop, live ETA, and C1-continuous motion state for buses
  List<BusVehicle> _enrichBusesWithNextStops(List<BusVehicle> input) {
    if (input.isEmpty) return input;
    final now = DateTime.now();
    final prevById = <String, BusVehicle>{
      for (final b in _fleetBuses) b.id: b,
      for (final b in _buses) b.id: b,
    };
    final selBus = _selectedBus;
    if (selBus != null) prevById[selBus.id] = selBus;

    // Route-aware, traffic-aware ETA for the selected line (keeps server ETAs when present)
    final list = (_selectedLineRoute != null && _selectedLineCode != null)
        ? EtaEngine.annotate(input, _selectedLineRoute, _apiService.traffic, now)
        : input;

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

      if (route != null && route.directions.isNotEmpty && bus.etaAt == null) {
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

      // 2. Fallback: Find nearest bus stop using spatial grid indexing
      if (nextStop.isEmpty && _busStops.isNotEmpty) {
        double minD = double.infinity;
        BusStop? nearest;

        final grid = _apiService.busStopsGrid;
        if (grid.isNotEmpty) {
          final latCell = (bus.lat * 50).floor();
          final lonCell = (bus.lon * 50).floor();

          for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
              final cellKey = ((latCell + dy) << 16) ^ ((lonCell + dx) & 0xFFFF);
              final inCell = grid[cellKey];
              if (inCell != null) {
                for (final s in inCell) {
                  final d = _distanceMeters(bus.lat, bus.lon, s.lat, s.lon);
                  if (d < minD && d < 2500) {
                    minD = d;
                    nearest = s;
                  }
                }
              }
            }
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

      final updated = bus.copyWith(
        destination: dest,
        nextStop: nextStop,
        nextStopEtaSec: etaSec,
        nextStopDistM: nextDistM,
        directionName: dirName,
        headsign: headsign,
        etaAt: bus.etaAt ?? (etaSec == null ? null : now.add(Duration(seconds: etaSec))),
        etaConf: bus.etaConf.isEmpty && etaSec != null ? 'low' : null,
      );
      final prev = prevById[updated.id];
      if (prev != null) {
        updated.inheritSmoothMotionFrom(prev, now);
      }
      return updated;
    }).toList();
  }

  Future<void> selectLine(String? lineCode) async {
    if (lineCode == null || lineCode.isEmpty) {
      _selectedLineCode = null;
      _selectedLineRoute = null;
      _selectedLineTimetable = null;
      _selectedDirection = 'ALL';
      _selectedBus = null;
      _followLocked = false;
      _cachedVisibleBuses = [];
      await refreshFleet();
      return;
    }

    final upper = lineCode.trim().toUpperCase();
    _selectedLineCode = upper;
    _selectedRailLine = null;
    _clearSelections();
    _selectedLineTimetable = null;
    _cachedVisibleBuses = [];
    _isLoading = true;
    notifyListeners();

    try {
      _selectedLineRoute = await _apiService.fetchLineRoute(upper);
      final raw = _isRailLine(upper) ? const <BusVehicle>[] : await _apiService.fetchBusesForLine(upper);
      _buses = _enrichBusesWithNextStops(raw);
      _cachedVisibleBuses = [];
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
    _cachedVisibleBuses = [];
    notifyListeners();
  }

  void _clearSelections() {
    _selectedBus = null;
    _selectedTrainId = null;
    _selectedStop = null;
    _selectedStation = null;
    _selectedStationLine = null;
    _selectedPier = null;
    _selectedVesselId = null;
    _selectedLiveVesselMmsi = null;
    _followLocked = false;
    _revealStation = false;
    _revealFocus = null;
  }

  void selectStation(NetworkStation? station, {String? line}) {
    _clearSelections();
    _selectedStation = station;
    _selectedStationLine = line;
    notifyListeners();
  }

  void setStationLine(String code) {
    _selectedStationLine = code;
    _revealFocus = null;
    notifyListeners();
  }

  void toggleReveal([bool? on]) {
    _revealStation = on ?? !_revealStation;
    if (!_revealStation) _revealFocus = null;
    notifyListeners();
  }

  void focusStage(StationStage? stage) {
    _revealStation = true;
    _revealFocus = stage;
    notifyListeners();
  }

  void selectPier(Pier? pier) {
    _clearSelections();
    _selectedPier = pier;
    notifyListeners();
  }

  void selectVessel(FerryVessel? v) {
    _clearSelections();
    _selectedVesselId = v?.id;
    _followLocked = v != null;
    notifyListeners();
  }

  void selectLiveVessel(LiveVessel? v) {
    _clearSelections();
    _selectedLiveVesselMmsi = v?.mmsi;
    _followLocked = v != null;
    notifyListeners();
  }

  void selectScheduledTrain(ScheduledTrain? t) {
    _clearSelections();
    _selectedTrainId = t?.id;
    _followLocked = t != null;
    notifyListeners();
  }

  void clearAllSelections() {
    _clearSelections();
    notifyListeners();
  }

  bool get hasDetailSelection =>
      _selectedBus != null || _selectedTrainId != null || _selectedStop != null || _selectedStation != null ||
      _selectedPier != null || _selectedVesselId != null || _selectedLiveVesselMmsi != null;

  void selectBus(BusVehicle? bus) {
    _selectedBus = bus;
    if (bus != null) {
      _selectedTrainId = null;
      _selectedStation = null;
      _selectedPier = null;
      _selectedVesselId = null;
      _selectedLiveVesselMmsi = null;
      _followLocked = true;
      _revealStation = false;
      _selectedStop = null;
      if (bus.line.isNotEmpty) {
        if (_selectedLineTimetable == null || _selectedLineTimetable!.lineCode.toUpperCase() != bus.line.toUpperCase()) {
          loadTimetableForLine(bus.line);
        }
      }
    } else {
      _followLocked = false;
    }
    notifyListeners();
  }

  void selectBusStop(BusStop? stop) {
    if (stop != null) _clearSelections();
    _selectedStop = stop;
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
    _cachedVisibleBuses = [];
    _stepVehicles();
    notifyListeners();
  }

  void toggleMetroLines() {
    _showMetroLines = !_showMetroLines;
    _stepVehicles();
    notifyListeners();
  }

  void toggleMetroTrains() {
    _showMetroTrains = !_showMetroTrains;
    _stepVehicles();
    notifyListeners();
  }

  void toggleBusStops() {
    _showBusStops = !_showBusStops;
    notifyListeners();
  }

  void toggleFerries() {
    _showFerries = !_showFerries;
    _stepVehicles();
    if (_showFerries) refreshLiveFerries();
    notifyListeners();
  }

  void toggleProjects() {
    _showProjects = !_showProjects;
    notifyListeners();
  }

  void toggleEntrances() {
    _showEntrances = !_showEntrances;
    notifyListeners();
  }

  FerryStatus? get ferryStatus => _engine?.ferryStatus;

  /// Fresh data kept up to date by the Worker's TransitHub: ferry cancellations (every 5 min),
  /// refreshed Şehir Hatları timetables and added / removed rail lines (every 6 h).
  Future<void> _refreshHubData({bool full = false}) async {
    if (_disposed) return;
    var changed = false;
    final status = await _apiService.fetchHubDoc('/ferries/status');
    if (status != null && _engine != null) {
      _engine!.ferryStatus = FerryStatus.fromJson(status);
      changed = true;
    }
    if (full) {
      final tt = await _apiService.fetchHubDoc('/ferries/timetables');
      if (tt != null && network.applyFerryTimetables(tt)) changed = true;
      final nc = await _apiService.fetchHubDoc('/network/changes');
      if (nc != null && network.applyNetworkChanges(nc)) {
        // new or closed lines: rebuild the timetable engine and re-apply what we know
        final st = _engine?.ferryStatus;
        _engine = ScheduleEngine(network)..ferryStatus = st;
        for (final sched in _railSchedules.values) {
          _engine!.applyOfficial(sched);
        }
        changed = true;
      }
    }
    if (changed) {
      _stepVehicles();
      notifyListeners();
    }
  }

  /// Live ferry positions (AIS via the Worker). Empty unless the Worker has an AIS key.
  Future<void> refreshLiveFerries() async {
    final res = await _apiService.fetchLiveFerries();
    if (res == null) return;
    _aisConfigured = res.$1;
    _liveVessels = res.$2;
    _liveVesselsAt = DateTime.now();
    notifyListeners();
  }


  // ─── SCHEDULE-DRIVEN TRAINS, FERRIES & CONTINUOUS BUS KINEMATICS (20–30 FPS) ───
  /// Smooth high-frequency ticker so trains, ferries, and buses glide seamlessly without stepping.
  Duration get _tickInterval {
    if (liteMode) return const Duration(milliseconds: 85);
    if (_followLocked && hasFollowedVehicle) return const Duration(milliseconds: 33);
    if (_currentZoom < 11.2 && _selectedLineCode == null) return const Duration(milliseconds: 90);
    return const Duration(milliseconds: 50);
  }

  void _stepVehicles() {
    final e = _engine;
    if (e == null || _disposed) return;
    final now = AppClock.now();
    final wallNow = DateTime.now();
    _trains = (_showMetroLines && _showMetroTrains) ? e.trainsAt(now) : const [];
    _vessels = _showFerries ? e.vesselsAt(now) : const [];
    if (_showBuses || _selectedLineCode != null || _selectedBus != null) {
      for (final b in visibleBuses) {
        b.stepDisplayPosition(wallNow);
      }
      _selectedBus?.stepDisplayPosition(wallNow);
    }
    vehicleTick.value++;
  }

  void _startScheduleTicker() {
    _trainTicker?.cancel();
    _liveFerryTimer?.cancel();
    _stepVehicles();
    void schedule() {
      _trainTicker = Timer(_tickInterval, () {
        if (_disposed) return;
        final active = (_showMetroLines && _showMetroTrains) ||
            _showFerries ||
            _showBuses ||
            _selectedLineCode != null ||
            hasFollowedVehicle;
        if (active) _stepVehicles();
        schedule();
      });
    }

    schedule();
    _liveFerryTimer?.cancel();
    _liveFerryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_showFerries) refreshLiveFerries();
    });
  }

  void _initRailSchedules() {
    final day = railServiceDay(DateTime.now());
    _railDay = day;
    _railStations = {
      for (final e in _metroStations.entries)
        if (e.value.length >= 2)
          e.key: e.value.map((s) => RailStation(name: s.name, lat: s.lat, lon: s.lon)).toList(),
    };
    // Trains appear instantly from the clock-anchored estimate, then switch to the official
    // timetable for each line as it arrives.
    for (final e in _railStations.entries) {
      _railSchedules[e.key] = _rail.cached(e.key, day) ?? buildEstimatedSchedule(e.key, e.value, day);
      _engine?.applyOfficial(_railSchedules[e.key]!);
    }
    _stepRailVehicles();
    _loadRailSchedules(day);
    _refreshRailStatus();
  }

  Future<void> _loadRailSchedules(RailServiceDay day) async {
    // Busiest lines first so the most-used trains become official soonest.
    const priority = ['B1', 'M2', 'M4', 'M1A', 'M1B', 'T1', 'M5', 'M3', 'M7', 'M9', 'M8', 'T4', 'T5', 'M6', 'T3', 'F1', 'F4', 'TF1', 'TF2'];
    final codes = _railStations.keys.toList()
      ..sort((a, b) {
        final ia = priority.indexOf(a), ib = priority.indexOf(b);
        return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
      });
    var next = 0;
    Future<void> worker() async {
      while (next < codes.length) {
        final code = codes[next++];
        final sched = await _rail.load(code, _railStations[code]!, day);
        if (_railDay?.dateKey != day.dateKey) return;
        _railSchedules[code] = sched.withStatus(_railStatus[code] ?? const []);
        _engine?.applyOfficial(sched); // the map, station sheet and 3D views use official times too
        _railLoadedCount++;
        notifyListeners();
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));
  }

  Future<void> _refreshRailStatus() async {
    final st = await _rail.loadStatus();
    if (st == null) return;
    _railStatus = st;
    _railSchedules.updateAll((k, v) => v.withStatus(st[k] ?? const []));
    notifyListeners();
  }

  /// Timetable trains on the old station lists, for the 3D map / station view / AR screens.
  void _stepRailVehicles() {
    _railStepAt = DateTime.now();
    final now = DateTime.now();
    final day = railServiceDay(now);
    if (_railDay != null && day.dateKey != _railDay!.dateKey) {
      // 03:00 rollover: load the new service day's timetables.
      _railDay = day;
      for (final e in _railStations.entries) {
        _railSchedules[e.key] = buildEstimatedSchedule(e.key, e.value, day);
      }
      _loadRailSchedules(day);
    }
    _railDay = day;
    final frac = now.millisecond / 1000.0;

    final trains = <MetroTrainVehicle>[];
    _railSchedules.forEach((code, sched) {
      final prof = railProfile(code);
      final color = getMetroLineColor(code);
      for (final t0 in railPositions(sched, day, extraSec: frac)) {
        final t = _onTrack(code, sched, t0);
        trains.add(MetroTrainVehicle(
          id: t.id,
          lineCode: code,
          systemType: prof.systemType,
          color: color,
          stations: _metroStations[code] ?? const [],
          dir: t.dir == 'G' ? 1 : -1,
          segIdx: math.min(t.prevIndex, t.nextIndex),
          progress: t.progress,
          currentSpeed: t.speedKmh,
          currentAcc: t.accel,
          accRate: prof.accel,
          decRate: prof.decel,
          specText: prof.specText,
          currentLat: t.lat,
          currentLon: t.lon,
          state: t.state,
          dwellRemaining: t.state == 'AT_STATION' ? t.etaSec : 0,
          segDurationSec: 0,
          timeInSegSec: 0,
          maxSpeed: prof.cruiseKmh,
          targetStationName: sched.stations[t.nextIndex].name,
          prevStationName: sched.stations[t.prevIndex].name,
          remainingMeters: t.remainingMeters,
          etaSec: t.etaSec,
          headsign: t.headsign,
          dirCode: t.dir,
          bearing: t.bearing,
          upcoming: t.upcoming,
          official: t.official,
          source: sched.source,
        ));
      }
    });
    _metroTrains = trains;
  }

  final Map<String, double?> _trackDist = {};

  /// Moves a timetable train from the straight station-to-station segment onto the real track
  /// (same timing, OSM geometry of the line's main variant).
  RailTrainState _onTrack(String code, RailSchedule sched, RailTrainState t) {
    final line = network.lineByCode[code];
    if (line == null || line.variants.isEmpty) return t;
    final v = line.variants.first;
    double? distOf(int idx) => _trackDist.putIfAbsent('$code|$idx', () {
          final st = sched.stations[idx];
          final want = railPlainName(st.name);
          RailStop? best;
          var bd = 900.0;
          for (final stop in v.stops) {
            final ns = network.stations[stop.stationId];
            final named = ns != null && (railPlainName(ns.name) == want || railPlainName(ns.name).contains(want) || want.contains(railPlainName(ns.name)));
            final d = haversine(st.lat, st.lon, stop.pos.latitude, stop.pos.longitude);
            if ((named || d < 300) && (named ? d * 0.25 : d) < bd) {
              bd = named ? d * 0.25 : d;
              best = stop;
            }
          }
          return best?.distM;
        });
    final a = distOf(t.prevIndex), b = distOf(t.nextIndex);
    if (a == null || b == null) return t;
    final along = a + (b - a) * t.progress;
    final (p, h) = v.path.pointAt(along);
    return t.copyWith(lat: p.latitude, lon: p.longitude, bearing: b >= a ? h : (h + 180) % 360);
  }

  /// Trains near the camera (a timetable-accurate network has 300+ trains at peak).
  List<MetroTrainVehicle> get visibleMetroTrains {
    if (_currentZoom < 12.0) return const [];
    final radius = (9000.0 * math.pow(2.0, 13.0 - _currentZoom)).clamp(1500.0, 20000.0);
    final c = _cameraCenter;
    return _metroTrains
        .where((t) => _distanceMeters(c.latitude, c.longitude, t.currentLat, t.currentLon) <= radius)
        .toList();
  }

  bool _isRailLine(String code) => code == 'MARMARAY' || _metroStations.containsKey(code);

  RailServiceDay get railDay => _railDay ?? railServiceDay(DateTime.now());
  RailSchedule? railSchedule(String line) => _railSchedules[line == 'MARMARAY' ? 'B1' : line];
  List<RailStatusItem> railStatusFor(String line) => _railStatus[line == 'MARMARAY' ? 'B1' : line] ?? const [];
  int get railOfficialLines => _railSchedules.values.where((s) => s.official).length;
  int get railLoadedCount => _railLoadedCount;

  /// Next departures from [stationIndex] of [line] computed from the loaded schedule.
  List<RailDeparture> departuresAt(String line, int stationIndex, {int perDirection = 4}) {
    final s = railSchedule(line);
    if (s == null) return const [];
    return railDeparturesAt(s, stationIndex, railServiceDay(DateTime.now()), perDirection: perDirection);
  }

  /// Exact official departures from the Worker's per-station timetable (null when offline).
  Future<List<RailDeparture>?> officialDepartures(String line, String station) =>
      _rail.officialDepartures(line == 'MARMARAY' ? 'B1' : line, station, railServiceDay(DateTime.now()));

  /// Every line calling at (or interchanging within [radiusM] of) [station].
  List<({String line, int index, MetroStation station})> linesAtStation(MetroStation station, {double radiusM = 350}) {
    final out = <({String line, int index, MetroStation station})>[];
    final want = railPlainName(station.name);
    _metroStations.forEach((line, list) {
      for (var i = 0; i < list.length; i++) {
        final s = list[i];
        final d = _distanceMeters(station.lat, station.lon, s.lat, s.lon);
        final p = railPlainName(s.name);
        final sameName = p.isNotEmpty && want.isNotEmpty && (p.contains(want) || want.contains(p));
        if (d <= radiusM || (sameName && d <= 900)) {
          out.add((line: line, index: i, station: s));
          break;
        }
      }
    });
    out.sort((a, b) => a.line == station.lineCode ? -1 : (b.line == station.lineCode ? 1 : a.line.compareTo(b.line)));
    return out;
  }

  /// Nearest rail stations to [p] (AR / station search).
  List<({MetroStation station, double distM})> nearestStations(LatLng p, {int limit = 8, double maxM = 3000}) {
    final best = <String, ({MetroStation station, double distM})>{};
    _metroStations.forEach((line, list) {
      for (final s in list) {
        final d = _distanceMeters(p.latitude, p.longitude, s.lat, s.lon);
        if (d > maxM) continue;
        final key = '${railPlainName(s.name)}@${(s.lat * 500).round()},${(s.lon * 500).round()}';
        final cur = best[key];
        if (cur == null || d < cur.distM) best[key] = (station: s, distM: d);
      }
    });
    final list = best.values.toList()..sort((a, b) => a.distM.compareTo(b.distM));
    return list.take(limit).toList();
  }

  /// Nearest bus stops to [p] using the spatial grid.
  List<({BusStop stop, double distM})> nearestBusStops(LatLng p, {int limit = 8, double maxM = 800}) {
    final grid = _apiService.busStopsGrid;
    final out = <({BusStop stop, double distM})>[];
    final latCell = (p.latitude * 50).floor();
    final lonCell = (p.longitude * 50).floor();
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final cell = grid[((latCell + dy) << 16) ^ ((lonCell + dx) & 0xFFFF)];
        if (cell == null) continue;
        for (final s in cell) {
          final d = _distanceMeters(p.latitude, p.longitude, s.lat, s.lon);
          if (d <= maxM) out.add((stop: s, distM: d));
        }
      }
    }
    out.sort((a, b) => a.distM.compareTo(b.distM));
    return out.take(limit).toList();
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
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
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
        }, onError: (_) {}); // Safari reports kCLErrorLocationUnknown as a stream error; keep the last fix
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
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
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

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _clockTimer?.cancel();
    clock.dispose();
    _trainTicker?.cancel();
    _liveFerryTimer?.cancel();
    vehicleTick.dispose();
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

extension on RailTrainState {
  RailTrainState copyWith({double? lat, double? lon, double? bearing}) => RailTrainState(
        id: id,
        line: line,
        dir: dir,
        headsign: headsign,
        prevIndex: prevIndex,
        nextIndex: nextIndex,
        progress: progress,
        state: state,
        speedKmh: speedKmh,
        accel: accel,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        bearing: bearing ?? this.bearing,
        etaSec: etaSec,
        remainingMeters: remainingMeters,
        upcoming: upcoming,
        official: official,
      );
}
