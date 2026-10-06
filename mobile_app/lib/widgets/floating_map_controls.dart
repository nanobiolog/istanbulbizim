import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class FloatingMapControls extends StatelessWidget {
  final VoidCallback onRecenter;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onRefresh;
  final VoidCallback? onToggleNightMode;
  final VoidCallback? onOpenLayers;
  final bool isNightMode;
  final bool isRefreshing;
  final bool hasUserLocation;

  const FloatingMapControls({
    super.key,
    required this.onRecenter,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onRefresh,
    this.onToggleNightMode,
    this.onOpenLayers,
    this.isNightMode = false,
    this.isRefreshing = false,
    this.hasUserLocation = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. Night Mode Toggle Button (Moon Icon matching media_1791311536821.png)
        if (onToggleNightMode != null) ...[
          _buildCircleButton(
            onTap: onToggleNightMode!,
            icon: Icon(
              isNightMode ? Icons.nightlight_round : Icons.wb_sunny_rounded,
              color: isNightMode ? const Color(0xFFFEF08A) : AppTheme.accentBlack,
              size: 24,
            ),
            darkStyle: isNightMode,
          ),
          const SizedBox(height: 10),
        ],

        // 2. Layers Menu Button (Layers Icon matching media_1791311536821.png)
        if (onOpenLayers != null) ...[
          _buildCircleButton(
            onTap: onOpenLayers!,
            icon: Icon(
              Icons.layers_rounded,
              color: isNightMode ? Colors.white : AppTheme.accentBlack,
              size: 24,
            ),
            darkStyle: isNightMode,
          ),
          const SizedBox(height: 10),
        ],

        // 3. Zoom In / Zoom Out Combined Pill
        Container(
          decoration: BoxDecoration(
            color: isNightMode ? AppTheme.cardDark : AppTheme.surface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: isNightMode ? AppTheme.cardBorderDark : AppTheme.borderLight,
            ),
            boxShadow: AppTheme.pillShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildControlItem(
                icon: Icons.add_rounded,
                onTap: onZoomIn,
                darkStyle: isNightMode,
              ),
              Container(
                width: 28,
                height: 1,
                color: isNightMode ? AppTheme.cardBorderDark : AppTheme.borderLight,
              ),
              _buildControlItem(
                icon: Icons.remove_rounded,
                onTap: onZoomOut,
                darkStyle: isNightMode,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // 4. GPS Recenter Button
        _buildCircleButton(
          onTap: onRecenter,
          icon: Icon(
            hasUserLocation ? Icons.my_location_rounded : Icons.location_searching_rounded,
            color: hasUserLocation
                ? const Color(0xFF38BDF8)
                : (isNightMode ? Colors.white : AppTheme.accentBlack),
            size: 24,
          ),
          darkStyle: isNightMode,
        ),
        const SizedBox(height: 10),

        // 5. Refresh Fleet Button
        _buildCircleButton(
          onTap: onRefresh,
          icon: isRefreshing
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isNightMode ? const Color(0xFF38BDF8) : AppTheme.accentBlack,
                    ),
                  ),
                )
              : Icon(
                  Icons.refresh_rounded,
                  color: isNightMode ? Colors.white : AppTheme.accentBlack,
                  size: 24,
                ),
          darkStyle: isNightMode,
        ),
      ],
    );
  }

  Widget _buildCircleButton({
    required VoidCallback onTap,
    required Widget icon,
    bool darkStyle = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: darkStyle ? AppTheme.cardDark : AppTheme.surface,
          shape: BoxShape.circle,
          border: Border.all(
            color: darkStyle ? AppTheme.cardBorderDark : AppTheme.borderLight,
            width: 1.2,
          ),
          boxShadow: AppTheme.pillShadow,
        ),
        child: Center(child: icon),
      ),
    );
  }

  Widget _buildControlItem({
    required IconData icon,
    required VoidCallback onTap,
    bool darkStyle = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 48,
        height: 44,
        child: Center(
          child: Icon(
            icon,
            color: darkStyle ? Colors.white : AppTheme.accentBlack,
            size: 22,
          ),
        ),
      ),
    );
  }
}
