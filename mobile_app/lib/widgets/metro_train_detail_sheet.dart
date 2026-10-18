import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/rail_models.dart';
import '../models/transit_models.dart';
import '../services/rail_engine.dart';
import '../theme/app_theme.dart';

class MetroTrainDetailSheet extends StatelessWidget {
  final MetroTrainVehicle train;
  final List<RailStatusItem> statusItems;
  final ValueNotifier<int>? clock;
  final VoidCallback onClose;
  final VoidCallback? onFollow3D;

  const MetroTrainDetailSheet({
    super.key,
    required this.train,
    required this.onClose,
    this.statusItems = const [],
    this.clock,
    this.onFollow3D,
  });

  bool get _isMarmaray => train.lineCode == 'B1' || train.lineCode == 'MARMARAY';

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.62),
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
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
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

              // Header: line badge, destination, close
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: train.color,
                      borderRadius: BorderRadius.circular(7),
                      boxShadow: [BoxShadow(color: train.color.withValues(alpha: 0.4), blurRadius: 6, offset: const Offset(0, 1))],
                    ),
                    child: Text(
                      _isMarmaray ? 'MARMARAY' : train.lineCode,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w900),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      train.headsign.isNotEmpty ? '➔ ${train.headsign}' : train.targetStationName,
                      style: const TextStyle(color: AppTheme.textLight, fontWeight: FontWeight.w800, fontSize: 18, letterSpacing: -0.3),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: onClose,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded, size: 18, color: AppTheme.textMutedDark),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Data provenance: official timetable vs estimate
              Row(
                children: [
                  Icon(
                    train.official ? Icons.verified_rounded : Icons.schedule_rounded,
                    size: 14,
                    color: train.official ? AppTheme.statusLive : const Color(0xFFF59E0B),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      train.official
                          ? 'Resmî tarifeye göre konum • ${train.source}'
                          : 'Tahmini konum • ${train.source.isNotEmpty ? train.source : 'sefer planı'}',
                      style: TextStyle(
                        color: train.official ? AppTheme.statusLive : const Color(0xFFFCD34D),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),

              // Live disruption notices from Metro İstanbul
              for (final s in statusItems.take(2)) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Color(0xFFFCA5A5), size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.message,
                          style: const TextStyle(color: Color(0xFFFECACA), fontSize: 12, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),

              // Status Banner (⚡ Seyir Halinde | 0.00 m/s²)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: train.statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: train.statusColor.withValues(alpha: 0.35), width: 1.2),
                ),
                child: Row(
                  children: [
                    Text(train.statusIcon, style: const TextStyle(fontSize: 16)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        train.statusTitle,
                        style: TextStyle(color: train.statusColor, fontWeight: FontWeight.w700, fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '${train.currentSpeed.round()} km/s • ${train.accDisplay}',
                        style: TextStyle(color: train.statusColor, fontWeight: FontWeight.w800, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Progress: [prevStation] [43%] [nextStation]
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      train.prevStationName,
                      style: const TextStyle(color: AppTheme.textMutedDark, fontSize: 11, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      train.state == 'AT_STATION' ? 'Kalkışa ${train.dwellRemaining.ceil()} sn' : '${train.remainingMeters.round()} m',
                      style: const TextStyle(color: AppTheme.textLight, fontSize: 12, fontWeight: FontWeight.w800),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      train.targetStationName,
                      style: const TextStyle(color: AppTheme.textMutedDark, fontSize: 11, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              LayoutBuilder(
                builder: (context, constraints) {
                  final fillWidth = train.progress.clamp(0.0, 1.0) * constraints.maxWidth;
                  return Container(
                    height: 6,
                    width: double.infinity,
                    decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(3)),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: fillWidth,
                        height: 6,
                        decoration: BoxDecoration(
                          color: train.color,
                          borderRadius: BorderRadius.circular(3),
                          boxShadow: [BoxShadow(color: train.color.withValues(alpha: 0.6), blurRadius: 4)],
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),

              // Next calls with ticking countdowns
              const Text(
                'Sonraki Duraklar',
                style: TextStyle(color: AppTheme.textLight, fontWeight: FontWeight.w800, fontSize: 14),
              ),
              const SizedBox(height: 8),
              if (train.upcoming.isEmpty)
                const Text(
                  'Son durağa ulaştı.',
                  style: TextStyle(color: AppTheme.textMutedDark, fontSize: 12),
                )
              else
                ...train.upcoming.map((c) => _UpcomingRow(call: c, color: train.color, clock: clock)),
              if (onFollow3D != null) ...[
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: onFollow3D,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.threed_rotation_rounded, color: AppTheme.accentBlack, size: 18),
                        SizedBox(width: 8),
                        Flexible(
                          child: Text('3D Haritada Trenle İlerle',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: AppTheme.accentBlack, fontWeight: FontWeight.w800, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),

              Text(
                '${train.systemType} • ${train.specText}\nİşletmeci: ${_isMarmaray ? 'TCDD Taşımacılık' : 'Metro İstanbul'}',
                style: const TextStyle(color: AppTheme.textMutedDark, fontSize: 11, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpcomingRow extends StatelessWidget {
  final RailStopCall call;
  final Color color;
  final ValueNotifier<int>? clock;

  const _UpcomingRow({required this.call, required this.color, this.clock});

  @override
  Widget build(BuildContext context) {
    Widget countdown() {
      final sec = math.max(0, call.at.difference(DateTime.now()).inSeconds);
      return Text(
        '${BusVehicle.formatEta(sec)} • ${istanbulClock(call.at)}',
        style: const TextStyle(
          color: Color(0xFFFEF08A),
          fontWeight: FontWeight.w800,
          fontSize: 12,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 2.5),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              call.name,
              style: const TextStyle(color: AppTheme.textLight, fontWeight: FontWeight.w600, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (clock != null) ValueListenableBuilder<int>(valueListenable: clock!, builder: (_, _, _) => countdown()) else countdown(),
        ],
      ),
    );
  }
}
