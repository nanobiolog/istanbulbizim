import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class FloatingMapControls extends StatelessWidget {
  final VoidCallback onRecenter;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onRefresh;
  final bool isRefreshing;
  final bool hasUserLocation;

  const FloatingMapControls({
    super.key,
    required this.onRecenter,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onRefresh,
    this.isRefreshing = false,
    this.hasUserLocation = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Refresh Fleet Button
        _buildCircleButton(
          onTap: onRefresh,
          icon: isRefreshing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accentBlack),
                  ),
                )
              : const Icon(
                  Icons.refresh_rounded,
                  color: AppTheme.accentBlack,
                  size: 26,
                ),
        ),
        const SizedBox(height: 12),

        // Zoom In / Zoom Out Combined Pill
        Container(
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(28),
            boxShadow: AppTheme.pillShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildControlItem(
                icon: Icons.add_rounded,
                onTap: onZoomIn,
              ),
              Container(
                width: 28,
                height: 1,
                color: AppTheme.borderLight,
              ),
              _buildControlItem(
                icon: Icons.remove_rounded,
                onTap: onZoomOut,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // My Location Button
        _buildCircleButton(
          onTap: onRecenter,
          icon: Icon(
            hasUserLocation ? Icons.my_location_rounded : Icons.location_searching_rounded,
            color: AppTheme.accentBlack,
            size: 26,
          ),
        ),
      ],
    );
  }

  Widget _buildCircleButton({
    required VoidCallback onTap,
    required Widget icon,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: AppTheme.surface,
          shape: BoxShape.circle,
          boxShadow: AppTheme.pillShadow,
        ),
        child: Center(child: icon),
      ),
    );
  }

  Widget _buildControlItem({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 52,
        height: 50,
        child: Center(
          child: Icon(
            icon,
            color: AppTheme.accentBlack,
            size: 24,
          ),
        ),
      ),
    );
  }
}
