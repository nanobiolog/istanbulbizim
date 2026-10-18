import 'package:flutter/material.dart';

import '../services/transit_provider.dart';
import '../theme/app_theme.dart';

/// Map layers as a simple grid of toggles.
class LayersBottomSheet extends StatelessWidget {
  final TransitProvider provider;
  final VoidCallback onClose;

  const LayersBottomSheet({super.key, required this.provider, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: provider,
      builder: (context, _) {
        final p = provider;
        final tiles = <_LayerTile>[
          _LayerTile(Icons.directions_bus_rounded, 'Otobüsler', '${p.activeBusCount} canlı', p.showBuses, p.toggleBuses),
          _LayerTile(Icons.signpost_rounded, 'Duraklar', 'yakınlaşınca', p.showBusStops, p.toggleBusStops),
          _LayerTile(Icons.subway_rounded, 'Raylı hatlar', '${p.network.lines.length} hat · ${p.network.stations.length} istasyon', p.showMetroLines,
              p.toggleMetroLines),
          _LayerTile(Icons.train_rounded, 'Trenler', '${p.scheduledTrains.length} seyirde', p.showMetroTrains, p.toggleMetroTrains),
          _LayerTile(Icons.directions_boat_filled_rounded, 'Vapurlar', p.hasLiveFerries ? '${p.liveVessels.length} canlı (AIS)' : '${p.scheduledVessels.length} tarifeye göre',
              p.showFerries, p.toggleFerries),
          _LayerTile(Icons.door_front_door_rounded, 'İstasyon girişleri', 'yakınlaşınca', p.showEntrances, p.toggleEntrances),
          _LayerTile(Icons.construction_rounded, 'Projeler', '${p.network.projects.length} inşaat hattı', p.showProjects, p.toggleProjects),
        ];
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
          decoration: const BoxDecoration(
            color: Color(0xFF1C1F24),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Row(children: [
                const Text('Katmanlar', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                const Spacer(),
                GestureDetector(
                  onTap: onClose,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), shape: BoxShape.circle),
                    child: const Icon(Icons.close_rounded, size: 18, color: AppTheme.textMutedDark),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              LayoutBuilder(builder: (context, c) {
                final cols = c.maxWidth > 520 ? 3 : 2;
                final w = (c.maxWidth - (cols - 1) * 10) / cols;
                return Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final t in tiles) SizedBox(width: w, child: t),
                ]);
              }),
              const SizedBox(height: 14),
              Text(
                'Hat geometrisi, istasyon girişleri ve projeler © OpenStreetMap katkıcıları (ODbL) · '
                'vapur hatları, iskeleler ve özel işletme tarifeleri İBB Açık Veri · Şehir Hatları tarifesi sehirhatlari.istanbul · '
                'harita © CARTO · fotoğraflar Wikimedia Commons',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 10.5, height: 1.35),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _LayerTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final bool on;
  final VoidCallback onTap;
  const _LayerTile(this.icon, this.title, this.sub, this.on, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: on ? const Color(0xFF1D4ED8) : const Color(0xFF2A2E35),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: on ? const Color(0xFF60A5FA) : Colors.white10),
        ),
        child: Row(children: [
          Icon(icon, color: on ? Colors.white : const Color(0xFF93C5FD), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: on ? 0.85 : 0.5), fontSize: 11, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
      ),
    );
  }
}
