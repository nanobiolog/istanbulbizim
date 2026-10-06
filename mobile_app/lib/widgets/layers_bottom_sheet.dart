import 'package:flutter/material.dart';
import '../services/transit_provider.dart';
import '../theme/app_theme.dart';

class LayersBottomSheet extends StatelessWidget {
  final TransitProvider provider;
  final VoidCallback onClose;

  const LayersBottomSheet({
    super.key,
    required this.provider,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(28),
          topRight: Radius.circular(28),
        ),
        border: Border.all(color: AppTheme.cardBorderDark, width: 1.2),
        boxShadow: AppTheme.sheetShadow,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Drag Handle Bar
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textMutedDark.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Header: Title & Close Button
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.layers_rounded,
                      color: AppTheme.textLight,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Katmanlar ve Seçenekler',
                      style: TextStyle(
                        color: AppTheme.textLight,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ],
                ),
                GestureDetector(
                  onTap: onClose,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: AppTheme.textMutedDark,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Layer Toggle Switches matching media_1791311521309.png
            _buildToggleRow(
              icon: '🚌',
              title: 'Canlı İETT Otobüsleri',
              value: provider.showBuses,
              onChanged: (_) => provider.toggleBuses(),
            ),
            const Divider(color: AppTheme.cardBorderDark, height: 16),

            _buildToggleRow(
              icon: '🚇',
              title: 'Raylı Sistemler (Metro / Tramvay)',
              value: provider.showMetroLines,
              onChanged: (_) => provider.toggleMetroLines(),
            ),
            const Divider(color: AppTheme.cardBorderDark, height: 16),

            _buildToggleRow(
              icon: '🚅',
              title: 'Hareketli Trenler (Tarife / Canlı)',
              value: provider.showMetroTrains,
              onChanged: (_) => provider.toggleMetroTrains(),
            ),
            const Divider(color: AppTheme.cardBorderDark, height: 16),

            _buildToggleRow(
              icon: '🚏',
              title: 'Otobüs Durakları',
              value: provider.showBusStops,
              onChanged: (_) => provider.toggleBusStops(),
            ),
            const SizedBox(height: 20),

            // Live Fleet Stats Row
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppTheme.cardBorderDark),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${provider.activeBusCount}',
                          style: const TextStyle(
                            color: Color(0xFF10B981),
                            fontWeight: FontWeight.w900,
                            fontSize: 20,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Canlı İETT Otobüsü',
                          style: TextStyle(
                            color: AppTheme.textMutedDark,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppTheme.cardBorderDark),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${provider.metroTrains.length}',
                          style: const TextStyle(
                            color: Color(0xFF38BDF8),
                            fontWeight: FontWeight.w900,
                            fontSize: 20,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Canlı Metro / Raylı',
                          style: TextStyle(
                            color: AppTheme.textMutedDark,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Speed Color Legend
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildLegendItem(const Color(0xFF10B981), 'Akıcı (>15)'),
                  _buildLegendItem(const Color(0xFFF59E0B), 'Yoğun (5-15)'),
                  _buildLegendItem(const Color(0xFF64748B), 'Duran (0-5)'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToggleRow({
    required String icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Text(icon, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Text(
              title,
              style: const TextStyle(
                color: AppTheme.textLight,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
        Switch.adaptive(
          value: value,
          onChanged: onChanged,
          activeThumbColor: const Color(0xFF0284C7),
          activeTrackColor: const Color(0xFF0284C7).withValues(alpha: 0.5),
          inactiveThumbColor: Colors.white54,
          inactiveTrackColor: Colors.white12,
        ),
      ],
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textMutedDark,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
