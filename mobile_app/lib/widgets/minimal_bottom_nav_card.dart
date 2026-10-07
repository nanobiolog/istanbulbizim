import 'package:flutter/material.dart';
import '../models/transit_models.dart';
import '../theme/app_theme.dart';

class MinimalBottomNavCard extends StatelessWidget {
  final BusVehicle? selectedBus;
  final String? activeLine;
  final LineRouteDetails? routeDetails;
  final int visibleBusCount;
  final int totalBusCount;
  final String selectedDirection;
  final DateTime? lastUpdated;
  final bool isNightMode;
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
    required this.onDirectionChanged,
    required this.onClearSelection,
    required this.onSearchTap,
  });

  String _formatLastUpdated() {
    if (lastUpdated == null) return 'Canlı';
    final now = DateTime.now();
    final diff = now.difference(lastUpdated!);
    if (diff.inSeconds < 10) return 'Az önce';
    if (diff.inSeconds < 60) return '${diff.inSeconds} sn önce';
    return '${lastUpdated!.hour.toString().padLeft(2, '0')}:${lastUpdated!.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
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

            if (selectedBus != null)
              _buildSelectedBusView(context)
            else if (activeLine != null)
              _buildActiveLineView(context)
            else
              _buildDefaultStatusView(context),
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

        // Direction / Headsign Card if available
        if (bus.headsign.isNotEmpty || dirText.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                Icon(
                  bus.direction == 'D'
                      ? Icons.arrow_forward_rounded
                      : Icons.arrow_back_rounded,
                  color: bus.direction == 'D'
                      ? AppTheme.directionCyan
                      : AppTheme.directionPurple,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (dirText.isNotEmpty)
                        Text(
                          dirText,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: bus.direction == 'D'
                                ? AppTheme.directionCyan
                                : AppTheme.directionPurple,
                            letterSpacing: 0.3,
                          ),
                        ),
                      Text(
                        bus.headsign.isNotEmpty ? bus.headsign : 'Güzergah Boyunca',
                        style: TextStyle(
                          color: isNightMode ? Colors.white : AppTheme.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (bus.bearing != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                            size: 12,
                            color: Color(0xFF0284C7),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${bus.bearing!.toInt()}°',
                          style: TextStyle(
                            fontSize: 11,
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
                isSelected: selectedDirection == 'D',
                arrowIcon: Icons.arrow_forward_rounded,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildDirectionButton(
                label: gRoute?.destination ?? 'Gidiş Yönü',
                code: 'G',
                accentColor: AppTheme.directionPurple,
                isSelected: selectedDirection == 'G',
                arrowIcon: Icons.arrow_back_rounded,
              ),
            ),
            const SizedBox(width: 8),
            _buildDirectionButton(
              label: 'Tümü',
              code: 'ALL',
              accentColor: const Color(0xFF0284C7),
              isSelected: selectedDirection == 'ALL',
              compact: true,
            ),
          ],
        ),
      ],
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
