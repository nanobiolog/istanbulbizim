import 'package:flutter/material.dart';
import '../models/transit_models.dart';
import '../theme/app_theme.dart';

class QuickActionPills extends StatelessWidget {
  final List<NearbyBusLine> nearbyLines;
  final String? selectedLine;
  final Function(String) onSelectLine;
  final VoidCallback onClearLine;
  final VoidCallback onSearchTap;
  final bool showMetro;
  final VoidCallback onToggleMetro;
  final bool showTrains;
  final VoidCallback onToggleTrains;
  final bool showFerries;
  final VoidCallback? onToggleFerries;
  final bool showBuses;
  final VoidCallback? onToggleBuses;
  final bool showStops;
  final VoidCallback? onToggleStops;
  final bool isNightMode;

  const QuickActionPills({
    super.key,
    required this.nearbyLines,
    required this.selectedLine,
    required this.onSelectLine,
    required this.onClearLine,
    required this.onSearchTap,
    required this.showMetro,
    required this.onToggleMetro,
    required this.showTrains,
    required this.onToggleTrains,
    this.showFerries = true,
    this.onToggleFerries,
    this.showBuses = false,
    this.onToggleBuses,
    this.showStops = false,
    this.onToggleStops,
    this.isNightMode = true,
  });

  static const List<String> _featuredRail = ['B1', 'M2', 'M4', 'M5', 'M7', 'T1', 'M11'];

  @override
  Widget build(BuildContext context) {
    final hasSelectedInList = selectedLine != null &&
        (nearbyLines.any((l) => l.lineCode.toUpperCase() == selectedLine!.toUpperCase()) ||
            _featuredRail.contains(selectedLine!.toUpperCase()));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Row 1: Search bar + Primary Layer Mode Toggles
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            physics: const BouncingScrollPhysics(),
            children: [
              _buildSearchButton(),
              const SizedBox(width: 7),
              if (selectedLine != null) ...[
                _buildClearFilterButton(),
                const SizedBox(width: 7),
              ],
              _buildToggleChip(
                label: 'Raylı',
                icon: Icons.subway_rounded,
                activeColor: const Color(0xFF38BDF8),
                isSelected: showMetro,
                onTap: onToggleMetro,
              ),
              const SizedBox(width: 6),
              if (onToggleFerries != null) ...[
                _buildToggleChip(
                  label: 'Vapur',
                  icon: Icons.directions_boat_filled_rounded,
                  activeColor: const Color(0xFF0EA5E9),
                  isSelected: showFerries,
                  onTap: onToggleFerries!,
                ),
                const SizedBox(width: 6),
              ],
              if (onToggleBuses != null) ...[
                _buildToggleChip(
                  label: 'Yakın Otobüs',
                  icon: Icons.directions_bus_rounded,
                  activeColor: const Color(0xFFF59E0B),
                  isSelected: showBuses,
                  onTap: onToggleBuses!,
                ),
                const SizedBox(width: 6),
              ],
              if (onToggleStops != null) ...[
                _buildToggleChip(
                  label: 'Duraklar',
                  icon: Icons.place_rounded,
                  activeColor: const Color(0xFF10B981),
                  isSelected: showStops,
                  onTap: onToggleStops!,
                ),
                const SizedBox(width: 6),
              ],
              _buildToggleChip(
                label: 'Canlı Tren',
                icon: Icons.train_rounded,
                activeColor: const Color(0xFFA855F7),
                isSelected: showTrains,
                onTap: onToggleTrains,
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // Row 2: Featured Rail Lines + Nearby Bus Lines in current viewport
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            physics: const BouncingScrollPhysics(),
            children: [
              if (selectedLine != null && !hasSelectedInList) ...[
                _buildLineChip(
                  NearbyBusLine(
                    lineCode: selectedLine!,
                    busCount: 0,
                    distanceMeters: 0,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              for (final railCode in _featuredRail)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _buildRailChip(railCode),
                ),
              ...nearbyLines
                  .where((l) => !_featuredRail.contains(l.lineCode.toUpperCase()) && l.lineCode.toUpperCase() != 'MARMARAY')
                  .take(12)
                  .map((line) {
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _buildLineChip(line),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSearchButton() {
    return GestureDetector(
      onTap: onSearchTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isNightMode
              ? const Color(0xFF0B1120).withValues(alpha: 0.94)
              : Colors.white.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isNightMode
                ? const Color(0xFF38BDF8).withValues(alpha: 0.35)
                : AppTheme.borderMedium,
            width: 1.2,
          ),
          boxShadow: const [
            BoxShadow(color: Color(0x29000000), blurRadius: 10, offset: Offset(0, 3)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.search_rounded,
              size: 16,
              color: Color(0xFF38BDF8),
            ),
            const SizedBox(width: 6),
            Text(
              'Hat / İstasyon Ara',
              style: TextStyle(
                color: isNightMode ? Colors.white : AppTheme.textPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClearFilterButton() {
    return GestureDetector(
      onTap: onClearLine,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFEF4444),
          borderRadius: BorderRadius.circular(22),
          boxShadow: const [
            BoxShadow(color: Color(0x33EF4444), blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.close_rounded, size: 14, color: Colors.white),
            SizedBox(width: 4),
            Text(
              'Filtreyi Kaldır',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRailChip(String code) {
    final isSelected = selectedLine != null &&
        (selectedLine!.toUpperCase() == code || (code == 'B1' && selectedLine!.toUpperCase() == 'MARMARAY'));
    final color = AppTheme.lineColor(code);
    final label = code == 'B1' ? 'Marmaray' : code;

    return GestureDetector(
      onTap: () {
        if (isSelected) {
          onClearLine();
        } else {
          onSelectLine(code);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? color
              : (isNightMode ? const Color(0xFF0F172A).withValues(alpha: 0.90) : Colors.white.withValues(alpha: 0.94)),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected ? Colors.white : color.withValues(alpha: 0.65),
            width: isSelected ? 1.6 : 1.2,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 8, offset: const Offset(0, 2))]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : (isNightMode ? Colors.white : AppTheme.textPrimary),
                fontWeight: FontWeight.w900,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLineChip(NearbyBusLine line) {
    final isSelected = selectedLine != null &&
        selectedLine!.toUpperCase() == line.lineCode.toUpperCase();

    return GestureDetector(
      onTap: () {
        if (isSelected) {
          onClearLine();
        } else {
          onSelectLine(line.lineCode);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? (isNightMode ? Colors.white : AppTheme.accentBlack)
              : (isNightMode
                  ? const Color(0xFF0F172A).withValues(alpha: 0.88)
                  : Colors.white.withValues(alpha: 0.94)),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected
                ? (isNightMode ? Colors.white : AppTheme.accentBlack)
                : (isNightMode
                    ? Colors.white.withValues(alpha: 0.15)
                    : AppTheme.borderMedium),
            width: isSelected ? 1.5 : 1.1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.directions_bus_rounded,
              size: 13,
              color: isSelected
                  ? (isNightMode ? AppTheme.accentBlack : Colors.white)
                  : AppTheme.lineColor(line.lineCode),
            ),
            const SizedBox(width: 4),
            Text(
              line.lineCode,
              style: TextStyle(
                color: isSelected
                    ? (isNightMode ? AppTheme.accentBlack : Colors.white)
                    : (isNightMode ? Colors.white : AppTheme.textPrimary),
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
            if (line.busCount > 0) ...[
              const SizedBox(width: 5),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1),
                decoration: BoxDecoration(
                  color: isSelected
                      ? (isNightMode ? Colors.black12 : Colors.white24)
                      : (isNightMode
                          ? Colors.white.withValues(alpha: 0.12)
                          : AppTheme.lightGray),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${line.busCount}',
                  style: TextStyle(
                    color: isSelected
                        ? (isNightMode ? AppTheme.accentBlack : Colors.white)
                        : (isNightMode ? Colors.white70 : AppTheme.textPrimary),
                    fontSize: 9.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToggleChip({
    required String label,
    required IconData icon,
    required Color activeColor,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? activeColor.withValues(alpha: isNightMode ? 0.22 : 0.15)
              : (isNightMode
                  ? const Color(0xFF0D1117).withValues(alpha: 0.85)
                  : Colors.white.withValues(alpha: 0.92)),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isSelected
                ? activeColor
                : (isNightMode
                    ? Colors.white.withValues(alpha: 0.14)
                    : AppTheme.borderMedium),
            width: isSelected ? 1.4 : 1.1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected
                  ? activeColor
                  : (isNightMode ? Colors.white60 : AppTheme.textSecondary),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? (isNightMode ? Colors.white : AppTheme.textPrimary)
                    : (isNightMode ? Colors.white60 : AppTheme.textSecondary),
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
