import 'package:flutter/material.dart';
import '../models/transit_models.dart';
import '../theme/app_theme.dart';

class MetroTrainDetailSheet extends StatelessWidget {
  final MetroTrainVehicle train;
  final VoidCallback onClose;

  const MetroTrainDetailSheet({
    super.key,
    required this.train,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
            const SizedBox(height: 12),

            // Header: Train Icon, Title, Badge & Close Button
            Row(
              children: [
                const Text(
                  '🚅',
                  style: TextStyle(fontSize: 22),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          '${train.lineCode} Metro Treni',
                          style: const TextStyle(
                            color: AppTheme.textLight,
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                            letterSpacing: -0.3,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: train.color,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: [
                            BoxShadow(
                              color: train.color.withValues(alpha: 0.4),
                              blurRadius: 6,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        child: Text(
                          train.id,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
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
            const SizedBox(height: 14),

            // Status Banner (⚡ Seyir Halinde | 0.00 m/s²)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: train.statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: train.statusColor.withValues(alpha: 0.35),
                  width: 1.2,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Text(
                        train.statusIcon,
                        style: const TextStyle(fontSize: 16),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        train.statusTitle,
                        style: TextStyle(
                          color: train.statusColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: train.statusColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      train.accDisplay,
                      style: TextStyle(
                        color: train.statusColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 2-Column Info Details Grid
            Row(
              children: [
                Expanded(
                  child: _buildDetailItem(
                    label: 'Hat',
                    valueWidget: Text(
                      train.lineCode,
                      style: TextStyle(
                        color: train.color,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildDetailItem(
                    label: 'Sistem',
                    valueWidget: Text(
                      train.systemType,
                      style: const TextStyle(
                        color: AppTheme.textMutedDark,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: _buildDetailItem(
                    label: 'Anlık Hız',
                    valueWidget: Text(
                      '${train.currentSpeed.round()} km/s',
                      style: const TextStyle(
                        color: AppTheme.textLight,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildDetailItem(
                    label: 'İvme / Fren',
                    valueWidget: Text(
                      train.accDisplay,
                      style: TextStyle(
                        color: train.statusColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Remaining Distance
            _buildDetailItem(
              label: 'Kalan Mesafe',
              valueWidget: Text(
                '${train.remainingMeters.round()} m',
                style: const TextStyle(
                  color: AppTheme.textLight,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Next Station
            _buildDetailItem(
              label: 'Sonraki Durak',
              valueWidget: Text(
                train.targetStationName,
                style: const TextStyle(
                  color: Color(0xFF38BDF8),
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Estimated Arrival
            _buildDetailItem(
              label: 'Tahmini Duruş / Varış',
              valueWidget: Text(
                '${train.etaFull} (${train.arrivalClock})',
                style: const TextStyle(
                  color: Color(0xFFFEF08A),
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Progress Bar Section: [prevStation] [43%] [nextStation]
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    train.prevStationName,
                    style: const TextStyle(
                      color: AppTheme.textMutedDark,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '${(train.progress * 100).round()}%',
                    style: const TextStyle(
                      color: AppTheme.textLight,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    train.targetStationName,
                    style: const TextStyle(
                      color: AppTheme.textMutedDark,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Progress bar track with line-colored fill
            LayoutBuilder(
              builder: (context, constraints) {
                final barWidth = constraints.maxWidth;
                final fillWidth = (train.progress.clamp(0.0, 1.0) * barWidth);

                return Container(
                  height: 6,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: fillWidth,
                      height: 6,
                      decoration: BoxDecoration(
                        color: train.color,
                        borderRadius: BorderRadius.circular(3),
                        boxShadow: [
                          BoxShadow(
                            color: train.color.withValues(alpha: 0.6),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailItem({
    required String label,
    required Widget valueWidget,
  }) {
    return Row(
      children: [
        Text(
          '$label: ',
          style: const TextStyle(
            color: AppTheme.textLight,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
        Expanded(child: valueWidget),
      ],
    );
  }
}
