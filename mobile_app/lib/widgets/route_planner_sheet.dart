import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/route_planner_service.dart';
import '../services/transit_provider.dart';

class RoutePlannerSheet extends StatefulWidget {
  final TransitProvider provider;
  final PlannedPoint? initialOrigin;
  final PlannedPoint? initialDestination;
  final void Function(PlannedItinerary itinerary, PlannedPoint origin, PlannedPoint destination) onSelectItineraryOnMap;
  final void Function(bool isOrigin, PlannedPoint? currentOrigin, PlannedPoint? currentDestination) onPickFromMap;

  const RoutePlannerSheet({
    super.key,
    required this.provider,
    this.initialOrigin,
    this.initialDestination,
    required this.onSelectItineraryOnMap,
    required this.onPickFromMap,
  });

  @override
  State<RoutePlannerSheet> createState() => _RoutePlannerSheetState();
}

class _RoutePlannerSheetState extends State<RoutePlannerSheet> {
  final TextEditingController _originController = TextEditingController();
  final TextEditingController _destController = TextEditingController();
  final FocusNode _originFocus = FocusNode();
  final FocusNode _destFocus = FocusNode();

  PlannedPoint? _origin;
  PlannedPoint? _destination;
  String? _activeSearchField; // 'origin' or 'dest'
  List<PlannedPoint> _suggestions = [];

  RouteTimeMode _timeMode = RouteTimeMode.now;
  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();

  bool _isLoading = false;
  RoutePlanResult? _result;
  int _expandedIndex = 0;
  final Set<String> _expandedLegStops = {};

  @override
  void initState() {
    super.initState();
    _origin = widget.initialOrigin;
    _destination = widget.initialDestination;
    if (_origin != null) _originController.text = _origin!.name;
    if (_destination != null) _destController.text = _destination!.name;

    // Default origin to user GPS location if available and not specified
    if (_origin == null && widget.provider.userLocation != null) {
      final loc = widget.provider.userLocation!;
      _origin = PlannedPoint(
        name: 'Mevcut Konumum',
        lat: loc.latitude,
        lon: loc.longitude,
        subtitle: 'GPS Konumu',
        kind: 'gps',
      );
      _originController.text = _origin!.name;
    }

    _originFocus.addListener(() {
      if (_originFocus.hasFocus) {
        setState(() => _activeSearchField = 'origin');
        _updateSuggestions(_originController.text);
      }
    });
    _destFocus.addListener(() {
      if (_destFocus.hasFocus) {
        setState(() => _activeSearchField = 'dest');
        _updateSuggestions(_destController.text);
      }
    });

    if (_origin != null && _destination != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _calculateRoute());
    }
  }

  @override
  void dispose() {
    _originController.dispose();
    _destController.dispose();
    _originFocus.dispose();
    _destFocus.dispose();
    super.dispose();
  }

  String _fold(String s) {
    return s
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('i̇', 'i')
        .replaceAll('ş', 's')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .trim();
  }

  void _updateSuggestions(String rawQuery) {
    final q = _fold(rawQuery);
    final provider = widget.provider;
    final net = provider.network;
    final items = <PlannedPoint>[];

    if (q.isEmpty || q == _fold('Mevcut Konumum')) {
      // Show popular hubs when query is empty
      const hubs = ['Kadıköy', 'Üsküdar', 'Beşiktaş', 'Yenikapı', 'Taksim', 'Mecidiyeköy', 'Söğütlüçeşme', 'Eminönü'];
      for (final h in hubs) {
        final fh = _fold(h);
        final st = net.stations.values.where((s) => _fold(s.name).contains(fh)).firstOrNull;
        if (st != null) {
          items.add(PlannedPoint(
            name: st.name,
            lat: st.pos.latitude,
            lon: st.pos.longitude,
            subtitle: 'Raylı Sistem · ${st.lines.join(", ")}',
            kind: 'station',
          ));
        }
      }
      for (final p in net.piers.values.take(4)) {
        items.add(PlannedPoint(
          name: '${p.name} İskelesi',
          lat: p.pos.latitude,
          lon: p.pos.longitude,
          subtitle: 'Vapur İskelesi',
          kind: 'pier',
        ));
      }
      setState(() => _suggestions = items.take(10).toList());
      return;
    }

    // 1. Rail stations
    final seenStations = <String>{};
    for (final st in net.stations.values) {
      final fn = _fold(st.name);
      if (fn.contains(q)) {
        final key = '$fn|${st.lines.join(",")}';
        if (seenStations.add(key)) {
          items.add(PlannedPoint(
            name: st.name,
            lat: st.pos.latitude,
            lon: st.pos.longitude,
            subtitle: 'Metro / Raylı · ${st.lines.join(", ")}',
            kind: 'station',
          ));
          if (items.length >= 8) break;
        }
      }
    }

    // 2. Ferry piers
    for (final p in net.piers.values) {
      if (_fold(p.name).contains(q)) {
        items.add(PlannedPoint(
          name: '${p.name} İskelesi',
          lat: p.pos.latitude,
          lon: p.pos.longitude,
          subtitle: 'Vapur İskelesi',
          kind: 'pier',
        ));
        if (items.length >= 13) break;
      }
    }

    // 3. Bus & Metrobüs stops
    final seenBusNames = <String>{};
    for (final s in provider.busStops) {
      final fn = _fold(s.name);
      if (fn.contains(q) || s.code.toLowerCase().contains(q)) {
        if (seenBusNames.add('${fn}_${s.direction}')) {
          items.add(PlannedPoint(
            name: s.name,
            lat: s.lat,
            lon: s.lon,
            subtitle: 'Otobüs Durağı (${s.code})${s.district.isNotEmpty ? " · ${s.district}" : ""}',
            kind: 'bus_stop',
          ));
          if (items.length >= 22) break;
        }
      }
    }

    setState(() => _suggestions = items);
  }

  void _selectSuggestion(PlannedPoint pt) {
    HapticFeedback.selectionClick();
    if (_activeSearchField == 'origin') {
      setState(() {
        _origin = pt;
        _originController.text = pt.name;
        _activeSearchField = null;
      });
      _originFocus.unfocus();
      if (_destination == null) {
        _destFocus.requestFocus();
      } else {
        _calculateRoute();
      }
    } else {
      setState(() {
        _destination = pt;
        _destController.text = pt.name;
        _activeSearchField = null;
      });
      _destFocus.unfocus();
      if (_origin == null) {
        _originFocus.requestFocus();
      } else {
        _calculateRoute();
      }
    }
  }

  Future<void> _useCurrentLocation(bool forOrigin) async {
    HapticFeedback.lightImpact();
    final loc = widget.provider.userLocation ?? await widget.provider.locateUser();
    if (!mounted) return;
    if (loc == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Konum alınamadı. Lütfen konum iznini kontrol edin.')),
      );
      return;
    }
    final pt = PlannedPoint(
      name: 'Mevcut Konumum',
      lat: loc.latitude,
      lon: loc.longitude,
      subtitle: 'GPS Konumu',
      kind: 'gps',
    );
    setState(() {
      if (forOrigin) {
        _origin = pt;
        _originController.text = pt.name;
      } else {
        _destination = pt;
        _destController.text = pt.name;
      }
      _activeSearchField = null;
    });
    _originFocus.unfocus();
    _destFocus.unfocus();
    if (_origin != null && _destination != null) {
      _calculateRoute();
    }
  }

  void _swapPoints() {
    HapticFeedback.lightImpact();
    setState(() {
      final tmp = _origin;
      _origin = _destination;
      _destination = tmp;
      _originController.text = _origin?.name ?? '';
      _destController.text = _destination?.name ?? '';
      _activeSearchField = null;
    });
    if (_origin != null && _destination != null) {
      _calculateRoute();
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF0EA5E9),
            onPrimary: Colors.white,
            surface: Color(0xFF161B26),
            onSurface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
        if (_timeMode == RouteTimeMode.now) {
          _timeMode = RouteTimeMode.departAt;
        }
      });
      if (_origin != null && _destination != null) _calculateRoute();
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF0EA5E9),
            onPrimary: Colors.white,
            surface: Color(0xFF161B26),
            onSurface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _selectedTime = picked;
        if (_timeMode == RouteTimeMode.now) {
          _timeMode = RouteTimeMode.departAt;
        }
      });
      if (_origin != null && _destination != null) _calculateRoute();
    }
  }

  void _applyTimePreset(String preset) {
    HapticFeedback.selectionClick();
    final now = DateTime.now();
    setState(() {
      if (preset == 'now') {
        _timeMode = RouteTimeMode.now;
        _selectedDate = now;
        _selectedTime = TimeOfDay.fromDateTime(now);
      } else if (preset == '+30') {
        final t = now.add(const Duration(minutes: 30));
        _timeMode = RouteTimeMode.departAt;
        _selectedDate = t;
        _selectedTime = TimeOfDay.fromDateTime(t);
      } else if (preset == '+60') {
        final t = now.add(const Duration(minutes: 60));
        _timeMode = RouteTimeMode.departAt;
        _selectedDate = t;
        _selectedTime = TimeOfDay.fromDateTime(t);
      } else if (preset == 'tom08') {
        final t = now.add(const Duration(days: 1));
        _timeMode = RouteTimeMode.departAt;
        _selectedDate = DateTime(t.year, t.month, t.day, 8, 0);
        _selectedTime = const TimeOfDay(hour: 8, minute: 0);
      }
    });
    if (_origin != null && _destination != null) _calculateRoute();
  }

  Future<void> _calculateRoute() async {
    if (_origin == null || _destination == null) return;
    _originFocus.unfocus();
    _destFocus.unfocus();
    setState(() {
      _activeSearchField = null;
      _isLoading = true;
      _expandedIndex = 0;
      _expandedLegStops.clear();
    });

    final res = await RoutePlannerService.planRoute(
      provider: widget.provider,
      from: _origin!,
      to: _destination!,
      timeMode: _timeMode,
      selectedDate: _selectedDate,
      selectedTime: _selectedTime,
    );

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _result = res;
    });
  }

  String _formatDateShort(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(d.year, d.month, d.day);
    final diff = target.difference(today).inDays;
    const months = ['Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz', 'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara'];
    const days = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];
    final dayName = days[d.weekday - 1];
    if (diff == 0) return 'Bugün ($dayName)';
    if (diff == 1) return 'Yarın ($dayName)';
    return '${d.day} ${months[d.month - 1]} $dayName';
  }

  String _scheduleDayBadge(DateTime d) {
    if (d.weekday == 7) return 'Pazar Tarifesi';
    if (d.weekday == 6) return 'Cumartesi Tarifesi';
    return 'İş Günü Tarifesi';
  }

  String _formatTimeOfDay(TimeOfDay t) {
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.88;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        color: const Color(0xFF0F141D),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: const [
          BoxShadow(color: Color(0x99000000), blurRadius: 30, offset: Offset(0, -6)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag Handle & Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
              child: Column(
                children: [
                  Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF0EA5E9), Color(0xFF2563EB)],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.alt_route_rounded, color: Colors.white, size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Akıllı Rota ve Aktarma Planlayıcı',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                            Text(
                              'Otobüs · Metro · Marmaray · Metrobüs · Vapur',
                              style: TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Origin & Destination Inputs Card
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: _buildEndpointsCard(),
            ),

            // Time Mode + Date/Time Selector
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: _buildDateTimeBar(),
            ),

            // Content Area: Either Autocomplete Suggestions OR Route Results
            Flexible(
              child: _activeSearchField != null
                  ? _buildSuggestionsList()
                  : _buildResultsSection(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEndpointsCard() {
    final isOriginFocused = _activeSearchField == 'origin';
    final isDestFocused = _activeSearchField == 'dest';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF171E2B),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          // Left timeline dots
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
              Container(
                width: 2,
                height: 28,
                margin: const EdgeInsets.symmetric(vertical: 3),
                color: Colors.white.withValues(alpha: 0.16),
              ),
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: const Color(0xFFF43F5E),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ],
          ),
          const SizedBox(width: 10),

          // Fields
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Origin Input
                Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: isOriginFocused ? const Color(0xFF1E293B) : const Color(0xFF0F141D),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isOriginFocused ? const Color(0xFF0EA5E9) : Colors.white.withValues(alpha: 0.07),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _originController,
                          focusNode: _originFocus,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                          decoration: const InputDecoration(
                            hintText: 'Kalkış durağı, istasyon veya iskele...',
                            hintStyle: TextStyle(color: Color(0xFF64748B), fontSize: 12.5, fontWeight: FontWeight.w500),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onChanged: _updateSuggestions,
                        ),
                      ),
                      if (_originController.text.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _origin = null;
                              _originController.clear();
                              _activeSearchField = 'origin';
                            });
                            _originFocus.requestFocus();
                            _updateSuggestions('');
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4),
                            child: Icon(Icons.clear_rounded, color: Colors.white54, size: 16),
                          ),
                        ),
                      GestureDetector(
                        onTap: () => _useCurrentLocation(true),
                        child: const Tooltip(
                          message: 'Mevcut Konumum',
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4),
                            child: Icon(Icons.my_location_rounded, color: Color(0xFF38BDF8), size: 16),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          Navigator.of(context).pop();
                          widget.onPickFromMap(true, _origin, _destination);
                        },
                        child: const Tooltip(
                          message: 'Haritadan Seç',
                          child: Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.push_pin_rounded, color: Color(0xFF10B981), size: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // Destination Input
                Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: isDestFocused ? const Color(0xFF1E293B) : const Color(0xFF0F141D),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDestFocused ? const Color(0xFF0EA5E9) : Colors.white.withValues(alpha: 0.07),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _destController,
                          focusNode: _destFocus,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                          decoration: const InputDecoration(
                            hintText: 'Varış durağı, istasyon veya iskele...',
                            hintStyle: TextStyle(color: Color(0xFF64748B), fontSize: 12.5, fontWeight: FontWeight.w500),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onChanged: _updateSuggestions,
                        ),
                      ),
                      if (_destController.text.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _destination = null;
                              _destController.clear();
                              _activeSearchField = 'dest';
                            });
                            _destFocus.requestFocus();
                            _updateSuggestions('');
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4),
                            child: Icon(Icons.clear_rounded, color: Colors.white54, size: 16),
                          ),
                        ),
                      GestureDetector(
                        onTap: () {
                          Navigator.of(context).pop();
                          widget.onPickFromMap(false, _origin, _destination);
                        },
                        child: const Tooltip(
                          message: 'Haritadan Seç',
                          child: Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.push_pin_rounded, color: Color(0xFFF43F5E), size: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),

          // Swap Button
          IconButton(
            onPressed: _swapPoints,
            icon: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: const Icon(Icons.swap_vert_rounded, color: Colors.white, size: 19),
            ),
            visualDensity: VisualDensity.compact,
            tooltip: 'Kalkış ve Varışı Değiştir',
          ),
        ],
      ),
    );
  }

  Widget _buildDateTimeBar() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF171E2B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Mode Segmented Row: Şimdi | Kalkış Zamanı | Varış Zamanı
          Row(
            children: [
              for (final mode in RouteTimeMode.values) ...[
                if (mode != RouteTimeMode.now) const SizedBox(width: 6),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() {
                        _timeMode = mode;
                        if (mode == RouteTimeMode.now) {
                          final now = DateTime.now();
                          _selectedDate = now;
                          _selectedTime = TimeOfDay.fromDateTime(now);
                        }
                      });
                      if (_origin != null && _destination != null) _calculateRoute();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      decoration: BoxDecoration(
                        color: _timeMode == mode ? const Color(0xFF0EA5E9) : const Color(0xFF0F141D),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: _timeMode == mode
                              ? const Color(0xFF38BDF8)
                              : Colors.white.withValues(alpha: 0.07),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        mode == RouteTimeMode.now
                            ? '⏱ Şimdi'
                            : (mode == RouteTimeMode.departAt ? '🛫 Kalkış Saati' : '🏁 Varış Saati'),
                        style: TextStyle(
                          color: _timeMode == mode ? Colors.white : const Color(0xFF94A3B8),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: 8),

          // Date & Time Picker Buttons + Schedule Day Badge
          Row(
            children: [
              // Date Button
              Expanded(
                flex: 3,
                child: GestureDetector(
                  onTap: _pickDate,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F141D),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today_rounded, color: Color(0xFF38BDF8), size: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _formatDateShort(_selectedDate),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),

              // Time Button
              Expanded(
                flex: 2,
                child: GestureDetector(
                  onTap: _pickTime,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F141D),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.access_time_filled_rounded, color: Color(0xFF38BDF8), size: 14),
                        const SizedBox(width: 5),
                        Text(
                          _timeMode == RouteTimeMode.now
                              ? _formatTimeOfDay(TimeOfDay.now())
                              : _formatTimeOfDay(_selectedTime),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),

              // Search / Recalculate Button
              ElevatedButton(
                onPressed: (_origin != null && _destination != null && !_isLoading) ? _calculateRoute : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0EA5E9),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.white12,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(0, 34),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                  elevation: 0,
                ),
                child: const Text(
                  'Hesapla',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          // Quick time chips & Active Day Type badge
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0EA5E9).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _scheduleDayBadge(_selectedDate),
                    style: const TextStyle(
                      color: Color(0xFF38BDF8),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _quickPresetChip('Şimdi', () => _applyTimePreset('now')),
                const SizedBox(width: 5),
                _quickPresetChip('+30 dk', () => _applyTimePreset('+30')),
                const SizedBox(width: 5),
                _quickPresetChip('+1 saat', () => _applyTimePreset('+60')),
                const SizedBox(width: 5),
                _quickPresetChip('Yarın 08:00', () => _applyTimePreset('tom08')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickPresetChip(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 10.5, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _buildSuggestionsList() {
    final isOrigin = _activeSearchField == 'origin';
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 16),
      children: [
        // Quick GPS & Map Pick buttons
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () => _useCurrentLocation(isOrigin),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0EA5E9).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF0EA5E9).withValues(alpha: 0.35)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.my_location_rounded, color: Color(0xFF38BDF8), size: 15),
                      SizedBox(width: 6),
                      Text(
                        'Mevcut Konumum',
                        style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12, fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onPickFromMap(isOrigin, _origin, _destination);
                },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.map_rounded, color: Colors.white, size: 15),
                      SizedBox(width: 6),
                      Text(
                        'Haritadan Dokunarak Seç',
                        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final s in _suggestions)
          InkWell(
            onTap: () => _selectSuggestion(s),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: s.kind == 'station'
                          ? const Color(0xFF8B5CF6).withValues(alpha: 0.2)
                          : (s.kind == 'pier'
                              ? const Color(0xFF0284C7).withValues(alpha: 0.2)
                              : const Color(0xFF10B981).withValues(alpha: 0.2)),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      s.kind == 'station'
                          ? Icons.train_rounded
                          : (s.kind == 'pier' ? Icons.directions_boat_filled_rounded : Icons.directions_bus_rounded),
                      color: s.kind == 'station'
                          ? const Color(0xFFC4B5FD)
                          : (s.kind == 'pier' ? const Color(0xFF38BDF8) : const Color(0xFF34D399)),
                      size: 17,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w700),
                        ),
                        if (s.subtitle.isNotEmpty)
                          Text(
                            s.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w500),
                          ),
                      ],
                    ),
                  ),
                  const Icon(Icons.north_west_rounded, color: Colors.white38, size: 15),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildResultsSection() {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 36),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.6, color: Color(0xFF38BDF8)),
              ),
              SizedBox(height: 12),
              Text(
                'Otobüs, Metro, Marmaray ve Vapur aktarmaları hesaplanıyor...',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }

    if (_result == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions_transit_filled_rounded, color: Colors.white.withValues(alpha: 0.18), size: 40),
            const SizedBox(height: 8),
            const Text(
              'Kalkış ve varış noktasını seçin, istediğiniz tarih ve saat için en hızlı otobüs, metro, Marmaray, metrobüs ve vapur rotalarını adım adım görün.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      );
    }

    if (!_result!.ok || _result!.itineraries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF7F1D1D).withValues(alpha: 0.28),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.4)),
          ),
          child: Text(
            _result!.error ?? 'Uygun rota bulunamadı.',
            style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ),
      );
    }

    final its = _result!.itineraries;
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
      itemCount: its.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, idx) => _buildItineraryCard(its[idx], idx),
    );
  }

  Widget _buildItineraryCard(PlannedItinerary it, int idx) {
    final isExpanded = _expandedIndex == idx;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: isExpanded ? const Color(0xFF192231) : const Color(0xFF151C28),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isExpanded ? const Color(0xFF0EA5E9) : Colors.white.withValues(alpha: 0.08),
          width: isExpanded ? 1.4 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Summary Header (Always visible)
          InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _expandedIndex = isExpanded ? -1 : idx);
            },
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Total Duration
                      Text(
                        '${it.totalMinutes} dk',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Clock Range (Dep -> Arr)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${it.depTime} ➔ ${it.arrTime}',
                          style: const TextStyle(
                            color: Color(0xFFE2E8F0),
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Tag Badge (En Hızlı, Aktarmasız, Deniz Yolu, etc.)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0EA5E9).withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          it.tag,
                          style: const TextStyle(
                            color: Color(0xFF38BDF8),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                        color: Colors.white54,
                        size: 20,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Visual Chain of Modes
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (var i = 0; i < it.legs.length; i++) ...[
                        if (i > 0)
                          const Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 15),
                        _buildLegPill(it.legs[i]),
                      ],
                    ],
                  ),

                  const SizedBox(height: 6),
                  Text(
                    '${it.transfers == 0 ? "Aktarmasız" : "${it.transfers} aktarma"} · Toplam ${it.walkMinutes} dk yürüyüş',
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Expanded Step-by-Step Vertical Timeline + "Haritada Göster" Button
          if (isExpanded) ...[
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < it.legs.length; i++)
                    _buildLegTimelineStep(it.legs[i], '${it.id}_$i', i == it.legs.length - 1),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      if (_origin != null && _destination != null) {
                        widget.onSelectItineraryOnMap(it, _origin!, _destination!);
                      }
                    },
                    icon: const Icon(Icons.map_rounded, size: 17, color: Colors.white),
                    label: const Text(
                      'Rotayı Haritada Göster',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0EA5E9),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLegPill(PlannedRouteLeg leg) {
    if (leg.type == 'walk') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.directions_walk_rounded, color: Color(0xFF94A3B8), size: 12),
            const SizedBox(width: 3),
            Text(
              '${leg.durationMin} dk',
              style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      );
    }

    final c = leg.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: c.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(leg.icon, color: Colors.white, size: 12),
          const SizedBox(width: 4),
          Text(
            leg.lineCode.isNotEmpty ? leg.lineCode : leg.lineName,
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }

  Widget _buildLegTimelineStep(PlannedRouteLeg leg, String legKey, bool isLast) {
    final isWalk = leg.type == 'walk';
    final color = isWalk ? const Color(0xFF64748B) : leg.color;
    final showStops = _expandedLegStops.contains(legKey);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left Column: Exact Departure & Arrival Clock Times
          SizedBox(
            width: 44,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  leg.depTime,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const Spacer(),
                if (isLast)
                  Text(
                    leg.arrTime,
                    style: const TextStyle(
                      color: Color(0xFF38BDF8),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Center Column: Colored Bar & Node Dots
          Column(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
              Expanded(
                child: Container(
                  width: isWalk ? 2 : 3.5,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    color: isWalk ? Colors.white24 : color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              if (isLast)
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF43F5E),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 10),

          // Right Column: Step Details
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 4 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Boarding Stop / Station / Pier Name
                  Text(
                    leg.fromName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 5),

                  if (isWalk)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.directions_walk_rounded, color: Color(0xFF94A3B8), size: 15),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${leg.toName} noktasına yürüyüş (${leg.durationMin} dk${leg.distanceM > 0 ? " · ${leg.distanceM} m" : ""})',
                              style: const TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: color.withValues(alpha: 0.35)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                                decoration: BoxDecoration(
                                  color: color,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(leg.icon, color: Colors.white, size: 12),
                                    const SizedBox(width: 4),
                                    Text(
                                      leg.lineCode.isNotEmpty ? leg.lineCode : leg.modeLabel,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  leg.lineName.isNotEmpty ? leg.lineName : leg.modeLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              Text(
                                '${leg.durationMin} dk',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          if (leg.direction.isNotEmpty || leg.scheduleNote.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              [
                                if (leg.direction.isNotEmpty) '➔ ${leg.direction}',
                                if (leg.scheduleNote.isNotEmpty) leg.scheduleNote,
                              ].join(' · '),
                              style: const TextStyle(
                                color: Color(0xFFCBD5E1),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (leg.liveBus != null) ...[
                            const SizedBox(height: 5),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF34D399),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    'Canlı Araç ${leg.liveBus!.door} · Durağa ~${leg.liveBus!.etaMin} dk (${leg.liveBus!.speed} km/s)',
                                    style: const TextStyle(
                                      color: Color(0xFF6EE7B7),
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 5),
                          Row(
                            children: [
                              Text(
                                'İniş: ${leg.toName} (${leg.arrTime})',
                                style: const TextStyle(
                                  color: Color(0xFFE2E8F0),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
                              if (leg.stops.length > 2)
                                GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      if (showStops) {
                                        _expandedLegStops.remove(legKey);
                                      } else {
                                        _expandedLegStops.add(legKey);
                                      }
                                    });
                                  },
                                  child: Text(
                                    showStops ? 'Durakları Gizle ▲' : '${leg.stopsCount} durak ▼',
                                    style: const TextStyle(
                                      color: Color(0xFF38BDF8),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (showStops && leg.stops.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final st in leg.stops)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 2),
                                      child: Row(
                                        children: [
                                          Text(
                                            st.time,
                                            style: const TextStyle(
                                              color: Color(0xFF94A3B8),
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w700,
                                              fontFeatures: [FontFeature.tabularFigures()],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              st.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                  if (isLast) ...[
                    const SizedBox(height: 8),
                    Text(
                      leg.toName,
                      style: const TextStyle(
                        color: Color(0xFF38BDF8),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
