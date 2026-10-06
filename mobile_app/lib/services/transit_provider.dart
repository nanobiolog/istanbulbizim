import 'dart:async';
import 'package:flutter/foundation.dart';
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

  // Selected Line Filter
  String? _selectedLineCode;
  LineRouteDetails? _selectedLineRoute;
  String _selectedDirection = 'ALL'; // 'ALL', 'D', 'G'

  // Selected Bus for Detail Sheet
  BusVehicle? _selectedBus;

  // Metro Overlay
  bool _showMetroLines = true;
  Map<String, List<MetroStation>> _metroStations = {};
  Map<String, String> _metroColors = {};

  // User GPS Location
  LatLng? _userLocation;
  StreamSubscription<Position>? _positionSubscription;

  // Auto-refresh timer
  Timer? _refreshTimer;
  DateTime? _lastUpdated;

  TransitProvider() {
    _init();
  }

  List<BusVehicle> get buses => _buses;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String? get selectedLineCode => _selectedLineCode;
  LineRouteDetails? get selectedLineRoute => _selectedLineRoute;
  String get selectedDirection => _selectedDirection;
  BusVehicle? get selectedBus => _selectedBus;
  bool get showMetroLines => _showMetroLines;
  Map<String, List<MetroStation>> get metroStations => _metroStations;
  Map<String, String> get metroColors => _metroColors;
  LatLng? get userLocation => _userLocation;
  DateTime? get lastUpdated => _lastUpdated;
  int get activeBusCount => _buses.length;

  // Available lines for search/quick-pills
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

    await refreshFleet();

    // Start background sync every 15 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      refreshFleet(silent: true);
    });

    _initLocation();
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
    } catch (e) {
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
      // 1. Fetch line route & stops
      _selectedLineRoute = await _apiService.fetchLineRoute(upper);
      // 2. Fetch buses for this line
      _buses = await _apiService.fetchBusesForLine(upper);
      _lastUpdated = DateTime.now();
    } catch (e) {
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
        notifyListeners();

        _positionSubscription = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
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
        notifyListeners();
        return _userLocation;
      }
    } catch (_) {}
    return null;
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _positionSubscription?.cancel();
    super.dispose();
  }
}
