import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/network_models.dart';
import '../three_d/engine3d.dart';
import '../three_d/scene_views.dart';
import '../three_d/vehicle_models.dart';

/// Which photo set + 3D model represents a vehicle.
class VehicleLook {
  final String mediaKey;
  final VehicleKind kind;
  final Color accent;
  final String title;
  const VehicleLook(this.mediaKey, this.kind, this.accent, this.title);

  static VehicleLook forLine(RailLine line) {
    final c = line.code;
    return switch (line.mode) {
      RailMode.suburban => VehicleLook(
          'marmaray',
          VehicleKind.marmaray,
          line.color,
          c == 'B1' ? 'Marmaray · TCDD E32000 Hyundai Rotem' : '$c Banliyö · TCDD E32000',
        ),
      RailMode.metro => (c == 'M5' || c == 'M7' || c == 'M8' || c == 'M11')
          ? VehicleLook(
              'metro_driverless',
              VehicleKind.metroDriverless,
              line.color,
              c == 'M11' ? '$c · CRRC Sürücüsüz Havalimanı Metrosu' : '$c · Tam Otomatik Sürücüsüz Metro',
            )
          : VehicleLook(
              'metro',
              VehicleKind.metro,
              line.color,
              c == 'M2'
                  ? 'M2 · Hyundai Rotem Metro Dizisi'
                  : (c == 'M4' ? 'M4 · CAF Metro Dizisi' : '$c · Metro İstanbul Raylı Dizi'),
            ),
      RailMode.tram => (c == 'T2' || c == 'T3')
          ? VehicleLook('nostalgic_tram', VehicleKind.nostalgicTram, line.color, '$c · Tarihi Nostaljik Tramvay')
          : VehicleLook(
              'tram',
              VehicleKind.tram,
              line.color,
              c == 'T1' ? 'T1 · Bombardier Flexity / Alstom Citadis' : '$c · Alçak Tabanlı Modern Tramvay',
            ),
      RailMode.funicular => VehicleLook(
          'funicular',
          VehicleKind.funicular,
          line.color,
          c == 'F2' ? 'F2 · Tarihi Karaköy–Beyoğlu Tünel (1875)' : '$c · Eğimli Füniküler Dizisi',
        ),
      RailMode.cable => VehicleLook('cable', VehicleKind.cable, line.color, '$c · Panoramik Teleferik Kabini'),
    };
  }

  static VehicleLook forFerry(FerryOperator? op, FerryLine? line) {
    final name = (line?.name ?? '').toLowerCase();
    if (name.contains('arabalı')) {
      return const VehicleLook('car_ferry', VehicleKind.carFerry, Color(0xFF1E3A8A), 'Arabalı Vapur · Çift Taraflı Ro-Ro');
    }
    return switch (op?.id) {
      'turyol' => VehicleLook('ferry_turyol', VehicleKind.privateFerry, op!.color, 'Turyol · Boğaz Yolcu Motoru'),
      'dentur' => const VehicleLook('ferry_dentur', VehicleKind.privateFerry, Color(0xFF14B8A6), 'Dentur Avrasya · Yolcu Motoru'),
      'ido' => const VehicleLook('ferry_ido', VehicleKind.seaBus, Color(0xFFD61F69), 'İDO · Hızlı Katamaran Deniz Otobüsü'),
      _ => const VehicleLook('ferry_sh', VehicleKind.ferry, Color(0xFF0B5CAD), 'Şehir Hatları · Klasik Boğaz Vapuru'),
    };
  }

  static VehicleLook bus(String line) => line.startsWith('34')
      ? const VehicleLook('metrobus', VehicleKind.metrobus, Color(0xFFE11D48), 'Metrobüs · Körüklü BRT Otobüsü')
      : const VehicleLook('bus', VehicleKind.bus, Color(0xFFF4C430), 'İETT · Alçak Tabanlı Şehir Otobüsü');
}

/// Interactive 3D vehicle model ↔ Wikimedia Commons photo carousel.
class VehicleShowcase extends StatefulWidget {
  final VehicleLook look;
  final List<VehiclePhoto> photos;
  final double height;
  const VehicleShowcase({super.key, required this.look, required this.photos, this.height = 172});

  @override
  State<VehicleShowcase> createState() => _VehicleShowcaseState();
}

class _VehicleShowcaseState extends State<VehicleShowcase> {
  bool _show3d = true;
  int _page = 0;

  Mesh get _mesh => VehicleModels.build(widget.look.kind, accent: widget.look.accent, cars: switch (widget.look.kind) {
        VehicleKind.marmaray || VehicleKind.metro || VehicleKind.metroDriverless => 2,
        VehicleKind.tram => 3,
        _ => 0,
      });

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    final photo = photos.isEmpty ? null : photos[_page.clamp(0, photos.length - 1)];
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: const Color(0xFF0B1324),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Stack(children: [
          Positioned.fill(
            child: _show3d || photos.isEmpty
                ? ModelViewer3D(mesh: _mesh, kind: widget.look.kind, height: widget.height)
                : PageView.builder(
                    itemCount: photos.length,
                    onPageChanged: (i) => setState(() => _page = i),
                    itemBuilder: (_, i) => Image.network(
                      photos[i].url,
                      fit: BoxFit.cover,
                      webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                      loadingBuilder: (c, child, prog) => prog == null
                          ? child
                          : const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
                      errorBuilder: (_, _, _) => ModelViewer3D(mesh: _mesh, kind: widget.look.kind, height: widget.height),
                    ),
                  ),
          ),
          // bottom gradient + title + credit
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: _show3d || photo == null,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 24, 12, 9),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0xD8040814)]),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(widget.look.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
                      if (!_show3d && photo != null)
                        GestureDetector(
                          onTap: () => launchUrl(Uri.parse(photo.page), mode: LaunchMode.externalApplication),
                          child: Text('📷 ${photo.credit}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 9.5, fontWeight: FontWeight.w500)),
                        )
                      else
                        const Text('Etkileşimli 3D model · döndürmek için sürükleyin',
                            style: TextStyle(color: Color(0xFF93C5FD), fontSize: 10, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                  if (!_show3d && photos.length > 1)
                    Row(children: [
                      for (var i = 0; i < photos.length; i++)
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(left: 4),
                          decoration: BoxDecoration(shape: BoxShape.circle, color: i == _page ? Colors.white : Colors.white38),
                        ),
                    ]),
                ]),
              ),
            ),
          ),
          // 3D / Foto toggle
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              padding: const EdgeInsets.all(3),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _seg('3D Model', _show3d, () => setState(() => _show3d = true)),
                if (photos.isNotEmpty) _seg('Fotoğraf', !_show3d, () => setState(() => _show3d = false)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _seg(String label, bool on, VoidCallback tap) => GestureDetector(
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(color: on ? const Color(0xFF38BDF8) : Colors.transparent, borderRadius: BorderRadius.circular(13)),
          child: Text(label, style: TextStyle(color: on ? const Color(0xFF090D16) : Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
        ),
      );
}
