import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class QuickActionPills extends StatelessWidget {
  final List<String> popularLines;
  final String? selectedLine;
  final Function(String) onSelectLine;
  final VoidCallback onClearLine;
  final bool showMetro;
  final VoidCallback onToggleMetro;

  const QuickActionPills({
    super.key,
    required this.popularLines,
    required this.selectedLine,
    required this.onSelectLine,
    required this.onClearLine,
    required this.showMetro,
    required this.onToggleMetro,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        physics: const BouncingScrollPhysics(),
        children: [
          // Metro Toggle Pill
          _buildPill(
            label: 'Metro',
            icon: Icons.subway_rounded,
            isSelected: showMetro,
            activeColor: const Color(0xFF009944), // Metro Green
            onTap: onToggleMetro,
          ),
          const SizedBox(width: 8),

          // All Buses / Clear Filter Pill
          if (selectedLine != null) ...[
            _buildPill(
              label: 'Tüm Hatlar',
              icon: Icons.clear_all_rounded,
              isSelected: false,
              activeColor: AppTheme.accentBlack,
              onTap: onClearLine,
            ),
            const SizedBox(width: 8),
          ],

          // Popular Bus Lines
          ...popularLines.map((line) {
            final isSelected = selectedLine == line;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _buildPill(
                label: line,
                icon: Icons.directions_bus_rounded,
                isSelected: isSelected,
                activeColor: AppTheme.accentBlack,
                onTap: () => onSelectLine(line),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildPill({
    required String label,
    required IconData icon,
    required bool isSelected,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? activeColor : AppTheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isSelected ? activeColor : AppTheme.borderLight,
            width: 1.5,
          ),
          boxShadow: AppTheme.pillShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? Colors.white : AppTheme.textPrimary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : AppTheme.textPrimary,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
