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
    this.isNightMode = true,
  });

  @override
  Widget build(BuildContext context) {
    // If a line is selected and not in current nearby view, ensure it appears at start
    final hasSelectedInList = selectedLine != null &&
        nearbyLines.any((l) => l.lineCode.toUpperCase() == selectedLine!.toUpperCase());

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        physics: const BouncingScrollPhysics(),
        children: [
          // 1. Compact Search Button
          _buildSearchButton(),
          const SizedBox(width: 7),

          // 2. Clear Selection Button (if a line is currently active)
          if (selectedLine != null) ...[
            _buildClearFilterButton(),
            const SizedBox(width: 7),
          ],

          // 3. Highlighted active line if not already in nearby list
          if (selectedLine != null && !hasSelectedInList) ...[
            _buildLineChip(
              NearbyBusLine(
                lineCode: selectedLine!,
                busCount: 0,
                distanceMeters: 0,
              ),
            ),
            const SizedBox(width: 7),
          ],

          // 4. Closest Bus Lines in Field View Area
          ...nearbyLines.map((line) {
            return Padding(
              padding: const EdgeInsets.only(right: 7),
              child: _buildLineChip(line),
            );
          }),

          // 5. Metro & Train Network Toggles at end of row
          const SizedBox(width: 4),
          _buildToggleChip(
            label: 'Metro',
            icon: Icons.subway_rounded,
            isSelected: showMetro,
            onTap: onToggleMetro,
          ),
          const SizedBox(width: 7),
          _buildToggleChip(
            label: 'Trenler',
            icon: Icons.train_rounded,
            isSelected: showTrains,
            onTap: onToggleTrains,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchButton() {
    return GestureDetector(
      onTap: onSearchTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: isNightMode
              ? const Color(0xFF0D1117).withValues(alpha: 0.92)
              : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isNightMode
                ? Colors.white.withValues(alpha: 0.16)
                : AppTheme.borderMedium,
            width: 1.2,
          ),
          boxShadow: AppTheme.pillShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_rounded,
              size: 16,
              color: isNightMode ? Colors.white : AppTheme.textPrimary,
            ),
            const SizedBox(width: 5),
            Text(
              'Ara',
              style: TextStyle(
                color: isNightMode ? Colors.white : AppTheme.textPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 13,
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
          color: const Color(0xFFEF4444).withValues(alpha: 0.20),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: const Color(0xFFEF4444).withValues(alpha: 0.70),
            width: 1.2,
          ),
          boxShadow: AppTheme.pillShadow,
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.close_rounded,
              size: 14,
              color: Color(0xFFF87171),
            ),
            SizedBox(width: 4),
            Text(
              'Tüm Hatlar',
              style: TextStyle(
                color: Color(0xFFFCA5A5),
                fontWeight: FontWeight.w800,
                fontSize: 13,
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
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white
              : (isNightMode
                  ? const Color(0xFF0D1117).withValues(alpha: 0.92)
                  : Colors.white),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isSelected
                ? Colors.white
                : (isNightMode
                    ? Colors.white.withValues(alpha: 0.16)
                    : AppTheme.borderMedium),
            width: isSelected ? 1.5 : 1.2,
          ),
          boxShadow: AppTheme.pillShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.directions_bus_rounded,
              size: 15,
              color: isSelected
                  ? const Color(0xFF090D16)
                  : (isNightMode ? const Color(0xFF38BDF8) : AppTheme.accentBlack),
            ),
            const SizedBox(width: 5),
            Text(
              line.lineCode,
              style: TextStyle(
                color: isSelected
                    ? const Color(0xFF090D16)
                    : (isNightMode ? Colors.white : AppTheme.textPrimary),
                fontWeight: FontWeight.w800,
                fontSize: 13.5,
              ),
            ),
            if (line.busCount > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF090D16).withValues(alpha: 0.10)
                      : const Color(0xFF10B981).withValues(alpha: 0.20),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF090D16).withValues(alpha: 0.25)
                        : const Color(0xFF10B981).withValues(alpha: 0.45),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  '${line.busCount}',
                  style: TextStyle(
                    color: isSelected
                        ? const Color(0xFF090D16)
                        : const Color(0xFF34D399),
                    fontSize: 10,
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
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? (isNightMode ? Colors.white.withValues(alpha: 0.22) : AppTheme.accentBlack)
              : (isNightMode
                  ? const Color(0xFF0D1117).withValues(alpha: 0.85)
                  : Colors.white),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isSelected
                ? (isNightMode ? const Color(0xFF38BDF8) : AppTheme.accentBlack)
                : (isNightMode
                    ? Colors.white.withValues(alpha: 0.14)
                    : AppTheme.borderMedium),
            width: 1.2,
          ),
          boxShadow: AppTheme.pillShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected
                  ? (isNightMode ? const Color(0xFF38BDF8) : Colors.white)
                  : (isNightMode ? Colors.white70 : AppTheme.textPrimary),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? Colors.white
                    : (isNightMode ? Colors.white70 : AppTheme.textPrimary),
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
