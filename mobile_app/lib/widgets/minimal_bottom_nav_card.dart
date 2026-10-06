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
    required this.onDirectionChanged,
    required this.onClearSelection,
    required this.onSearchTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(32),
          topRight: Radius.circular(32),
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
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.borderMedium,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),

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

  // 1. Bus Vehicle Detailed View
  Widget _buildSelectedBusView(BuildContext context) {
    final bus = selectedBus!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                // Line Code Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppTheme.accentBlack,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    bus.line.isNotEmpty ? bus.line : 'İETT',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  bus.id, // Door / Vehicle No
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
            GestureDetector(
              onTap: onClearSelection,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: AppTheme.background,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Speed & Info Grid (Black & White high-contrast)
        Row(
          children: [
            // Speed indicator badge
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.accentBlack,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.speed_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${bus.speed.toInt()} km/s',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          bus.speed <= 3 ? 'Durakta / Bekliyor' : 'Seyir Halinde',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),

            // Time / Age badge
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.background,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.borderMedium),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.access_time_filled_rounded,
                      color: AppTheme.accentBlack,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          bus.time.isNotEmpty ? bus.time : 'Canlı',
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          bus.plate.isNotEmpty ? bus.plate : (bus.operator.isNotEmpty ? bus.operator : 'İETT Filo'),
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),

        if (bus.headsign.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            bus.headsign,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ],
      ],
    );
  }

  // 2. Active Line View (with Direction D / G toggle)
  Widget _buildActiveLineView(BuildContext context) {
    final dRoute = routeDetails?.directions['D'];
    final gRoute = routeDetails?.directions['G'];

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
                Text(
                  'Hat $activeLine',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  '$visibleBusCount Canlı Araç Takip Ediliyor',
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            GestureDetector(
              onTap: onClearSelection,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.accentBlack,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  'Kapat',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Direction Selection Tabs (High Contrast Black & White)
        Row(
          children: [
            Expanded(
              child: _buildDirectionButton(
                label: dRoute?.destination ?? 'Dönüş Yönü',
                code: 'D',
                isSelected: selectedDirection == 'D',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildDirectionButton(
                label: gRoute?.destination ?? 'Gidiş Yönü',
                code: 'G',
                isSelected: selectedDirection == 'G',
              ),
            ),
            const SizedBox(width: 8),
            _buildDirectionButton(
              label: 'Tümü',
              code: 'ALL',
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
    required bool isSelected,
    bool compact = false,
  }) {
    return GestureDetector(
      onTap: () => onDirectionChanged(code),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 10,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.accentBlack : AppTheme.background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppTheme.accentBlack : AppTheme.borderMedium,
            width: 1.5,
          ),
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isSelected ? Colors.white : AppTheme.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  // 3. Default Fast Navigation Bar with Vicinity Count
  Widget _buildDefaultStatusView(BuildContext context) {
    return Row(
      children: [
        // Instant Line Search Big Button
        Expanded(
          child: GestureDetector(
            onTap: onSearchTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: AppTheme.accentBlack,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.directions_bus_filled_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Hat Seç veya Ara',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),

        // Live Fleet Counter Pill with 5km proximity info
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.borderMedium),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: AppTheme.accentBlack,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$visibleBusCount Araç',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              const Text(
                'Yakında (5 km)',
                style: TextStyle(
                  color: AppTheme.textSecondary,
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
