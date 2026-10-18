import 'package:flutter/material.dart';

import '../models/network_models.dart';
import '../services/network_repository.dart';
import '../services/schedule_engine.dart';

/// "← HALKALI 2 dk · · · GEBZE → 1 dk" strip: the previous / this / next station on one line with
/// the scheduled trains moving between them in real time.
class LineStrip extends StatelessWidget {
  final RailLine line;
  final RailStation station;
  final NetworkRepository repo;
  final ScheduleEngine engine;
  final DateTime now;
  final bool compact;

  const LineStrip({
    super.key,
    required this.line,
    required this.station,
    required this.repo,
    required this.engine,
    required this.now,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final main = line.variants.first;
    final i = main.indexOfStation(station.id);
    final deps = engine.departuresAt(station, now).where((d) => d.line.code == line.code).toList();
    DepartureEstimate? dirOf(int d) => deps.where((x) => x.direction == d).firstOrNull;
    final back = dirOf(-1), fwd = dirOf(1);
    final prev = i > 0 ? repo.stations[main.stops[i - 1].stationId] : null;
    final next = (i >= 0 && i < main.stops.length - 1) ? repo.stations[main.stops[i + 1].stationId] : null;

    // window along the main variant (distance metres)
    final dThis = i >= 0 ? main.stops[i].distM : 0.0;
    final dPrev = i > 0 ? main.stops[i - 1].distM : dThis - 1500;
    final dNext = (i >= 0 && i < main.stops.length - 1) ? main.stops[i + 1].distM : dThis + 1500;
    final lo = dPrev - (dThis - dPrev) * 0.35, hi = dNext + (dNext - dThis) * 0.35;
    final mainIdx = {for (var k = 0; k < main.stops.length; k++) main.stops[k].stationId: main.stops[k].distM};

    final dots = <(double, int)>[]; // (0..1 position, direction)
    if (i >= 0) {
      for (final t in engine.trainsAt(now, onlyLine: line.code)) {
        final a = mainIdx[t.fromStationId], b = mainIdx[t.toStationId];
        if (a == null || b == null) continue;
        final along = a + (b - a) * t.segFrac;
        if (along < lo || along > hi) continue;
        final dir = b >= a ? 1 : -1;
        dots.add(((along - lo) / (hi - lo), t.atStation ? (a <= dThis ? 1 : -1) : dir));
      }
    }
    double pos(double d) => ((d - lo) / (hi - lo)).clamp(0.0, 1.0);

    const fg = Colors.white;
    final muted = Colors.white.withValues(alpha: 0.62);
    String eta(DepartureEstimate? d) => d == null ? '—' : formatCountdown(d.at.difference(now));

    return Container(
      padding: EdgeInsets.fromLTRB(14, compact ? 8 : 10, 14, compact ? 8 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFF3A3F47).withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('← ${main.from.toUpperCase()}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
                  Text(eta(back), style: const TextStyle(color: fg, fontSize: 19, fontWeight: FontWeight.w800)),
                ]),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${main.to.toUpperCase()} →',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
                  Text(eta(fwd), style: const TextStyle(color: fg, fontSize: 19, fontWeight: FontWeight.w800)),
                ]),
              ),
            ],
          ),
          SizedBox(
            height: compact ? 44 : 52,
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              return Stack(clipBehavior: Clip.none, children: [
                Positioned(left: 0, right: 0, top: 22, child: Container(height: 2, color: Colors.white24)),
                for (final (d, label) in [
                  if (prev != null) (dPrev, prev.name),
                  (dThis, station.name),
                  if (next != null) (dNext, next.name),
                ]) ...[
                  Positioned(
                    left: pos(d) * w - 1.5,
                    top: 14,
                    child: Container(width: 3, height: 18, decoration: BoxDecoration(color: Colors.white70, borderRadius: BorderRadius.circular(2))),
                  ),
                  Positioned(
                    left: (pos(d) * w - 50).clamp(0.0, w - 100),
                    width: 100,
                    top: 36,
                    child: Text(label,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: d == dThis ? fg : muted, fontSize: 11, fontWeight: d == dThis ? FontWeight.w800 : FontWeight.w600)),
                  ),
                ],
                for (final (p, dir) in dots)
                  Positioned(
                    left: p * w - 13,
                    top: dir > 0 ? 6 : 26,
                    child: Container(
                      width: 26,
                      height: 9,
                      decoration: BoxDecoration(
                        color: line.color,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white, width: 1.4),
                      ),
                    ),
                  ),
                Positioned(
                  left: pos(dThis) * w - 14,
                  top: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: const Color(0xFFF5B301), borderRadius: BorderRadius.circular(5)),
                    child: const Text('Sen', style: TextStyle(color: Color(0xFF111827), fontSize: 9, fontWeight: FontWeight.w900)),
                  ),
                ),
              ]);
            }),
          ),
        ],
      ),
    );
  }
}
