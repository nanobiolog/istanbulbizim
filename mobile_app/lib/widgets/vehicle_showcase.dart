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
      RailMode.suburban => VehicleLook('marmaray', VehicleKind.marmaray, line.color, 'TCDD E32000 · Hyundai Rotem'),
      RailMode.metro => (c == 'M5' || c == 'M8' || c == 'M11')
          ? VehicleLook('metro_driverless', VehicleKind.metro, line.color, 'Sürücüsüz metro dizisi')
          : VehicleLook('metro', VehicleKind.metro, line.color, '$c metro dizisi'),
      RailMode.tram => (c == 'T2' || c == 'T3')
          ? VehicleLook('nostalgic_tram', VehicleKind.nostalgicTram, line.color, 'Nostaljik tramvay')
          : VehicleLook('tram', VehicleKind.tram, line.color, 'Alstom Citadis tramvay'),
      RailMode.funicular => VehicleLook('funicular', VehicleKind.funicular, line.color, 'Füniküler'),
      RailMode.cable => VehicleLook('cable', VehicleKind.cable, line.color, 'Teleferik kabini'),
    };
  }

  static VehicleLook forFerry(FerryOperator? op, FerryLine? line) {
    final name = (line?.name ?? '').toLowerCase();
    if (name.contains('arabalı')) return const VehicleLook('car_ferry', VehicleKind.carFerry, Color(0xFF1E3A8A), 'Arabalı vapur');
    return switch (op?.id) {
      'turyol' => VehicleLook('ferry_turyol', VehicleKind.privateFerry, op!.color, 'Turyol motoru'),
      'dentur' => const VehicleLook('ferry_dentur', VehicleKind.privateFerry, Color(0xFF14B8A6), 'Dentur Avrasya motoru'),
      'ido' => const VehicleLook('ferry_ido', VehicleKind.seaBus, Color(0xFF0EA5E9), 'İDO deniz otobüsü'),
      _ => const VehicleLook('ferry_sh', VehicleKind.ferry, Color(0xFF0B5CAD), 'Şehir Hatları vapuru'),
    };
  }

  static VehicleLook bus(String line) => line.startsWith('34')
      ? const VehicleLook('metrobus', VehicleKind.metrobus, Color(0xFFE11D48), 'Metrobüs · Mercedes CapaCity')
      : const VehicleLook('bus', VehicleKind.bus, Color(0xFFF4C430), 'İETT otobüsü');
}

/// Photo carousel (Wikimedia Commons, with credit) ↔ rotatable 3D model.
class VehicleShowcase extends StatefulWidget {
  final VehicleLook look;
  final List<VehiclePhoto> photos;
  final double height;
  const VehicleShowcase({super.key, required this.look, required this.photos, this.height = 168});

  @override
  State<VehicleShowcase> createState() => _VehicleShowcaseState();
}

class _VehicleShowcaseState extends State<VehicleShowcase> {
  bool _show3d = false;
  int _page = 0;

  Mesh get _mesh => VehicleModels.build(widget.look.kind, accent: widget.look.accent, cars: switch (widget.look.kind) {
        VehicleKind.marmaray || VehicleKind.metro => 2,
        VehicleKind.tram => 3,
        _ => 0,
      });

  @override
  void initState() {
    super.initState();
    _show3d = widget.photos.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    final photo = photos.isEmpty ? null : photos[_page.clamp(0, photos.length - 1)];
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: widget.height,
        color: const Color(0xFF0F172A),
        child: Stack(children: [
          Positioned.fill(
            child: _show3d
                ? ModelViewer3D(mesh: _mesh, height: widget.height)
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
                      errorBuilder: (_, _, _) => ModelViewer3D(mesh: _mesh, height: widget.height),
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
                padding: const EdgeInsets.fromLTRB(12, 26, 12, 9),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0xCC000000)]),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(widget.look.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
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
                        const Text('3D model · sürükleyip çevir',
                            style: TextStyle(color: Colors.white70, fontSize: 9.5, fontWeight: FontWeight.w500)),
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
          // photo / 3D toggle
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(16)),
              padding: const EdgeInsets.all(3),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (photos.isNotEmpty) _seg('Foto', !_show3d, () => setState(() => _show3d = false)),
                _seg('3D', _show3d, () => setState(() => _show3d = true)),
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
          decoration: BoxDecoration(color: on ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(13)),
          child: Text(label, style: TextStyle(color: on ? const Color(0xFF0F172A) : Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800)),
        ),
      );
}
