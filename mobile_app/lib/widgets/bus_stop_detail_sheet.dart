import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/transit_models.dart';
import '../services/transit_provider.dart';
import '../theme/app_theme.dart';

class BusStopDetailSheet extends StatelessWidget {
  final BusStop stop;
  final TransitProvider provider;
  final VoidCallback onClose;
  final Function(String) onSelectLine;

  const BusStopDetailSheet({
    super.key,
    required this.stop,
    required this.provider,
    required this.onClose,
    required this.onSelectLine,
  });

  @override
  Widget build(BuildContext context) {
    final approaching = provider.getApproachingBusesForStop(stop);

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.65,
      ),
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

            // Header: Stop Icon, Name & Code, Close Button
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.3)),
                  ),
                  child: const Text('🚏', style: TextStyle(fontSize: 20)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stop.name,
                        style: const TextStyle(
                          color: AppTheme.textLight,
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${stop.district.isNotEmpty ? '${stop.district} • ' : ''}Durak Kodu: ${stop.code}',
                        style: const TextStyle(
                          color: AppTheme.textMutedDark,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
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
            const SizedBox(height: 16),

            // Section Title: Approaching Buses
            Row(
              children: [
                const Icon(
                  Icons.near_me_rounded,
                  color: Color(0xFF38BDF8),
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  'Yaklaşan Canlı Otobüsler (${approaching.length})',
                  style: const TextStyle(
                    color: AppTheme.textLight,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Approaching Buses List
            if (approaching.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.cardBorderDark,
                    style: BorderStyle.solid,
                  ),
                ),
                child: const Text(
                  'Bu durağa 4.5 km mesafede yaklaşan canlı otobüs tespit edilemedi veya araçlar ilk kalkış peronunda beklemede.',
                  style: TextStyle(
                    color: AppTheme.textMutedDark,
                    fontSize: 12,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const BouncingScrollPhysics(),
                  itemCount: approaching.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, idx) {
                    final item = approaching[idx];
                    final BusVehicle bus = item['bus'] as BusVehicle;
                    final int distM = item['dist_m'] as int;
                    final int estSec = item['est_sec'] as int;

                    final distKm = (distM / 1000).toStringAsFixed(1);
                    final estMin = math.max(1, (estSec / 60).round());

                    return GestureDetector(
                      onTap: () {
                        if (bus.line.isNotEmpty) {
                          onSelectLine(bus.line);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.cardBorderDark),
                        ),
                        child: Row(
                          children: [
                            // Line Code Pill
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                bus.line.isNotEmpty ? bus.line : 'İETT',
                                style: const TextStyle(
                                  color: AppTheme.accentBlack,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),

                            // Bus Details
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    bus.headsign.isNotEmpty ? bus.headsign : 'Kapı: ${bus.id}',
                                    style: const TextStyle(
                                      color: AppTheme.textLight,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${bus.speed.round()} km/s • $distKm km uzakta',
                                    style: const TextStyle(
                                      color: AppTheme.textMutedDark,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Countdown Pill
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.35),
                                ),
                              ),
                              child: Text(
                                '⏱️ ~$estMin dk',
                                style: const TextStyle(
                                  color: Color(0xFF10B981),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
