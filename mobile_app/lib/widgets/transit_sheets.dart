import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/network_models.dart';
import '../services/schedule_engine.dart';
import '../services/transit_provider.dart';
import 'vehicle_showcase.dart';
import '../services/app_clock.dart';

const _sheetBg = Color(0xFF1C1F24);
const _card = Color(0xFF2A2E35);

class _SheetFrame extends StatelessWidget {
  final List<Widget> children;
  final double maxFraction;
  const _SheetFrame({required this.children, this.maxFraction = 0.64});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * maxFraction),
      decoration: const BoxDecoration(
        color: _sheetBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, -6))],
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            ...children,
          ]),
        ),
      ),
    );
  }
}

Widget _headerCard({
  required Color color,
  required String kicker,
  required String title,
  String? subtitle,
  Widget? trailing,
  List<Widget> chips = const [],
  required VoidCallback onClose,
  IconData? icon,
}) {
  final c1 = Color.lerp(color, Colors.white, 0.06)!, c2 = Color.lerp(color, Colors.black, 0.3)!;
  return Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [c1, c2]),
      border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.32), blurRadius: 18, offset: const Offset(0, 6))],
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (icon != null) ...[Icon(icon, color: Colors.white70, size: 14), const SizedBox(width: 5)],
            Flexible(
              child: Text(kicker,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.82), fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
            ),
          ]),
          const SizedBox(height: 2),
          Text(title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.4, height: 1.12)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(color: Colors.white.withValues(alpha: 0.82), fontSize: 12.5, fontWeight: FontWeight.w600)),
          ],
          if (chips.isNotEmpty) ...[const SizedBox(height: 8), Wrap(spacing: 6, runSpacing: 6, children: chips)],
        ]),
      ),
      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        GestureDetector(
          onTap: onClose,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
            child: const Icon(Icons.close_rounded, color: Colors.white, size: 18),
          ),
        ),
        ?trailing,
      ]),
    ]),
  );
}

Widget _chip(String text, Color bg, {Color fg = Colors.white, Color? dot}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot != null) ...[
          Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 5),
        ],
        Text(text, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w800)),
      ]),
    );

Widget _bigStat(String value, String label) => Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, height: 1.0)),
      Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11, fontWeight: FontWeight.w700)),
    ]);

// ───────────────────────── pier ─────────────────────────

class PierSheet extends StatefulWidget {
  final TransitProvider provider;
  final VoidCallback onClose;
  const PierSheet({super.key, required this.provider, required this.onClose});

  @override
  State<PierSheet> createState() => _PierSheetState();
}

class _PierSheetState extends State<PierSheet> {
  String? _openLine;

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final pier = p.selectedPier!;
    final net = p.network;
    final now = AppClock.now();
    final deps = p.engine?.pierDepartures(pier.id, now, limit: 10) ?? const <PierDeparture>[];
    final ops = pier.operators.map((o) => net.operators[o]).whereType<FerryOperator>().toList();
    final primary = ops.isNotEmpty ? ops.first : null;
    final lines = net.ferryLines.where((l) => l.piers.contains(pier.id)).toList();
    final look = VehicleLook.forFerry(primary, null);
    return _SheetFrame(children: [
      _headerCard(
        color: primary?.color ?? const Color(0xFF0B5CAD),
        kicker: primary?.municipal == true ? 'İSKELE · İBB' : 'İSKELE',
        icon: Icons.anchor_rounded,
        title: pier.name,
        chips: [for (final o in ops) _chip(o.name, Colors.white.withValues(alpha: 0.2), dot: o.color)],
        trailing: deps.isEmpty ? null : _bigStat(formatCountdown(deps.first.at.difference(now)).replaceAll(' ', '\n'), 'sıradaki'),
        onClose: widget.onClose,
      ),
      const SizedBox(height: 10),
      if (lines.isEmpty)
        _note('Bu iskele için yayımlanmış düzenli sefer tarifesi yok${ops.isNotEmpty && !ops.first.municipal ? ' (${ops.first.name})' : ''}.')
      else if (deps.isEmpty)
        _note('Bugün bu iskeleden kalan sefer yok.')
      else
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(20)),
          child: Column(children: [
            for (final d in deps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(color: net.operators[d.line.operatorId]?.color ?? Colors.blue, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('→ ${net.piers[d.destination]?.name ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                      Text('${net.operators[d.line.operatorId]?.short ?? ''} · ${d.line.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11.5, fontWeight: FontWeight.w500)),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(formatCountdown(d.at.difference(now)),
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
                    Text(hhmm(d.at), style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11.5, fontWeight: FontWeight.w600)),
                  ]),
                ]),
              ),
          ]),
        ),
      const SizedBox(height: 10),
      // full timetables per line
      Container(
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(20)),
        child: Column(children: [
          for (final l in lines)
            Column(children: [
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => setState(() => _openLine = _openLine == l.id ? null : l.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    const Icon(Icons.schedule_rounded, color: Color(0xFF93C5FD), size: 17),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w700)),
                        Text('${net.operators[l.operatorId]?.name ?? ''} · ${l.source}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11, fontWeight: FontWeight.w500)),
                      ]),
                    ),
                    Icon(_openLine == l.id ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: Colors.white54),
                  ]),
                ),
              ),
              if (_openLine == l.id) _timetable(l, pier, now),
            ]),
        ]),
      ),
      const SizedBox(height: 12),
      VehicleShowcase(look: look, photos: net.photos(look.mediaKey), height: 150),
      const SizedBox(height: 8),
      _liveNote(p),
    ]);
  }

  Widget _timetable(FerryLine l, Pier pier, DateTime now) {
    final rows = widget.provider.engine?.lineTimetableAt(l, pier.id, now) ?? const [];
    final net = widget.provider.network;
    if (rows.isEmpty) return Padding(padding: const EdgeInsets.all(12), child: _note('Bugün sefer yok.'));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (t, trip, _) in rows)
          Tooltip(
            message: '→ ${net.piers[trip.piers.last]?.name ?? ''}${trip.note.isNotEmpty ? '\n${trip.note}' : ''}',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: t.isBefore(now) ? Colors.white.withValues(alpha: 0.04) : const Color(0xFF1D4ED8).withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(hhmm(t),
                  style: TextStyle(
                      color: t.isBefore(now) ? Colors.white30 : Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ),
      ]),
    );
  }
}

Widget _liveNote(TransitProvider p) {
  final live = p.hasLiveFerries;
  return Row(children: [
    Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: live ? const Color(0xFF22C55E) : const Color(0xFFF59E0B), shape: BoxShape.circle),
    ),
    const SizedBox(width: 6),
    Expanded(
      child: Text(
        live
            ? 'Canlı AIS konumları açık (${p.liveVessels.length} gemi) · tarifeler: Şehir Hatları / İBB GTFS'
            : (p.aisConfigured
                ? 'AIS bağlı, şu an veri yok · gemiler tarifeye göre gösteriliyor'
                : 'Gemiler tarifeye göre gösteriliyor (canlı AIS için Worker\'a AISSTREAM_API_KEY ekleyin)'),
        style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w500),
      ),
    ),
  ]);
}

Widget _note(String text) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(18)),
      child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
    );

// ───────────────────────── vessel ─────────────────────────

class VesselSheet extends StatelessWidget {
  final TransitProvider provider;
  final VoidCallback onClose;
  final void Function(Pier) onOpenPier;
  const VesselSheet({super.key, required this.provider, required this.onClose, required this.onOpenPier});

  @override
  Widget build(BuildContext context) {
    final v = provider.selectedVessel;
    if (v == null) {
      return _SheetFrame(children: [
        _headerCard(color: const Color(0xFF0B5CAD), kicker: 'VAPUR', title: 'Sefer tamamlandı', onClose: onClose),
      ]);
    }
    final net = provider.network;
    final now = AppClock.now();
    final midnight = DateTime(now.year, now.month, now.day);
    final next = net.piers[v.trip.piers[v.toIdx]];
    final look = VehicleLook.forFerry(v.op, v.line);
    final status = v.docked
        ? (v.fromIdx == 0 && v.etaSec > 0 ? 'İskelede · kalkışa ${formatCountdown(Duration(seconds: v.etaSec.round()))}' : 'İskelede')
        : 'Seyirde · ${next?.name ?? ''} ${formatCountdown(Duration(seconds: v.etaSec.round()))}';
    return _SheetFrame(children: [
      _headerCard(
        color: v.op?.color ?? const Color(0xFF0B5CAD),
        kicker: '${v.op?.name.toUpperCase() ?? 'VAPUR'} · TARİFEYE GÖRE',
        icon: Icons.directions_boat_filled_rounded,
        title: '→ ${net.piers[v.trip.piers.last]?.name ?? ''}',
        subtitle: status,
        trailing: v.docked ? null : _bigStat(v.speedKn.toStringAsFixed(0), 'knot'),
        onClose: onClose,
      ),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(20)),
        child: Column(children: [
          for (var i = 0; i < v.trip.piers.length; i++)
            InkWell(
              onTap: () {
                final pr = net.piers[v.trip.piers[i]];
                if (pr != null) onOpenPier(pr);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Icon(
                    i < v.toIdx || (v.docked && i <= v.fromIdx && v.fromIdx > 0)
                        ? Icons.check_circle_rounded
                        : (i == v.toIdx ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
                    size: 17,
                    color: i == v.toIdx ? (v.op?.color ?? Colors.blue) : Colors.white38,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(net.piers[v.trip.piers[i]]?.name ?? '',
                        style: TextStyle(
                            color: i < v.toIdx ? Colors.white54 : Colors.white,
                            fontSize: 14,
                            fontWeight: i == v.toIdx ? FontWeight.w800 : FontWeight.w600)),
                  ),
                  Text(hhmm(midnight.add(Duration(minutes: v.trip.minutes[i]))),
                      style: TextStyle(color: i < v.toIdx ? Colors.white38 : Colors.white, fontSize: 13.5, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      VehicleShowcase(look: look, photos: net.photos(look.mediaKey), height: 150),
      const SizedBox(height: 8),
      Text('${v.line.name} · ${v.line.source}', style: const TextStyle(color: Colors.white38, fontSize: 10)),
      const SizedBox(height: 4),
      _liveNote(provider),
    ]);
  }
}

// ───────────────────────── live AIS vessel ─────────────────────────

class LiveVesselSheet extends StatelessWidget {
  final LiveVessel vessel;
  final TransitProvider provider;
  final VoidCallback onClose;
  const LiveVesselSheet({super.key, required this.vessel, required this.provider, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final op = provider.network.operators[vessel.operatorId];
    final look = VehicleLook.forFerry(op, null);
    return _SheetFrame(children: [
      _headerCard(
        color: op?.color ?? const Color(0xFF0B5CAD),
        kicker: '${op?.name.toUpperCase() ?? 'GEMİ'} · CANLI AIS',
        icon: Icons.sensors_rounded,
        title: vessel.name.isEmpty ? 'MMSI ${vessel.mmsi}' : vessel.name,
        subtitle: '${vessel.sog.toStringAsFixed(1)} knot · rota ${vessel.cog.round()}° · ${vessel.ageSec} sn önce',
        onClose: onClose,
      ),
      const SizedBox(height: 12),
      VehicleShowcase(look: look, photos: provider.network.photos(look.mediaKey), height: 150),
    ]);
  }
}

// ───────────────────────── train ─────────────────────────

class TrainSheet extends StatelessWidget {
  final TransitProvider provider;
  final VoidCallback onClose;
  final void Function(NetworkStation) onOpenStation;
  final VoidCallback? onFollow3D;
  const TrainSheet({super.key, required this.provider, required this.onClose, required this.onOpenStation, this.onFollow3D});

  @override
  Widget build(BuildContext context) {
    final t = provider.selectedTrain;
    if (t == null) {
      return _SheetFrame(children: [
        _headerCard(color: const Color(0xFF334155), kicker: 'TREN', title: 'Sefer tamamlandı', onClose: onClose),
      ]);
    }
    final net = provider.network;
    final next = net.stations[t.toStationId];
    final look = VehicleLook.forLine(t.line);
    final eta = Duration(seconds: t.etaSec.round());
    final upcoming = <(NetworkStation, Duration)>[];
    var acc = t.etaSec;
    for (var i = t.toIdx; i < t.variant.stops.length && upcoming.length < 5; i++) {
      final st = net.stations[t.variant.stops[i].stationId];
      if (st == null) continue;
      if (i > t.toIdx) {
        final d = t.variant.stops[i].distM - t.variant.stops[i - 1].distM;
        acc += d / (t.line.speedKmh / 3.6) * 1.18 + t.line.dwellS;
      }
      upcoming.add((st, Duration(seconds: acc.round())));
    }
    return _SheetFrame(children: [
      _headerCard(
        color: t.line.color,
        kicker: '${t.line.mode.label} · ${t.line.code} · ${provider.engine?.isOfficial(t.line.code) == true ? 'RESMİ TARİFE' : 'TARİFEYE GÖRE'}',
        icon: t.line.mode.icon,
        title: '→ ${t.variant.to}',
        subtitle: t.atStation ? '${next?.name ?? ''} istasyonunda · kalkışa ${formatCountdown(eta)}' : '${t.state.label} · ${next?.name ?? ''} ${formatCountdown(eta)}',
        trailing: _bigStat('${t.speedKmh.round()}', 'km/s'),
        onClose: onClose,
      ),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(20)),
        child: Column(children: [
          for (final (st, d) in upcoming)
            InkWell(
              onTap: () => onOpenStation(st),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: t.line.color, width: 3)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(st.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                  if (st.lines.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Row(children: [
                        for (final c in st.lines.where((c) => c != t.line.code).take(3))
                          Container(
                            margin: const EdgeInsets.only(left: 3),
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                                color: net.lineByCode[c]?.color ?? Colors.grey, borderRadius: BorderRadius.circular(6)),
                            child: Text(c, style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w800)),
                          ),
                      ]),
                    ),
                  Text(formatCountdown(d), style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _metric('İvme', '${t.line.mode.accel.toStringAsFixed(2)} m/s²')),
        const SizedBox(width: 8),
        Expanded(child: _metric('Fren', '${t.line.mode.decel.toStringAsFixed(2)} m/s²')),
        const SizedBox(width: 8),
        Expanded(child: _metric('Sıradaki', '${math.max(0, t.distanceToNextM).round()} m')),
      ]),
      if (onFollow3D != null) ...[
        const SizedBox(height: 10),
        GestureDetector(
          onTap: onFollow3D,
          child: Container(
            height: 48,
            decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(24)),
            child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.location_city_rounded, color: Color(0xFF93C5FD), size: 19),
              SizedBox(width: 8),
              Text("3D'de trenle ilerle", style: TextStyle(color: Color(0xFF93C5FD), fontSize: 15, fontWeight: FontWeight.w800)),
            ]),
          ),
        ),
      ],
      const SizedBox(height: 12),
      VehicleShowcase(look: look, photos: net.photos(look.mediaKey), height: 150),
      const SizedBox(height: 8),
      Text('${t.line.code} ${t.line.longName} · ${t.line.operator} · konum ${t.line.headwaySource} sefer sıklığından hesaplanır',
          style: const TextStyle(color: Colors.white38, fontSize: 10)),
    ]);
  }

  Widget _metric(String k, String v) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: const TextStyle(color: Colors.white54, fontSize: 10.5, fontWeight: FontWeight.w600)),
          Text(v, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
        ]),
      );
}

// ───────────────────────── rail line ─────────────────────────

class RailLineSheet extends StatelessWidget {
  final TransitProvider provider;
  final VoidCallback onClose;
  final void Function(NetworkStation) onOpenStation;
  const RailLineSheet({super.key, required this.provider, required this.onClose, required this.onOpenStation});

  @override
  Widget build(BuildContext context) {
    final line = provider.selectedRailLine!;
    final net = provider.network;
    final main = line.variants.first;
    final now = AppClock.now();
    final minute = now.hour * 60 + now.minute;
    final hw = line.headways.where((h) => minute >= h.startMin && minute < h.endMin).firstOrNull;
    final running = provider.scheduledTrains.where((t) => t.line.code == line.code).length;
    final look = VehicleLook.forLine(line);
    return _SheetFrame(maxFraction: 0.6, children: [
      _headerCard(
        color: line.color,
        kicker: '${line.mode.label} · ${line.operator.toUpperCase()}',
        icon: line.mode.icon,
        title: line.code == 'B1' ? 'Marmaray' : '${line.code}  ${main.from} – ${main.to}',
        subtitle: '${line.code == 'B1' ? '${main.from} – ${main.to} · ' : ''}${(main.path.length / 1000).toStringAsFixed(1)} km · ${main.stops.length} istasyon',
        trailing: _bigStat(hw == null ? '—' : '${(hw.seconds / 60).round()}', hw == null ? 'sefer yok' : 'dk aralık'),
        onClose: onClose,
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _pill(Icons.train_rounded, '$running tren seyirde')),
        const SizedBox(width: 8),
        Expanded(child: _pill(Icons.schedule_rounded, provider.engine?.isOfficial(line.code) == true ? 'Resmi tarife' : 'Kaynak: ${line.headwaySource}')),
      ]),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(20)),
        child: Column(children: [
          for (var i = 0; i < main.stops.length; i++)
            if (net.stations[main.stops[i].stationId] case final st?)
              InkWell(
                onTap: () => onOpenStation(st),
                child: SizedBox(
                  height: 38,
                  child: Row(children: [
                    SizedBox(
                      width: 18,
                      child: Column(children: [
                        Expanded(child: Container(width: 4, color: i == 0 ? Colors.transparent : line.color)),
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                              color: Colors.white, shape: BoxShape.circle, border: Border.all(color: line.color, width: 3)),
                        ),
                        Expanded(child: Container(width: 4, color: i == main.stops.length - 1 ? Colors.transparent : line.color)),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(st.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                    for (final c in st.lines.where((c) => c != line.code).take(4))
                      Container(
                        margin: const EdgeInsets.only(left: 3),
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(color: net.lineByCode[c]?.color ?? Colors.grey, borderRadius: BorderRadius.circular(6)),
                        child: Text(c, style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w800)),
                      ),
                    if (st.kindFor(line.code) == StationKind.underground)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text('−${st.depthFor(line.code).round()} m',
                            style: const TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w700)),
                      ),
                  ]),
                ),
              ),
        ]),
      ),
      const SizedBox(height: 12),
      VehicleShowcase(look: look, photos: net.photos(look.mediaKey), height: 150),
    ]);
  }

  Widget _pill(IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Icon(icon, color: const Color(0xFF93C5FD), size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ]),
      );
}
