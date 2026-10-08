import 'package:flutter/material.dart';
import '../models/transit_models.dart';
import '../theme/app_theme.dart';

class MinimalBottomNavCard extends StatefulWidget {
  final BusVehicle? selectedBus;
  final String? activeLine;
  final LineRouteDetails? routeDetails;
  final int visibleBusCount;
  final int totalBusCount;
  final String selectedDirection;
  final DateTime? lastUpdated;
  final bool isNightMode;
  final LineTimetable? timetable;
  final bool isLoadingTimetable;
  final Function(String) onDirectionChanged;
  final VoidCallback onClearSelection;
  final VoidCallback onSearchTap;

  const MinimalBottomNavCard({
    super.key,
    this.selectedBus,
    this.activeLine,
    this.routeDetails,
    required this.visibleBusCount,
    required this.totalBusCount,
    required this.selectedDirection,
    this.lastUpdated,
    this.isNightMode = true,
    this.timetable,
    this.isLoadingTimetable = false,
    required this.onDirectionChanged,
    required this.onClearSelection,
    required this.onSearchTap,
  });

  @override
  State<MinimalBottomNavCard> createState() => _MinimalBottomNavCardState();
}

class _MinimalBottomNavCardState extends State<MinimalBottomNavCard> {
  bool get isNightMode => widget.isNightMode;
  BusVehicle? get selectedBus => widget.selectedBus;
  String? get activeLine => widget.activeLine;
  LineRouteDetails? get routeDetails => widget.routeDetails;
  int get visibleBusCount => widget.visibleBusCount;
  int get totalBusCount => widget.totalBusCount;
  String get selectedDirection => widget.selectedDirection;
  DateTime? get lastUpdated => widget.lastUpdated;
  LineTimetable? get timetable => widget.timetable;
  bool get isLoadingTimetable => widget.isLoadingTimetable;
  void Function(String) get onDirectionChanged => widget.onDirectionChanged;
  VoidCallback get onClearSelection => widget.onClearSelection;
  VoidCallback get onSearchTap => widget.onSearchTap;

  bool _showTimetable = false; // Collapsed by default so screen UI is clean
  String _selectedDayType = 'I'; // 'I': İş Günü, 'C': Cumartesi, 'P': Pazar
  String _timetableDirection = 'D'; // 'D' or 'G'

  @override
  void initState() {
    super.initState();
    _initDayType();
    _timetableDirection = widget.selectedDirection == 'G' ? 'G' : 'D';
  }

  @override
  void didUpdateWidget(MinimalBottomNavCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeLine != widget.activeLine || oldWidget.selectedBus?.id != widget.selectedBus?.id) {
      _showTimetable = false; // Reset collapsed on line or vehicle change
    }
    if (widget.selectedDirection != 'ALL' && widget.selectedDirection != _timetableDirection) {
      _timetableDirection = widget.selectedDirection;
    }
  }

  void _initDayType() {
    final weekday = DateTime.now().weekday; // 1: Mon ... 6: Sat, 7: Sun
    if (weekday == DateTime.saturday) {
      _selectedDayType = 'C';
    } else if (weekday == DateTime.sunday) {
      _selectedDayType = 'P';
    } else {
      _selectedDayType = 'I';
    }
  }

  String _formatLastUpdated() {
    if (widget.lastUpdated == null) return 'Canlı';
    final now = DateTime.now();
    final diff = now.difference(widget.lastUpdated!);
    if (diff.inSeconds < 10) return 'Az önce';
    if (diff.inSeconds < 60) return '${diff.inSeconds} sn önce';
    return '${widget.lastUpdated!.hour.toString().padLeft(2, '0')}:${widget.lastUpdated!.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isNightMode = widget.isNightMode;
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * (_showTimetable ? 0.75 : 0.45),
      ),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 22),
      decoration: BoxDecoration(
        color: isNightMode ? const Color(0xFF0D1117) : AppTheme.surface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(32),
          topRight: Radius.circular(32),
        ),
        border: Border.all(
          color: isNightMode ? Colors.white.withValues(alpha: 0.12) : AppTheme.borderLight,
          width: 1.2,
        ),
        boxShadow: AppTheme.sheetShadow,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag Handle Bar
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: isNightMode
                      ? Colors.white.withValues(alpha: 0.25)
                      : AppTheme.borderMedium,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),

            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: widget.selectedBus != null
                    ? _buildSelectedBusView(context)
                    : widget.activeLine != null
                        ? _buildActiveLineView(context)
                        : _buildDefaultStatusView(context),
              ),
            ),
          ],
        ),
      ),
    );
  }


  // 1. Bus Vehicle Detailed View with rich telemetry, heading, operator & speed
  Widget _buildSelectedBusView(BuildContext context) {
    final bus = selectedBus!;
    final speed = bus.speed;
    final speedStatus = speed <= 3
        ? 'Durakta / Bekliyor'
        : (speed < 15 ? 'Yoğun Trafik / Yavaş' : (speed < 45 ? 'Normal Seyir' : 'Seri / Hızlı'));
    final speedColor = bus.speedColor;

    // Direction name resolution
    String dirText = bus.directionName.isNotEmpty
        ? bus.directionName
        : (bus.direction == 'D' ? 'Dönüş İstikameti' : (bus.direction == 'G' ? 'Gidiş İstikameti' : ''));

    final updateTime = _formatLastUpdated();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Top Row: Line badge, Vehicle Door No, Close
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                // Line Code Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: isNightMode ? Colors.white : AppTheme.accentBlack,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                  child: Text(
                    bus.line.isNotEmpty ? bus.line : 'İETT',
                    style: TextStyle(
                      color: isNightMode ? AppTheme.surfaceDark : Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Kapı: ${bus.id}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: isNightMode ? Colors.white : AppTheme.textPrimary,
                          ),
                        ),
                        if (bus.plate.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isNightMode
                                  ? Colors.white.withValues(alpha: 0.10)
                                  : AppTheme.background,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isNightMode
                                    ? Colors.white.withValues(alpha: 0.15)
                                    : AppTheme.borderMedium,
                              ),
                            ),
                            child: Text(
                              bus.plate,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: isNightMode ? Colors.white70 : AppTheme.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      bus.operator.isNotEmpty ? bus.operator : 'İETT İstanbul Otobüs Filosu',
                      style: TextStyle(
                        fontSize: 11,
                        color: isNightMode ? Colors.white54 : AppTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            GestureDetector(
              onTap: onClearSelection,
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: isNightMode
                      ? Colors.white.withValues(alpha: 0.10)
                      : AppTheme.background,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: isNightMode ? Colors.white70 : AppTheme.textSecondary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // 1. Destination / Where it's going Card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: isNightMode
                ? Colors.white.withValues(alpha: 0.05)
                : AppTheme.lightGray,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isNightMode
                  ? Colors.white.withValues(alpha: 0.08)
                  : AppTheme.borderLight,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: (bus.direction == 'D' ? AppTheme.directionCyan : AppTheme.directionPurple)
                      .withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  bus.direction == 'D'
                      ? Icons.arrow_forward_rounded
                      : Icons.arrow_back_rounded,
                  color: bus.direction == 'D'
                      ? AppTheme.directionCyan
                      : AppTheme.directionPurple,
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GİTTİĞİ YÖN / HEDEF',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: bus.direction == 'D'
                            ? AppTheme.directionCyan
                            : AppTheme.directionPurple,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      bus.destination.isNotEmpty
                          ? bus.destination
                          : (bus.headsign.isNotEmpty
                              ? bus.headsign
                              : (dirText.isNotEmpty ? dirText : 'Güzergah Boyunca')),
                      style: TextStyle(
                        color: isNightMode ? Colors.white : AppTheme.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (bus.bearing != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: isNightMode
                        ? Colors.white.withValues(alpha: 0.10)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.rotate(
                        angle: (bus.bearing! * 3.141592653589793 / 180),
                        child: const Icon(
                          Icons.navigation_rounded,
                          size: 11,
                          color: Color(0xFF0284C7),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${bus.bearing!.toInt()}°',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: isNightMode ? Colors.white70 : AppTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // 2. Next Stop & Live Arrival ETA Card
        if (bus.nextStop.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isNightMode
                    ? [
                        const Color(0xFF1E293B).withValues(alpha: 0.7),
                        const Color(0xFF0F172A).withValues(alpha: 0.8),
                      ]
                    : [
                        const Color(0xFFEFF6FF),
                        const Color(0xFFF8FAFC),
                      ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isNightMode
                    ? const Color(0xFF38BDF8).withValues(alpha: 0.25)
                    : const Color(0xFF93C5FD),
                width: 1.2,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.pin_drop_rounded,
                    color: Color(0xFF0284C7),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'SIRADAKİ DURAK',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              color: Color(0xFF0284C7),
                            ),
                          ),
                          if (bus.nextStopDistM != null && bus.nextStopDistM! > 0) ...[
                            const SizedBox(width: 6),
                            Text(
                              bus.nextStopDistM! >= 1000
                                  ? '• ${(bus.nextStopDistM! / 1000).toStringAsFixed(1)} km'
                                  : '• ${bus.nextStopDistM!} m',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: isNightMode ? Colors.white60 : AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        bus.nextStop,
                        style: TextStyle(
                          color: isNightMode ? Colors.white : AppTheme.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // ETA Badge
                Builder(
                  builder: (_) {
                    final eta = bus.nextStopEtaSec ?? 999;
                    final isImminent = eta <= 60;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: isImminent
                            ? const Color(0xFF10B981).withValues(alpha: 0.2)
                            : (isNightMode
                                ? const Color(0xFF0284C7).withValues(alpha: 0.25)
                                : const Color(0xFFDBEAFE)),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isImminent
                              ? const Color(0xFF10B981).withValues(alpha: 0.4)
                              : const Color(0xFF38BDF8).withValues(alpha: 0.4),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'TAHMİN',
                            style: TextStyle(
                              fontSize: 8.5,
                              fontWeight: FontWeight.w800,
                              color: isImminent
                                  ? const Color(0xFF10B981)
                                  : const Color(0xFF0284C7),
                              letterSpacing: 0.5,
                            ),
                          ),
                          Text(
                            bus.nextStopEtaText,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w900,
                              color: isImminent
                                  ? const Color(0xFF10B981)
                                  : (isNightMode ? Colors.white : const Color(0xFF0369A1)),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],

        // Metric Tiles: Speed, GPS Time, Signal Freshness
        Row(
          children: [
            // Speed indicator badge
            Expanded(
              flex: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: isNightMode
                      ? Colors.white.withValues(alpha: 0.08)
                      : AppTheme.accentBlack,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isNightMode ? Colors.white12 : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: speedColor.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.speed_rounded,
                        color: speedColor,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                '${speed.toInt()}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(width: 3),
                              const Text(
                                'km/s',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            speedStatus,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.75),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Time / Freshness badge
            Expanded(
              flex: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: isNightMode
                      ? Colors.white.withValues(alpha: 0.05)
                      : AppTheme.background,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isNightMode ? Colors.white12 : AppTheme.borderMedium,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: (isNightMode ? Colors.white : AppTheme.accentBlack)
                            .withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.schedule_rounded,
                        color: isNightMode ? Colors.white70 : AppTheme.accentBlack,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            bus.time.isNotEmpty ? bus.time : updateTime,
                            style: TextStyle(
                              color: isNightMode ? Colors.white : AppTheme.textPrimary,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          Row(
                            children: [
                              Container(
                                width: 5,
                                height: 5,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF10B981),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                bus.ageSeconds > 0 ? '${bus.ageSeconds} sn önce' : 'Canlı Sinyal',
                                style: TextStyle(
                                  color: isNightMode ? Colors.white54 : AppTheme.textSecondary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),

        // Expandable Timetable / Sefer Saatleri & Kalkış Tablosu Trigger
        if (bus.line.isNotEmpty) ...[
          const SizedBox(height: 10),
          _buildTimetableExpandButton(bus.line),
          if (_showTimetable) ...[
            const SizedBox(height: 10),
            _buildTimetableSection(bus.line),
          ],
        ],
      ],
    );
  }


  // 2. Active Line View (with Direction D / G toggle and route destinations)
  Widget _buildActiveLineView(BuildContext context) {
    final dRoute = routeDetails?.directions['D'];
    final gRoute = routeDetails?.directions['G'];
    final updateTime = _formatLastUpdated();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Hat $activeLine',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: isNightMode ? Colors.white : AppTheme.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: isNightMode
                            ? Colors.white.withValues(alpha: 0.12)
                            : AppTheme.background,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isNightMode ? Colors.white24 : AppTheme.borderMedium,
                        ),
                      ),
                      child: Text(
                        '$visibleBusCount Araç',
                        style: TextStyle(
                          color: isNightMode ? Colors.white : AppTheme.textPrimary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      Icons.update_rounded,
                      size: 11,
                      color: isNightMode ? Colors.white54 : AppTheme.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Son Güncelleme: $updateTime',
                      style: TextStyle(
                        color: isNightMode ? Colors.white54 : AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            GestureDetector(
              onTap: onClearSelection,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isNightMode
                      ? Colors.white.withValues(alpha: 0.12)
                      : AppTheme.accentBlack,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isNightMode ? Colors.white24 : Colors.transparent,
                  ),
                ),
                child: Text(
                  'Filtreyi Temizle',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Direction Selection Tabs (High Contrast Black & White / Vibrant Direction Accents)
        Row(
          children: [
            Expanded(
              child: _buildDirectionButton(
                label: dRoute?.destination ?? 'Dönüş Yönü',
                code: 'D',
                accentColor: AppTheme.directionCyan,
                isSelected: widget.selectedDirection == 'D',
                arrowIcon: Icons.arrow_forward_rounded,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildDirectionButton(
                label: gRoute?.destination ?? 'Gidiş Yönü',
                code: 'G',
                accentColor: AppTheme.directionPurple,
                isSelected: widget.selectedDirection == 'G',
                arrowIcon: Icons.arrow_back_rounded,
              ),
            ),
            const SizedBox(width: 8),
            _buildDirectionButton(
              label: 'Tümü',
              code: 'ALL',
              accentColor: const Color(0xFF0284C7),
              isSelected: widget.selectedDirection == 'ALL',
              compact: true,
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Expandable Timetable / Sefer Saatleri & Kalkış Tablosu Trigger
        _buildTimetableExpandButton(widget.activeLine ?? ''),

        if (_showTimetable) ...[
          const SizedBox(height: 10),
          _buildTimetableSection(widget.activeLine ?? ''),
        ],
      ],
    );
  }

  Widget _buildTimetableExpandButton(String lineCode) {
    final isNight = widget.isNightMode;
    final isMetro = lineCode.startsWith('M') || lineCode.startsWith('T') || lineCode.startsWith('F');

    return GestureDetector(
      onTap: () {
        setState(() {
          _showTimetable = !_showTimetable;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _showTimetable
              ? (isNight ? Colors.white.withValues(alpha: 0.12) : AppTheme.accentBlack)
              : (isNight ? Colors.white.withValues(alpha: 0.06) : AppTheme.lightGray),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _showTimetable
                ? (isNight ? Colors.white30 : AppTheme.accentBlack)
                : (isNight ? Colors.white12 : AppTheme.borderMedium),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: (isMetro ? const Color(0xFF0284C7) : const Color(0xFF10B981))
                    .withValues(alpha: _showTimetable ? 0.3 : 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isMetro ? Icons.subway_rounded : Icons.schedule_rounded,
                size: 16,
                color: isMetro ? const Color(0xFF38BDF8) : const Color(0xFF10B981),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        isMetro ? 'Metro Sefer Saatleri & Aralıkları' : 'İETT Kalkış & Sefer Saatleri',
                        style: TextStyle(
                          color: _showTimetable
                              ? (isNight ? Colors.white : Colors.white)
                              : (isNight ? Colors.white : AppTheme.textPrimary),
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: isMetro
                              ? const Color(0xFF0284C7).withValues(alpha: 0.25)
                              : const Color(0xFF10B981).withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          isMetro ? 'METRO' : 'İBB PORTAL',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: isMetro ? const Color(0xFF38BDF8) : const Color(0xFF10B981),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    _showTimetable ? 'Tabloyu gizlemek için dokunun' : 'Kalkış saatlerini ve sefer sıklığını göster',
                    style: TextStyle(
                      color: _showTimetable
                          ? (isNight ? Colors.white70 : Colors.white70)
                          : (isNight ? Colors.white60 : AppTheme.textSecondary),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              _showTimetable ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
              color: _showTimetable
                  ? (isNight ? Colors.white : Colors.white)
                  : (isNight ? Colors.white70 : AppTheme.textSecondary),
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimetableSection(String lineCode) {
    final isNight = widget.isNightMode;
    final timetable = widget.timetable;
    final isLoading = widget.isLoadingTimetable;

    if (isLoading) {
      return Container(
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(width: 12),
            Text(
              'İBB Sefer Saatleri Alınıyor...',
              style: TextStyle(
                color: isNight ? Colors.white70 : AppTheme.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    if (timetable == null || timetable.entries.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isNight ? Colors.white.withValues(alpha: 0.04) : AppTheme.lightGray,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline_rounded, size: 18, color: Color(0xFFF59E0B)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Bu hat için İBB veri portalında kayıtlı planlanan kalkış tablosu bulunamadı veya canlı filo seyir modunda çalışıyor.',
                style: TextStyle(
                  color: isNight ? Colors.white70 : AppTheme.textSecondary,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Filter by selected Day Type and Direction
    final dayFiltered = timetable.entries.where((e) => e.dayType == _selectedDayType).toList();
    final dirFiltered = dayFiltered.where((e) => e.direction == _timetableDirection).toList();
    final entries = dirFiltered.isNotEmpty ? dirFiltered : dayFiltered;

    final now = DateTime.now();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Day Type Filters (İş Günü | Cumartesi | Pazar)
        Row(
          children: [
            _buildDayTypePill('I', 'İş Günü'),
            const SizedBox(width: 6),
            _buildDayTypePill('C', 'Cumartesi'),
            const SizedBox(width: 6),
            _buildDayTypePill('P', 'Pazar'),
            const Spacer(),
            // Direction toggle for timetable (D / G)
            Row(
              children: [
                GestureDetector(
                  onTap: () => setState(() => _timetableDirection = 'D'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _timetableDirection == 'D' ? AppTheme.directionCyan : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _timetableDirection == 'D' ? AppTheme.directionCyan : (isNight ? Colors.white24 : AppTheme.borderMedium),
                      ),
                    ),
                    child: Text(
                      'Dönüş',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: _timetableDirection == 'D' ? Colors.white : (isNight ? Colors.white70 : AppTheme.textSecondary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => setState(() => _timetableDirection = 'G'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _timetableDirection == 'G' ? AppTheme.directionPurple : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _timetableDirection == 'G' ? AppTheme.directionPurple : (isNight ? Colors.white24 : AppTheme.borderMedium),
                      ),
                    ),
                    child: Text(
                      'Gidiş',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: _timetableDirection == 'G' ? Colors.white : (isNight ? Colors.white70 : AppTheme.textSecondary),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),

        if (timetable.note != null && timetable.note!.isNotEmpty) ...[
          Text(
            timetable.note!,
            style: TextStyle(
              color: isNight ? Colors.white54 : AppTheme.textSecondary,
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
        ],

        // Grid of departure badges
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 180),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isNight ? Colors.white.withValues(alpha: 0.04) : AppTheme.lightGray,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isNight ? Colors.white12 : AppTheme.borderLight,
            ),
          ),
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    'Seçili gün ve yön için sefer saati bulunamadı.',
                    style: TextStyle(
                      color: isNight ? Colors.white60 : AppTheme.textSecondary,
                      fontSize: 11.5,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: entries.map((e) {
                      final isFuture = e.isUpcoming(now);
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(
                          color: isFuture
                              ? (isNight ? const Color(0xFF0284C7).withValues(alpha: 0.25) : const Color(0xFFE0F2FE))
                              : (isNight ? Colors.white.withValues(alpha: 0.05) : Colors.white),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isFuture
                                ? const Color(0xFF38BDF8)
                                : (isNight ? Colors.white10 : AppTheme.borderMedium),
                            width: isFuture ? 1.2 : 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isFuture) ...[
                              Container(
                                width: 5,
                                height: 5,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF10B981),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 5),
                            ],
                            Text(
                              e.time,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isFuture ? FontWeight.w900 : FontWeight.w600,
                                color: isFuture
                                    ? (isNight ? Colors.white : const Color(0xFF0369A1))
                                    : (isNight ? Colors.white38 : AppTheme.textMuted),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildDayTypePill(String code, String label) {
    final isSelected = _selectedDayType == code;
    final isNight = widget.isNightMode;

    return GestureDetector(
      onTap: () => setState(() => _selectedDayType = code),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? (isNight ? Colors.white : AppTheme.accentBlack)
              : (isNight ? Colors.white.withValues(alpha: 0.06) : AppTheme.background),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? (isNight ? Colors.white : AppTheme.accentBlack)
                : (isNight ? Colors.white12 : AppTheme.borderMedium),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected
                ? (isNight ? AppTheme.surfaceDark : Colors.white)
                : (isNight ? Colors.white70 : AppTheme.textSecondary),
            fontWeight: FontWeight.w700,
            fontSize: 11,
          ),
        ),
      ),
    );
  }


  Widget _buildDirectionButton({
    required String label,
    required String code,
    required Color accentColor,
    required bool isSelected,
    IconData? arrowIcon,
    bool compact = false,
  }) {
    return GestureDetector(
      onTap: () => onDirectionChanged(code),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 10,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? (isNightMode ? Colors.white : AppTheme.accentBlack)
              : (isNightMode
                  ? Colors.white.withValues(alpha: 0.05)
                  : AppTheme.background),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? (isNightMode ? Colors.white : AppTheme.accentBlack)
                : (isNightMode ? Colors.white12 : AppTheme.borderMedium),
            width: 1.5,
          ),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (arrowIcon != null) ...[
                Icon(
                  arrowIcon,
                  size: 13,
                  color: isSelected
                      ? (isNightMode ? AppTheme.surfaceDark : Colors.white)
                      : accentColor,
                ),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected
                        ? (isNightMode ? AppTheme.surfaceDark : Colors.white)
                        : (isNightMode ? Colors.white : AppTheme.textPrimary),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 3. Default Fast Navigation Bar with Vicinity Count & Update info
  Widget _buildDefaultStatusView(BuildContext context) {
    final updateTime = _formatLastUpdated();

    return Row(
      children: [
        // Instant Line Search Big Button
        Expanded(
          child: GestureDetector(
            onTap: onSearchTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              decoration: BoxDecoration(
                color: isNightMode ? Colors.white : AppTheme.accentBlack,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.directions_bus_filled_rounded,
                    color: isNightMode ? AppTheme.surfaceDark : Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Hat Seç veya Ara',
                    style: TextStyle(
                      color: isNightMode ? AppTheme.surfaceDark : Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),

        // Live Fleet Counter Pill with 5km proximity info & Last update
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isNightMode
                ? Colors.white.withValues(alpha: 0.06)
                : AppTheme.background,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isNightMode ? Colors.white12 : AppTheme.borderMedium,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF10B981),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '$visibleBusCount Araç',
                    style: TextStyle(
                      color: isNightMode ? Colors.white : AppTheme.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'Güncel • $updateTime',
                style: TextStyle(
                  color: isNightMode ? Colors.white54 : AppTheme.textSecondary,
                  fontWeight: FontWeight.w500,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
