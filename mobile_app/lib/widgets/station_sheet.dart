import 'package:flutter/material.dart';

import '../models/network_models.dart';
import '../screens/station_walk_screen.dart';
import '../services/schedule_engine.dart';
import '../services/transit_provider.dart';
import '../three_d/station_scene.dart';
import 'vehicle_showcase.dart';
import '../services/app_clock.dart';

/// Bottom sheet for a rail station: header card, layers (plan), live departures, walk / reveal.
class StationSheet extends StatelessWidget {
  final TransitProvider provider;
  final VoidCallback onClose;
  final void Function(LatLngLike target) onFocusMap;

  /// Opens the station view (walking route from your location, 3D route, AR).
  final VoidCallback? onOpenStationView;

  const StationSheet({super.key, required this.provider, required this.onClose, required this.onFocusMap, this.onOpenStationView});

  @override
  Widget build(BuildContext context) {
    final st = provider.selectedStation!;
    final line = provider.selectedStationLine!;
    final plan = provider.selectedStationPlan!;
    final engine = provider.engine;
    final now = AppClock.now();
    final deps = engine?.departuresAt(st, now) ?? const <DepartureEstimate>[];
    final mine = deps.where((d) => d.line.code == line.code).toList()..sort((a, b) => a.direction.compareTo(b.direction));
    final others = deps.where((d) => d.line.code != line.code).toList();
    final reveal = provider.revealStation;
    final lines = provider.network.linesAt(st);
    final maxH = MediaQuery.of(context).size.height * (reveal ? 0.56 : 0.66);

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1F24),
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
            _header(context, st, line, plan, lines),
            const SizedBox(height: 10),
            _architectureCard(plan),
            const SizedBox(height: 10),
            if (reveal) ...[
              _layers(plan),
              const SizedBox(height: 10),
            ],
            if (mine.isNotEmpty)
              Row(children: [
                for (var i = 0; i < mine.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: _departureCard(mine[i], now)),
                ],
              ])
            else
              _note('Bu saatte sefer görünmüyor (tarife: ${line.headwaySource}).'),
            if (others.isNotEmpty) ...[
              const SizedBox(height: 10),
              _otherLines(others, now),
            ],
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _button(
                  icon: Icons.directions_walk_rounded,
                  label: 'İçinde Yürü (3D)',
                  primary: true,
                  onTap: engine == null
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => StationWalkScreen(plan: plan, repo: provider.network, engine: engine),
                          )),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _button(
                  icon: Icons.view_in_ar_rounded,
                  label: reveal ? 'Haritaya Dön' : '3D Kesit Planı',
                  primary: false,
                  onTap: () => provider.toggleReveal(),
                ),
              ),
            ]),
            if (onOpenStationView != null) ...[
              const SizedBox(height: 8),
              _button(icon: Icons.near_me_rounded, label: 'Yol tarifi · AR · resmi saatler', primary: false, onTap: onOpenStationView),
            ],
            const SizedBox(height: 12),
            VehicleShowcase(
              look: VehicleLook.forLine(line),
              photos: provider.network.photos(VehicleLook.forLine(line).mediaKey),
              height: 158,
            ),
            const SizedBox(height: 8),
            Text(
              'Tren konumları ve süreler ${engine?.isOfficial(line.code) == true ? 'Metro İstanbul resmi tarifesine' : (line.headwaySource == 'İBB GTFS' ? 'İBB GTFS sefer sıklığına' : 'tahmini sefer sıklığına')} göre hesaplanır · '
              'derinlik: ${plan.depthSource == 'kaynak' ? 'mühendislik projesi' : (plan.depthSource == 'osm' ? 'OSM kat verisi' : 'tahmini')} · '
              'girişler: © OpenStreetMap',
              style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w500),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _architectureCard(StationPlan plan) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: const Color(0xFF252932),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.architecture_rounded, color: plan.line.color, size: 17),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              plan.architectureTitle,
              style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _chip(plan.island ? 'Ada Peron' : 'Yan Peron', Colors.white.withValues(alpha: 0.10), Colors.white70),
          if (plan.hasPsd) ...[
            const SizedBox(width: 5),
            _chip('PAKS Kapı', const Color(0xFF0284C7).withValues(alpha: 0.28), const Color(0xFF7DD3FC)),
          ],
        ]),
        const SizedBox(height: 5),
        Text(
          plan.architectureSummary,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.68), fontSize: 11.5, height: 1.32, fontWeight: FontWeight.w500),
        ),
      ]),
    );
  }

  Widget _header(BuildContext context, NetworkStation st, RailLine line, StationPlan plan, List<RailLine> lines) {
    final transfers = lines.where((l) => l.code != line.code).toList();
    final depthBig = plan.underground ? '${plan.depth.round()}' : (plan.elevated ? '+${plan.depth.abs().round()}' : '0');
    final depthSub = plan.underground ? 'm derinlik' : (plan.elevated ? 'm viyadük' : 'zemin kat');
    final base = line.color;
    final c1 = Color.lerp(base, Colors.white, 0.08)!, c2 = Color.lerp(base, Colors.black, 0.28)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [c1, c2]),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        boxShadow: [BoxShadow(color: base.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(line.mode.label,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.82), fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
              if (line.mode != RailMode.suburban) ...[
                const SizedBox(width: 6),
                _chip(line.code, Colors.white.withValues(alpha: 0.22), Colors.white),
              ],
            ]),
            const SizedBox(height: 2),
            Text(st.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 27, fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.1)),
            const SizedBox(height: 8),
            if (transfers.isNotEmpty)
              Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Icon(Icons.swap_vert_rounded, color: Colors.white.withValues(alpha: 0.85), size: 17),
                for (final t in transfers)
                  GestureDetector(
                    onTap: () => provider.setStationLine(t.code),
                    child: _chip(t.code == 'B1' ? 'Marmaray' : t.code, Colors.white.withValues(alpha: 0.2), Colors.white, dot: t.color),
                  ),
              ])
            else
              Text(line.longName, style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600)),
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
          const SizedBox(height: 4),
          Text(depthBig, style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w800, height: 1.0)),
          Text(depthSub, style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5, fontWeight: FontWeight.w700)),
        ]),
      ]),
    );
  }

  Widget _layers(StationPlan plan) {
    final layers = plan.layers;
    final focus = provider.revealFocus;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(color: const Color(0xFF2A2E35), borderRadius: BorderRadius.circular(22)),
      child: Column(children: [
        for (var i = 0; i < layers.length; i++)
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () {
              final l = layers[i];
              provider.focusStage(focus == l.stage ? null : l.stage);
              if (l.stage == StationStage.street) {
                final e = plan.station.entrances;
                if (e.isNotEmpty) onFocusMap(LatLngLike(e.first.pos.latitude, e.first.pos.longitude));
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(children: [
                Column(children: [
                  Container(width: 2, height: 6, color: i == 0 ? Colors.transparent : Colors.white24),
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: focus == layers[i].stage ? plan.line.color : const Color(0xFF3B4049),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(layers[i].icon, color: focus == layers[i].stage ? Colors.white : const Color(0xFF93C5FD), size: 16),
                  ),
                  Container(width: 2, height: 6, color: i == layers.length - 1 ? Colors.transparent : Colors.white24),
                ]),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(layers[i].title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                    Text(layers[i].subtitle,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12, fontWeight: FontWeight.w500)),
                  ]),
                ),
                Icon(Icons.my_location_rounded,
                    color: focus == layers[i].stage ? plan.line.color : Colors.white.withValues(alpha: 0.35), size: 19),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _departureCard(DepartureEstimate d, DateTime now) {
    final wait = d.at.difference(now);
    final then = d.then?.difference(d.at);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 12),
      decoration: BoxDecoration(color: const Color(0xFF2A2E35), borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${d.towards} yönü',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(formatCountdown(wait), style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, height: 1.15)),
        Text(then == null ? hhmm(d.at) : 'sonra ${formatCountdown(then)} · ${hhmm(d.at)}',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 11.5, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _otherLines(List<DepartureEstimate> others, DateTime now) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: const Color(0xFF2A2E35), borderRadius: BorderRadius.circular(20)),
      child: Column(children: [
        for (final d in others.take(6))
          InkWell(
            onTap: () => provider.setStationLine(d.line.code),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                _chip(d.line.code == 'B1' ? 'B1' : d.line.code, d.line.color, Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('→ ${d.towards}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
                ),
                Text(formatCountdown(d.at.difference(now)),
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
                if (d.then != null)
                  Text('  · ${formatCountdown(d.then!.difference(now))}',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
      ]),
    );
  }

  static Widget _chip(String text, Color bg, Color fg, {Color? dot}) => Container(
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

  static Widget _note(String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFF2A2E35), borderRadius: BorderRadius.circular(18)),
        child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
      );

  static Widget _button({required IconData icon, required String label, required bool primary, VoidCallback? onTap}) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: primary ? const Color(0xFF1D4ED8) : const Color(0xFF2A2E35),
            borderRadius: BorderRadius.circular(26),
            boxShadow: primary ? [BoxShadow(color: const Color(0xFF1D4ED8).withValues(alpha: 0.4), blurRadius: 14, offset: const Offset(0, 5))] : null,
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: primary ? Colors.white : const Color(0xFF93C5FD), size: 20),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: primary ? Colors.white : const Color(0xFF93C5FD), fontSize: 15.5, fontWeight: FontWeight.w800)),
          ]),
        ),
      );
}

/// Minimal lat/lon carrier so this widget does not depend on the map package.
class LatLngLike {
  final double lat, lon;
  const LatLngLike(this.lat, this.lon);
}
