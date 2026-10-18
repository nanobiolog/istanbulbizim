import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/network_models.dart';
import 'engine3d.dart';
import 'vehicle_models.dart';

/// Vertical layers of a station, top to bottom — the same list the station sheet shows.
enum StationStage { street, passage, security, gates, escalators, platform }

extension StationStageText on StationStage {
  String get label => switch (this) {
        StationStage.street => 'Sokak',
        StationStage.passage => 'Geçit',
        StationStage.security => 'Güvenlik',
        StationStage.gates => 'Turnike',
        StationStage.escalators => 'Merdiven',
        StationStage.platform => 'Peron',
      };

  IconData get icon => switch (this) {
        StationStage.street => Icons.directions_walk_rounded,
        StationStage.passage => Icons.south_east_rounded,
        StationStage.security => Icons.shield_outlined,
        StationStage.gates => Icons.credit_card_rounded,
        StationStage.escalators => Icons.stairs_rounded,
        StationStage.platform => Icons.directions_subway_filled_rounded,
      };
}

/// Real-world architectural / civil-engineering archetype of an Istanbul station.
enum StationArchetype {
  /// Deep NATM bored twin circular platform tunnels connected by cross-passages
  /// (e.g. Sirkeci B1 -60m, Gayrettepe M11 -72m, Yıldız M7 -71m, Şişhane M2 -45m, Mecidiyeköy M7 -47m, Boğaziçi Üniv. M6 -35m).
  deepCavernTubes,

  /// Iconic Haliç M2 cable-stayed metro bridge over the Golden Horn (+13m over water, inclined pylons & stay cables).
  goldenHornBridge,

  /// Waterfront cut-and-cover hub beside Bosphorus / Golden Horn with glass skylights & promenade
  /// (e.g. Üsküdar B1/M5, Kabataş T1/F1, Kadıköy M4, Eminönü, Karaköy).
  waterfrontCutAndCover,

  /// Monumental multi-line cut-and-cover transfer hub with overlooking mezzanine gallery, grand columns & skylights
  /// (e.g. Yenikapı B1/M1/M2, Ayrılık Çeşmesi B1/M4, Taksim M2/F1, Levent M2/M6, Mecidiyeköy M2, Bakırköy-İncirli, Kirazlı, Mahmutbey).
  monumentalTransferHub,

  /// Elevated concrete viaduct station on flared hammerhead piers with arched steel-and-glass rib canopy
  /// (e.g. Kağıthane M7, Alibeyköy M7, Söğütlüçeşme B1, Seyrantepe, Davutpaşa, Merter, Otogar, Bahariye).
  viaductElevated,

  /// Modernized TCDD Marmaray surface commuter station with overhead pedestrian footbridge (üstgeçit) & catenary portals
  /// (e.g. Bakırköy, Bostancı, Göztepe, Erenköy, Suadiye, Maltepe, Kartal, Pendik, Gebze, Florya, Yeşilköy, Kazlıçeşme, Halkalı).
  marmaraySurface,

  /// Historic / sloped funicular tunnel (F1, F2 Tarihi Tünel 1875, F4) or aerial ropeway terminal (TF1, TF2).
  slopedFunicularOrCable,

  /// Modern cut-and-cover / top-down metro station with line-specific architectural cladding & PSDs on driverless lines.
  modernUnderground,
}

/// One row of the "layers" list (Street → Gates & security → Escalators → Platforms).
class PlanLayer {
  final StationStage stage;
  final String title;
  final String subtitle;
  final IconData icon;
  final double y; // level height (m, + up)
  final double x; // focus point along the station
  const PlanLayer(this.stage, this.title, this.subtitle, this.icon, this.y, this.x);
}

/// Real OSM entrance projected into the station's local 3D coordinate system (metres).
class ProjectedEntrance {
  final String label;
  final double dx; // along track
  final double dz; // across track
  final bool wheelchair;
  const ProjectedEntrance({required this.label, required this.dx, required this.dz, required this.wheelchair});
}

/// Published engineering overrides for landmark Istanbul stations (depth in m, platform type, archetype).
class _StationEngineeringOverride {
  final double? depth;
  final bool? island;
  final StationArchetype archetype;
  final String title;
  final String summary;
  const _StationEngineeringOverride({
    this.depth,
    this.island,
    required this.archetype,
    required this.title,
    required this.summary,
  });
}

/// Geometry and real architectural metadata of one station for one line.
class StationPlan {
  final NetworkStation station;
  final RailLine line;
  late final StationKind kind;
  late final double depth; // platform depth below street (m); negative = elevated
  late final String depthSource;
  late final StationArchetype archetype;
  late final String architectureTitle;
  late final String architectureSummary;
  late final bool island;
  late final double trackBearingDeg;
  late final List<ProjectedEntrance> projectedEntrances;

  StationPlan(this.station, this.line) {
    final folded = _foldName(station.name);
    final ov = _lookupOverride(line.code, folded, station);
    final rawKind = station.kindFor(line.code);
    if (ov?.depth != null) {
      depth = ov!.depth!;
      kind = depth > 1 ? StationKind.underground : (depth < -1 ? StationKind.elevated : StationKind.surface);
      depthSource = 'kaynak';
    } else {
      kind = rawKind;
      depth = station.depthFor(line.code);
      depthSource = station.depthSourceFor(line.code);
    }

    island = ov?.island ?? _inferIslandPlatform(line.code, folded, station);
    archetype = ov?.archetype ?? _inferArchetype(line, kind, depth, folded, station);
    architectureTitle = ov?.title ?? _defaultArchTitle(archetype, line);
    architectureSummary = ov?.summary ?? _defaultArchSummary(archetype, line, station);
    trackBearingDeg = _computeTrackBearing(station, line);
    projectedEntrances = _projectEntrances(station, trackBearingDeg);
  }

  static String _foldName(String s) {
    return s
        .replaceAll('İ', 'i')
        .replaceAll('I', 'ı')
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ş', 's')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }

  static _StationEngineeringOverride? _lookupOverride(String code, String name, NetworkStation st) {
    // 1. Haliç Golden Horn Cable-Stayed Metro Bridge
    if (name == 'halic' && code == 'M2') {
      return const _StationEngineeringOverride(
        depth: -13,
        island: false,
        archetype: StationArchetype.goldenHornBridge,
        title: 'Haliç Metro Köprüsü · Eğik Askılı Köprü İstasyonu',
        summary: 'Haliç üzerinde +13 m kotunda, iki eğik çelik pilon ve askı kablolarıyla taşınan 180 m yan peronlu köprü istasyonu.',
      );
    }
    // 2. Sirkeci Marmaray Deep NATM Twin Bored Caverns
    if (name.contains('sirkeci') && code == 'B1') {
      return const _StationEngineeringOverride(
        depth: 60,
        island: false,
        archetype: StationArchetype.deepCavernTubes,
        title: 'NATM Derin Çift Tüp Tünel · −60 m',
        summary: 'Tarihi Yarımada altında −60 m derinlikte açılmış iki paralel dairesel peron tüneli, 4 bağlantı tüneli ile Cağaloğlu ve Gar girişlerine bağlanır.',
      );
    }
    // 3. Gayrettepe M11 (Deepest station in Istanbul - 72m) & M2
    if (name.contains('gayrettepe')) {
      if (code == 'M11') {
        return const _StationEngineeringOverride(
          depth: 72,
          island: true,
          archetype: StationArchetype.deepCavernTubes,
          title: 'İstanbul’un En Derin İstasyonu · −72 m NATM Tünel',
          summary: '−72 m derinlikte 6 yeraltı katlı havalimanı metro merkezi; tam boy peron ayırıcı kapılar (PAKS) ve M2/Metrobüs entegrasyon tünelleri.',
        );
      }
      return const _StationEngineeringOverride(
        depth: 28,
        island: true,
        archetype: StationArchetype.monumentalTransferHub,
        title: 'Aç-Kapa Aktarma Merkezi · −28 m',
        summary: 'Büyükdere Caddesi altında geniş kolonlu konkors, M11 havalimanı metrosu ve Zincirlikuyu Metrobüs yaya tüneli bağlantısı.',
      );
    }
    // 4. Yıldız M7 (-71m deep NATM twin caverns)
    if (name == 'yildiz' && code == 'M7') {
      return const _StationEngineeringOverride(
        depth: 71,
        island: false,
        archetype: StationArchetype.deepCavernTubes,
        title: 'Derin Şaft & Çift Tüp NATM İstasyonu · −71 m',
        summary: 'Beşiktaş–Barbaros sırtında −71 m derinlikte kademeli yürüyen merdiven şaftları ve PAKS kapılı ikiz tünel peronlar.',
      );
    }
    // 5. Üsküdar Waterfront Plaza (B1 Marmaray & M5 Driverless)
    if (name == 'uskudar') {
      if (code == 'B1') {
        return const _StationEngineeringOverride(
          depth: 30,
          island: true,
          archetype: StationArchetype.waterfrontCutAndCover,
          title: 'Boğaz Kıyısı Aç-Kapa Diyafram Duvar · −30 m',
          summary: 'Üsküdar Meydanı ve Boğaz kıyısında cam ışıklıklı geniş konkors, 225 m ada peron ve M5 / Şehir Hatları iskele entegrasyonu.',
        );
      }
      if (code == 'M5') {
        return const _StationEngineeringOverride(
          depth: 40,
          island: true,
          archetype: StationArchetype.waterfrontCutAndCover,
          title: 'Sürücüsüz Metro Kıyı Aktarma İstasyonu · −40 m',
          summary: 'Türkiye’nin ilk tam otomatik sürücüsüz metro hattı başlangıç istasyonu; tam boy PAKS peron kapıları ve Marmaray altgeçidi.',
        );
      }
    }
    // 6. Yenikapı Mega Transfer Hub (B1, M1A, M1B, M2)
    if (name == 'yenikapi' && code != 'T6') {
      return _StationEngineeringOverride(
        depth: code == 'M2' ? 26 : 24,
        island: code == 'M2' || code == 'B1',
        archetype: StationArchetype.monumentalTransferHub,
        title: 'Yenikapı Arkeo-Transfer Merkezi · Aç-Kapa Meydan',
        summary: 'Theodosius Limanı arkeolojik kazı alanı üzerine inşa edilen, kaset tavan ışıklıklı ve mozaik sütunlu dev 4-hat aktarma kompleksi.',
      );
    }
    // 7. Şişhane M2 (-45m deep cavern)
    if (name == 'sishane' && code == 'M2') {
      return const _StationEngineeringOverride(
        depth: 45,
        island: true,
        archetype: StationArchetype.deepCavernTubes,
        title: 'Beyoğlu Sırtı Derin Tünel İstasyonu · −45 m',
        summary: 'İstiklal Caddesi, Vergi Dairesi ve Kasımpaşa kotlarını birbirine bağlayan −45 m derinlikte kemerli tünel peron.',
      );
    }
    // 8. Mecidiyeköy (M7 -47m deep cavern / M2 -28m hub)
    if (name.contains('mecidiyekoy') || name.contains('sisli')) {
      if (code == 'M7') {
        return const _StationEngineeringOverride(
          depth: 47,
          island: false,
          archetype: StationArchetype.deepCavernTubes,
          title: 'Derin NATM Aktarma Tüneli · −47 m',
          summary: 'M2 hattı ve Metrobüs aksının altından geçen −47 m derinlikte PAKS kapılı ikiz tünel peronlar.',
        );
      }
      return const _StationEngineeringOverride(
        depth: 28,
        island: true,
        archetype: StationArchetype.monumentalTransferHub,
        title: 'Şişli-Mecidiyeköy Ana Aktarma Merkezi · −28 m',
        summary: 'Çok çıkışlı yeraltı çarşı konkorsu, M7 sürücüsüz metro ve Metrobüs yaya tünelleri.',
      );
    }
    // 9. Ayrılık Çeşmesi (B1 / M4)
    if (name.contains('ayrilik cesmesi')) {
      return _StationEngineeringOverride(
        depth: code == 'B1' ? 28 : 24,
        island: true,
        archetype: StationArchetype.monumentalTransferHub,
        title: 'Anadolu Yakası Ana Raylı Aktarma Merkezi',
        summary: 'Marmaray Boğaz tüp geçişi çıkışı ile M4 Kadıköy–Sabiha Gökçen hattını üst üste bağlayan geniş konkorslu istasyon.',
      );
    }
    // 10. Taksim (M2 / F1)
    if (name == 'taksim' && (code == 'M2' || code == 'F1')) {
      return _StationEngineeringOverride(
        depth: code == 'M2' ? 30 : 22,
        island: code == 'M2',
        archetype: code == 'F1' ? StationArchetype.slopedFunicularOrCable : StationArchetype.monumentalTransferHub,
        title: code == 'F1' ? 'Taksim–Kabataş Eğimli Füniküler Terminali' : 'Taksim Meydanı Çok Katlı Metro Merkezi · −30 m',
        summary: 'Taksim Meydanı, Gezi Parkı ve Talimhane çıkışlarını F1 Kabataş füniküleri ile birleştiren galeri boşluklu merkez.',
      );
    }
    // 11. Kadıköy (M4)
    if (name == 'kadikoy' && code == 'M4') {
      return const _StationEngineeringOverride(
        depth: 32,
        island: true,
        archetype: StationArchetype.waterfrontCutAndCover,
        title: 'Kadıköy Rıhtım Kıyı Metro İstasyonu · −32 m',
        summary: 'Kadıköy İskele Meydanı altında deniz seviyesinin altında inşa edilmiş, vapur iskeleleri ve T3 tramvay bağlantılı ana terminal.',
      );
    }
    // 12. Kağıthane (M7 Viaduct vs M11 Underground)
    if (name == 'kagithane') {
      if (code == 'M7') {
        return const _StationEngineeringOverride(
          depth: -12,
          island: false,
          archetype: StationArchetype.viaductElevated,
          title: 'Kağıthane Deresi Viyadük İstasyonu · +12 m',
          summary: 'Kağıthane Cendere Vadisi üzerinde +12 m yüksekliğinde betonarme viyadük ve çelik-cam tonoz kanopi.',
        );
      }
      if (code == 'M11') {
        return const _StationEngineeringOverride(
          depth: 34,
          island: true,
          archetype: StationArchetype.monumentalTransferHub,
          title: 'Kağıthane M11 Havalimanı Metrosu İstasyonu · −34 m',
          summary: 'M7 viyadüğü ile entegre, İstanbul Havalimanı ekspres hattının PAKS kapılı yeraltı istasyonu.',
        );
      }
    }
    // 13. Alibeyköy M7 Viaduct
    if (name == 'alibeykoy' && code == 'M7') {
      return const _StationEngineeringOverride(
        depth: -10,
        island: false,
        archetype: StationArchetype.viaductElevated,
        title: 'Alibeyköy Viyadük & T5 Aktarma İstasyonu · +10 m',
        summary: 'Alibeyköy Deresi üzerinde yükseltilmiş viyadük peronları ve zemin katta T5 Haliç tramvayı aktarması.',
      );
    }
    // 14. Söğütlüçeşme B1 Viaduct
    if (name == 'sogutlucesme' && code == 'B1') {
      return const _StationEngineeringOverride(
        depth: -8,
        island: true,
        archetype: StationArchetype.viaductElevated,
        title: 'Söğütlüçeşme Viyadük Gar & Metrobüs Merkezi · +8 m',
        summary: 'Kadıköy Kurbağalıdere üzerinde yükseltilmiş viyadük peronu, YHT garı ve Metrobüs terminali.',
      );
    }
    // 15. F2 Tarihi Tünel (Karaköy - Beyoğlu 1875)
    if (code == 'F2') {
      return const _StationEngineeringOverride(
        depth: 18,
        island: false,
        archetype: StationArchetype.slopedFunicularOrCable,
        title: 'Tarihi Tünel (1875) · Dünyanın En Eski 2. Yeraltı Raylı Sistemi',
        summary: '1875 yılında Eugène-Henri Gavand tarafından inşa edilen, tuğla tonoz kemerli tarihi Karaköy–Beyoğlu füniküler istasyonu.',
      );
    }
    // 16. Boğaziçi Üniversitesi / Hisarüstü (M6 & F4)
    if (name.contains('bogazici') || name.contains('hisarustu')) {
      return _StationEngineeringOverride(
        depth: 35,
        island: code == 'M6',
        archetype: code == 'F4' ? StationArchetype.slopedFunicularOrCable : StationArchetype.deepCavernTubes,
        title: code == 'F4' ? 'Hisarüstü–Aşiyan Boğaz Füniküleri · −35 m' : 'Boğaziçi Üniv. NATM Tünel İstasyonu · −35 m',
        summary: 'Boğaziçi Üniversitesi güney kampüsü girişinde −35 m derinlikte kemerli tünel peron ve F4 Aşiyan füniküler bağlantısı.',
      );
    }
    return null;
  }

  static bool _inferIslandPlatform(String code, String folded, NetworkStation st) {
    if (code == 'T1' || code == 'T4' || code == 'T5') return false;
    if (code == 'B1' || code == 'B2') {
      // Sirkeci and Bakırköy/Söğütlüçeşme have distinct layouts; most Marmaray surface stations have island passenger platforms
      if (folded.contains('sirkeci') || folded.contains('bakirkoy')) return false;
      return true;
    }
    return st.islandPlatform;
  }

  static StationArchetype _inferArchetype(RailLine line, StationKind kind, double depth, String folded, NetworkStation st) {
    if (line.mode == RailMode.funicular || line.mode == RailMode.cable) {
      return StationArchetype.slopedFunicularOrCable;
    }
    if (kind == StationKind.elevated || depth < -2) {
      return StationArchetype.viaductElevated;
    }
    if (line.code == 'B1' || line.code == 'B2' || line.code == 'T6') {
      if (kind == StationKind.underground && depth >= 45) return StationArchetype.deepCavernTubes;
      if (kind == StationKind.underground) return StationArchetype.monumentalTransferHub;
      return StationArchetype.marmaraySurface;
    }
    if (kind == StationKind.underground) {
      if (depth >= 36) return StationArchetype.deepCavernTubes;
      if (st.lines.length >= 2 || st.entrances.length >= 5) return StationArchetype.monumentalTransferHub;
      return StationArchetype.modernUnderground;
    }
    return StationArchetype.modernUnderground;
  }

  static String _defaultArchTitle(StationArchetype a, RailLine line) => switch (a) {
        StationArchetype.deepCavernTubes => 'Derin NATM Delme Tünel İstasyonu · ${line.code}',
        StationArchetype.goldenHornBridge => 'Haliç Eğik Askılı Metro Köprüsü',
        StationArchetype.waterfrontCutAndCover => 'Kıyı Meydanı Aç-Kapa İstasyonu · ${line.code}',
        StationArchetype.monumentalTransferHub => 'Çok Katlı Raylı Aktarma Merkezi · ${line.code}',
        StationArchetype.viaductElevated => 'Yükseltilmiş Betonarme Viyadük İstasyonu · ${line.code}',
        StationArchetype.marmaraySurface => 'Marmaray Yüzey İstasyonu · Üstgeçit Konkors & Katener',
        StationArchetype.slopedFunicularOrCable => line.mode == RailMode.cable ? 'Teleferik İstasyonu' : 'Eğimli Füniküler İstasyonu',
        StationArchetype.modernUnderground => '${line.code} Yeraltı Metro İstasyonu${_isDriverless(line.code) ? ' · Tam Boy PAKS' : ''}',
      };

  static String _defaultArchSummary(StationArchetype a, RailLine line, NetworkStation st) => switch (a) {
        StationArchetype.deepCavernTubes =>
          'Derin yeraltı kotunda açılmış kemerli NATM peron tünelleri, ara sahanlıklı yürüyen merdiven şaftları ve bağlantı galerileri.',
        StationArchetype.goldenHornBridge =>
          'Haliç üzerinde eğik askılı çelik köprü, yan peronlar ve yaya geçiş yolları.',
        StationArchetype.waterfrontCutAndCover =>
          'Deniz kıyısında diyafram duvarlı aç-kapa istasyon yapısı, doğal ışıklıklı konkors ve iskele bağlantısı.',
        StationArchetype.monumentalTransferHub =>
          '${st.lines.join(" · ")} hatlarını birbirine bağlayan galeri boşluklu geniş konkors ve ${st.entranceCount} farklı sokak girişi.',
        StationArchetype.viaductElevated =>
          'Cadde kotu üzerinde yükseltilmiş viyadük ayakları, çelik-cam kanopi ve zemin kat turnike holü.',
        StationArchetype.marmaraySurface =>
          '225 m uzunluğunda 10 vagonlu Marmaray peronu, havai katener portalları ve üstgeçit bilet holü.',
        StationArchetype.slopedFunicularOrCable =>
          line.mode == RailMode.cable ? 'Askı halatı çark sistemi ve panoramik kabin yanaşma peronu.' : 'Eğimli hat boyunca kademeli peron ve halat tambur sistemi.',
        StationArchetype.modernUnderground =>
          'OpenStreetMap giriş/çıkış yönlerine göre modellenmiş konkors, turnike holü ve ${_isDriverless(line.code) ? 'tam boy PAKS peron ayırıcı kapılı ' : ''}peron katı.',
      };

  static bool _isDriverless(String code) =>
      code == 'M5' || code == 'M7' || code == 'M8' || code == 'M11' || code == 'F1' || code == 'F4';

  /// True when the platform has full-height automated Platform Screen Doors (PAKS / PSDs).
  bool get hasPsd => _isDriverless(line.code);

  static double _computeTrackBearing(NetworkStation st, RailLine line) {
    if (line.variants.isEmpty) return 90.0;
    final v = line.variants.first;
    final idx = v.indexOfStation(st.id);
    if (idx >= 0) {
      final d = v.stops[idx].distM;
      final (_, h) = v.path.pointAt(d);
      return h;
    }
    return 90.0;
  }

  static List<ProjectedEntrance> _projectEntrances(NetworkStation st, double trackBearingDeg) {
    if (st.entrances.isEmpty) {
      return const [
        ProjectedEntrance(label: 'Giriş 1', dx: -45, dz: -8, wheelchair: true),
        ProjectedEntrance(label: 'Giriş 2', dx: -45, dz: 8, wheelchair: false),
      ];
    }
    final rad = trackBearingDeg * math.pi / 180.0;
    final ux = math.sin(rad), uy = math.cos(rad); // along track (east, north)
    final vx = math.cos(rad), vy = -math.sin(rad); // across track
    final kx = 111320.0 * math.cos(st.pos.latitude * math.pi / 180.0);
    const ky = 110540.0;
    final out = <ProjectedEntrance>[];
    for (var i = 0; i < st.entrances.length; i++) {
      final e = st.entrances[i];
      final eastM = (e.pos.longitude - st.pos.longitude) * kx;
      final northM = (e.pos.latitude - st.pos.latitude) * ky;
      final dx = (eastM * ux + northM * uy).clamp(-110.0, 110.0);
      final dz = (eastM * vx + northM * vy).clamp(-42.0, 42.0);
      final lbl = e.ref.isNotEmpty
          ? 'Giriş ${e.ref}${e.name.isNotEmpty ? ' · ${e.name}' : ''}'
          : (e.name.isNotEmpty ? e.name : 'Giriş ${i + 1}');
      out.add(ProjectedEntrance(label: lbl, dx: dx, dz: dz, wheelchair: e.wheelchair));
    }
    return out;
  }

  bool get underground => kind == StationKind.underground && depth > 1;
  bool get elevated => kind == StationKind.elevated || depth < -1;
  bool get isRail => line.mode == RailMode.suburban || line.mode == RailMode.metro;

  double get yPlatform => underground ? -depth : (elevated ? depth.abs().clamp(8.0, 14.0) : (isRail ? 1.0 : 0.3));
  double get yConcourse {
    if (archetype == StationArchetype.marmaraySurface) return 6.4; // Overhead pedestrian footbridge (üstgeçit)
    if (underground) return -(depth * 0.36).clamp(5.5, 14.0);
    return 0.0;
  }

  double get platformLength => switch (line.mode) {
        RailMode.suburban => 225,
        RailMode.metro => line.code == 'M6' ? 80 : (line.code == 'M1A' || line.code == 'M1B' ? 120 : 180),
        RailMode.tram => 55,
        RailMode.funicular => 60,
        RailMode.cable => 24,
      };
  bool get hasSecurity => underground || (isRail && !elevated) || archetype == StationArchetype.marmaraySurface;
  double get trackZ => archetype == StationArchetype.deepCavernTubes ? 9.2 : (island ? 7.0 : 1.75);

  /// Horizontal run of the main escalator bank (30° incline).
  double get escalatorRun => (yPlatform - yConcourse).abs() * 1.732;
  double get escalatorLength => (yPlatform - yConcourse).abs() * 2.0;
  double get entranceRun => underground ? (-yConcourse) * 1.732 : (archetype == StationArchetype.marmaraySurface ? 10.0 : 0);

  // x positions along the station (platform centre = 0, the street is toward −x)
  double get xLanding => -platformLength * 0.16;
  double get xTop => xLanding - math.max(escalatorRun, 4);
  double get xGates => xTop - 10;
  double get xSecurity => xTop - 19;
  double get xConcourseStart => xTop - 34;
  double get xPassageStart => xConcourseStart - (underground ? 18 : 6);
  double get xStreetTop => xPassageStart - entranceRun;

  int get entranceCount => station.entranceCount;

  String get depthText {
    if (underground) return '−${depth.round()} m';
    if (elevated) return '+${depth.abs().round()} m';
    return 'Zemin';
  }

  List<PlanLayer> get layers {
    final esc = escalatorLength;
    final escMin = math.max(1, (esc / 0.5 / 60).round());
    final isBridge = archetype == StationArchetype.goldenHornBridge;
    final isMarmaraySurface = archetype == StationArchetype.marmaraySurface;
    return [
      PlanLayer(
        StationStage.street,
        isBridge ? 'Haliç Yaya Köprüsü Girişi' : 'Sokak & Girişler',
        '$entranceCount gerçek OSM girişi${station.elevators > 0 ? ' · ${station.elevators} asansör' : ''}${station.escalators > 0 ? ' · ${station.escalators} yürüyen merdiven' : ''}',
        Icons.directions_walk_rounded,
        0,
        xStreetTop - 6,
      ),
      PlanLayer(
        StationStage.gates,
        isMarmaraySurface
            ? 'Üstgeçit Turnike Holü (+6 m)'
            : (underground ? 'Konkors · Turnike & Güvenlik' : 'Turnikeler & İstanbulkart'),
        underground
            ? '−${(-yConcourse).round()} m · X-ray, İstanbulkart${station.lines.length > 1 ? ' · ${station.lines.join("/")} aktarma' : ''}'
            : (isMarmaraySurface ? '+6 m yaya üstgeçidi · İstanbulkart & X-ray' : 'Zemin kat · İstanbulkart'),
        Icons.shield_outlined,
        yConcourse,
        xGates,
      ),
      if (esc > 3)
        PlanLayer(
          StationStage.escalators,
          archetype == StationArchetype.deepCavernTubes ? 'Derin Şaft & Yürüyen Merdivenler' : 'Yürüyen Merdiven & Asansör',
          '${esc.round()} m eğimli iniş · yaklaşık $escMin dk${depth >= 40 ? ' · ara sahanlıklı' : ''}',
          Icons.stairs_rounded,
          (yConcourse + yPlatform) / 2,
          (xTop + xLanding) / 2,
        ),
      PlanLayer(
        StationStage.platform,
        archetype == StationArchetype.deepCavernTubes ? 'İkiz NATM Tünel Peronlar' : 'Peron Katı',
        '${underground ? '−${depth.round()} m derinlik' : (elevated ? 'Viyadük +${depth.abs().round()} m' : 'Zemin seviyesi')} · ${island ? 'ada peron' : 'yan peron'}${hasPsd ? ' · PAKS kapılı' : ''}',
        Icons.directions_subway_filled_rounded,
        yPlatform,
        0,
      ),
    ];
  }
}

/// A waypoint along the first-person walking path from the street to the platform.
class PathNode {
  final double s; // cumulative distance (m)
  final double x, y, z;
  final StationStage stage;
  final bool onEscalator;
  const PathNode(this.s, this.x, this.y, this.z, this.stage, {this.onEscalator = false});
}

/// Builds the 3D mesh + labels + walk path of a station from its [StationPlan].
/// Each station renders with its authentic architectural archetype, real OSM entrance orientations,
/// line-specific material palette, and Platform Screen Doors (PAKS) where installed.
class StationScene {
  final StationPlan plan;
  final bool reveal; // true = open ceiling cut-away; false = enclosed ceilings for first-person walk
  late final Mesh staticMesh;
  late final List<Label3D> labels;
  late final List<PathNode> path;
  late final double pathLength;

  StationScene(this.plan, {this.reveal = false}) {
    final m = Mesh();
    final lbs = <Label3D>[];
    final pts = <(double, double, double, StationStage, bool)>[];
    _build(m, lbs, pts);
    staticMesh = m;
    labels = lbs;
    final out = <PathNode>[];
    var s = 0.0;
    for (var i = 0; i < pts.length; i++) {
      if (i > 0) {
        final dx = pts[i].$1 - pts[i - 1].$1, dy = pts[i].$2 - pts[i - 1].$2, dz = pts[i].$3 - pts[i - 1].$3;
        s += math.sqrt(dx * dx + dy * dy + dz * dz);
      }
      out.add(PathNode(s, pts[i].$1, pts[i].$2, pts[i].$3, pts[i].$4, onEscalator: pts[i].$5));
    }
    path = out;
    pathLength = s;
  }

  /// Sample the walk path at distance [s] metres.
  (double x, double y, double z, StationStage stage, bool onEsc) pointAt(double s) {
    if (path.isEmpty) return (0, 0, 0, StationStage.street, false);
    final cl = s.clamp(0.0, pathLength);
    var i = 0;
    while (i + 1 < path.length && path[i + 1].s < cl) {
      i++;
    }
    if (i + 1 >= path.length) {
      final n = path.last;
      return (n.x, n.y, n.z, n.stage, n.onEscalator);
    }
    final a = path[i], b = path[i + 1];
    final t = (b.s - a.s) <= 1e-6 ? 0.0 : (cl - a.s) / (b.s - a.s);
    return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.stage, a.onEscalator);
  }

  double stageStart(StationStage st) {
    for (final n in path) {
      if (n.stage == st) return n.s;
    }
    return 0;
  }

  // ─────────────── station-specific material palette ───────────────

  static const _wallB = Color(0xFFD5DCE4);
  static const _conc = Color(0xFF94A3B8);
  static const _dark = Color(0xFF1E293B);
  static const _steel = Color(0xFFCBD5E1);
  static const _tactile = Color(0xFFF59E0B);

  Color get _floorA => switch (plan.archetype) {
        StationArchetype.monumentalTransferHub => const Color(0xFFEAE3D5), // warm travertine / marble
        StationArchetype.waterfrontCutAndCover => const Color(0xFFDCE7F0), // coastal granite
        StationArchetype.deepCavernTubes => const Color(0xFFD8E0E8),
        _ => const Color(0xFFDDE3EA),
      };

  Color get _floorB => switch (plan.archetype) {
        StationArchetype.monumentalTransferHub => const Color(0xFFD8CFC0),
        StationArchetype.waterfrontCutAndCover => const Color(0xFFCBD9E6),
        StationArchetype.deepCavernTubes => const Color(0xFFC8D2DC),
        _ => const Color(0xFFCDD5DF),
      };

  void _build(Mesh m, List<Label3D> lbs, List<(double, double, double, StationStage, bool)> pts) {
    final p = plan;
    final col = p.line.color;
    final main = p.line.variants.first;

    // 1. Specialized full-scene builders for Golden Horn Bridge & Surface/Viaduct stations
    if (p.archetype == StationArchetype.goldenHornBridge) {
      _buildGoldenHornBridgeStation(m, lbs, pts, col, main);
      return;
    }
    if (p.archetype == StationArchetype.marmaraySurface) {
      _buildMarmaraySurfaceStation(m, lbs, pts, col, main);
      return;
    }
    if (!p.underground) {
      _buildSurfaceOrViaduct(m, lbs, pts);
      return;
    }

    // 2. Underground Stations (Deep NATM Twin Caverns, Waterfront Plaza, Monumental Hubs, Modern Metro)
    _streetWithRealEntrances(m, lbs, xEntry: p.xStreetTop, waterfront: p.archetype == StationArchetype.waterfrontCutAndCover);
    pts.add((p.xStreetTop - 16, 0, 0, StationStage.street, false));
    pts.add((p.xStreetTop - 2, 0, 0, StationStage.street, false));

    // Street -> Concourse escalator & stairs
    _entranceEscalator(m, p.xStreetTop, 0, p.xPassageStart, p.yConcourse, col);
    pts.add((p.xPassageStart, p.yConcourse, 0, StationStage.passage, true));

    // Approach passage with real multi-entrance branches from OpenStreetMap
    _passageWithBranches(m, p.xPassageStart, p.xConcourseStart, p.yConcourse, col);
    pts.add((p.xConcourseStart, p.yConcourse, 0, StationStage.passage, false));

    // Concourse (Turnike & Güvenlik Holü)
    _concourse(m, lbs, p.xConcourseStart, p.xTop, p.yConcourse, col);
    pts.add((p.xSecurity, p.yConcourse, 0, StationStage.security, false));
    pts.add((p.xGates + 2, p.yConcourse, 0, StationStage.gates, false));
    pts.add((p.xTop, p.yConcourse, 0, StationStage.escalators, false));

    // Main escalator bank (with intermediate mezzanine landing shaft for deep stations >= 36m)
    _escalatorBank(m, p.xTop, p.yConcourse, p.xLanding, p.yPlatform, col);
    pts.add(((p.xTop + p.xLanding) / 2, (p.yConcourse + p.yPlatform) / 2, 0, StationStage.escalators, true));
    pts.add((p.xLanding, p.yPlatform, 0, StationStage.platform, false));

    // Platform Hall — branches by real engineering archetype!
    switch (p.archetype) {
      case StationArchetype.deepCavernTubes:
        _buildDeepTwinCavernPlatform(m, lbs, p.yPlatform, col, main);
      case StationArchetype.monumentalTransferHub:
      case StationArchetype.waterfrontCutAndCover:
        _buildMonumentalHubPlatform(m, lbs, p.yPlatform, col, main);
      case StationArchetype.slopedFunicularOrCable:
        _buildFunicularPlatform(m, lbs, p.yPlatform, col, main);
      default:
        _buildModernUndergroundPlatform(m, lbs, p.yPlatform, col, main);
    }

    pts.add((p.xLanding + 12, p.yPlatform, 0, StationStage.platform, false));
    pts.add((0, p.yPlatform, 0, StationStage.platform, false));
    pts.add((18, p.yPlatform, p.island ? 2.5 : -2.6, StationStage.platform, false));
  }

  // ─────────────── 1. HALİÇ GOLDEN HORN CABLE-STAYED BRIDGE STATION ───────────────

  void _buildGoldenHornBridgeStation(
    Mesh m,
    List<Label3D> lbs,
    List<(double, double, double, StationStage, bool)> pts,
    Color col,
    RailVariant main,
  ) {
    final L = plan.platformLength;
    const hL = 110.0;
    const yWater = -13.0;
    const yDeck = 0.0;
    const bridgeW = 14.5;

    // Golden Horn water surface below the bridge
    m.tiledFloor(-hL - 40, -65, hL + 40, 65, yWater, 16, const Color(0xFF0E4D6E), const Color(0xFF155E75));

    // Concrete cylindrical river piers rising out of the Golden Horn water
    for (final px in [-78.0, -32.0, 32.0, 78.0]) {
      m.cylinder(px, -4.5, yWater, yDeck, 2.2, const Color(0xFFCBD5E1), seg: 12);
      m.cylinder(px, 4.5, yWater, yDeck, 2.2, const Color(0xFFCBD5E1), seg: 12);
      // Pier water-level pile cap
      m.box(px - 3.6, yWater, -7.8, px + 3.6, yWater + 1.4, 7.8, const Color(0xFF94A3B8));
    }

    // Steel box-girder bridge deck
    m.box(-hL - 35, yDeck - 2.4, -bridgeW, hL + 35, yDeck - 0.8, bridgeW, const Color(0xFF64748B));

    // Two iconic inclined white steel cable-stayed pylons (+32m tall) & stay cables
    for (final px in [-32.0, 32.0]) {
      for (final sgn in [-1.0, 1.0]) {
        final zBase = sgn * (bridgeW - 1.2);
        // Pylon tower legs
        m.ramp(px - 1.4, yDeck, px - 0.6, yDeck + 32.0, zBase - 0.7, zBase + 0.7, Colors.white);
        // Radiating stay cables fanning to the bridge deck
        for (final spanOff in [-38.0, -26.0, -15.0, 15.0, 26.0, 38.0]) {
          m.ramp(px, yDeck + 28.0, px + spanOff, yDeck + 0.5, zBase - 0.06, zBase + 0.06, const Color(0xFFE2E8F0));
        }
      }
      // Cross-beam between pylon legs
      m.box(px - 0.9, yDeck + 22.0, -bridgeW + 1.0, px + 0.9, yDeck + 23.4, bridgeW - 1.0, Colors.white);
    }

    // Central twin tracks & side platforms + outer Golden Horn pedestrian walkways
    _tracks(m, -hL - 30, hL + 30, yDeck - 0.8, 1.75);
    for (final sgn in [-1.0, 1.0]) {
      final zInner = sgn * 3.2, zOuter = sgn * 8.6;
      final zMin = math.min(zInner, zOuter), zMax = math.max(zInner, zOuter);
      m.tiledFloor(-L / 2, zMin, L / 2, zMax, yDeck, 3.0, _floorA, _floorB);
      m.box(-L / 2, yDeck - 0.8, zMin, L / 2, yDeck, zMax, _conc, faces: 4 | 8 | 16 | 32);
      // Yellow tactile strip
      final tz = sgn * 3.55;
      m.quad([-L / 2 + 1, yDeck + 0.02, tz - 0.18], [L / 2 - 1, yDeck + 0.02, tz - 0.18], [L / 2 - 1, yDeck + 0.02, tz + 0.18],
          [-L / 2 + 1, yDeck + 0.02, tz + 0.18], _tactile);
      // Curved steel-and-glass windscreen shell canopy over each side platform
      for (var x = -L / 2 + 6; x <= L / 2 - 6; x += 12) {
        m.box(x - 0.2, yDeck, sgn * 8.2, x + 0.2, yDeck + 4.4, sgn * 8.5, Colors.white);
        m.ramp(x - 0.2, yDeck + 4.4, x + 0.2, yDeck + 5.2, math.min(sgn * 3.4, sgn * 8.4), math.max(sgn * 3.4, sgn * 8.4), Colors.white);
      }
      if (!reveal) {
        m.box(-L / 2, yDeck + 4.6, zMin, L / 2, yDeck + 4.85, zMax, const Color(0xFFBAE6FD));
      }
      _platformFurniture(m, -L / 2, L / 2, yDeck, sgn * 5.8, col, '${plan.station.name} · Haliç Köprüsü');
    }

    // Approach pedestrian bridge & turnstiles at -X end
    _fareGates(m, -L / 2 - 8, yDeck, col);
    lbs.add(const Label3D(-32, 34, 0, 'Haliç Metro Köprüsü', sub: '+13 m · Eğik Askılı Pilonlar', icon: Icons.architecture_rounded));
    lbs.add(Label3D(-L / 2 - 12, yDeck + 3.2, 0, 'Yaya Köprüsü Girişi', sub: 'Unkapanı / Beyoğlu yönü', color: col, icon: Icons.directions_walk_rounded));
    lbs.add(Label3D(20, yDeck + 3.6, -5.8, '→ ${main.to}', color: col, dark: true));
    lbs.add(Label3D(20, yDeck + 3.6, 5.8, '→ ${main.from}', color: col, dark: true));

    pts.add((-L / 2 - 22, yDeck, -5.8, StationStage.street, false));
    pts.add((-L / 2 - 8, yDeck, -5.8, StationStage.gates, false));
    pts.add((0, yDeck, -5.8, StationStage.platform, false));
    pts.add((22, yDeck, -5.8, StationStage.platform, false));
  }

  // ─────────────── 2. MARMARAY SURFACE COMMUTER STATION (ÜSTGEÇİT & KATENER) ───────────────

  void _buildMarmaraySurfaceStation(
    Mesh m,
    List<Label3D> lbs,
    List<(double, double, double, StationStage, bool)> pts,
    Color col,
    RailVariant main,
  ) {
    final L = plan.platformLength;
    final hL = L / 2;
    const yPlat = 1.05;
    const yBridge = 6.4;

    // Surrounding urban ground & boulevard trees
    m.tiledFloor(-hL - 25, -34, hL + 25, 34, 0, 8, const Color(0xFFCBD5E1), const Color(0xFFBCC6D2));
    for (var x = -hL; x <= hL; x += 28) {
      _tree(m, x, -22);
      _tree(m, x, 22);
    }

    // Platform & Dual Commuter Tracks
    if (plan.island) {
      const pw = 5.4;
      _tracks(m, -hL - 22, hL + 22, 0.0, 7.0);
      m.tiledFloor(-hL, -pw, hL, pw, yPlat, 3.0, _floorA, _floorB);
      m.box(-hL, 0, -pw, hL, yPlat, pw, _conc, faces: 4 | 8 | 16 | 32);
      for (final sgn in [-1.0, 1.0]) {
        final tz = sgn * (pw - 0.45);
        m.quad([-hL + 1, yPlat + 0.02, tz - 0.2], [hL - 1, yPlat + 0.02, tz - 0.2], [hL - 1, yPlat + 0.02, tz + 0.2],
            [-hL + 1, yPlat + 0.02, tz + 0.2], _tactile);
      }
      _platformFurniture(m, -hL, hL, yPlat, 0, col, plan.station.name);
    } else {
      _tracks(m, -hL - 22, hL + 22, 0.0, 1.75);
      for (final sgn in [-1.0, 1.0]) {
        final zMin = math.min(sgn * 3.1, sgn * 7.8), zMax = math.max(sgn * 3.1, sgn * 7.8);
        m.tiledFloor(-hL, zMin, hL, zMax, yPlat, 3.0, _floorA, _floorB);
        m.box(-hL, 0, zMin, hL, yPlat, zMax, _conc, faces: 4 | 8 | 16 | 32);
        _platformFurniture(m, -hL, hL, yPlat, sgn * 5.2, col, plan.station.name);
      }
    }

    // Overhead Catenary Portals (25 kV AC electrification masts & contact wire)
    for (var x = -hL + 14; x <= hL - 14; x += 28) {
      m.box(x - 0.18, 0, -10.5, x + 0.18, 6.2, -10.1, const Color(0xFF475569));
      m.box(x - 0.18, 0, 10.1, x + 0.18, 6.2, 10.5, const Color(0xFF475569));
      m.box(x - 0.15, 5.8, -10.5, x + 0.15, 6.1, 10.5, const Color(0xFF64748B));
      // V-strut platform shelter canopy columns
      m.cylinder(x, 0, yPlat, yPlat + 4.1, 0.22, const Color(0xFF334155), seg: 8);
      m.box(x - 11.0, yPlat + 4.0, -4.2, x + 11.0, yPlat + 4.25, 4.2, const Color(0xFF94A3B8));
    }

    // Overhead Pedestrian Concourse Footbridge (Üstgeçit Bilet Holü at y = +6.4m)
    const bx0 = -32.0, bx1 = -18.0;
    m.tiledFloor(bx0, -18, bx1, 18, yBridge, 2.0, _floorA, _floorB);
    m.box(bx0, yBridge - 0.45, -18, bx1, yBridge, 18, _conc);
    // Glass side walls of the overpass footbridge
    m.box(bx0, yBridge, -18, bx1, yBridge + 3.2, -17.6, const Color(0xFF38BDF8));
    m.box(bx0, yBridge, 17.6, bx1, yBridge + 3.2, 18, const Color(0xFF38BDF8));
    if (!reveal) {
      m.box(bx0, yBridge + 3.2, -18, bx1, yBridge + 3.5, 18, const Color(0xFF64748B));
    }
    // Street stairs rising to the footbridge + Fare gates on the bridge + Escalator descending to platform
    m.ramp(bx0 - 9.0, 0, bx0, yBridge, -16.5, -12.5, _steel, steps: 20, alt: _dark);
    _fareGates(m, (bx0 + bx1) / 2, yBridge, col);
    m.ramp(bx1, yBridge, bx1 + 10.0, yPlat, -2.2, 2.2, _steel, steps: 18, alt: _dark);

    lbs.add(Label3D(bx0 - 6, 2.5, -14.5, '${plan.station.name} Girişi', sub: '${plan.entranceCount} giriş · Asansör', color: col, icon: Icons.directions_walk_rounded));
    lbs.add(const Label3D((bx0 + bx1) / 2, yBridge + 3.8, 0, 'Üstgeçit Turnike Holü', sub: '+6 m · İstanbulkart & X-ray', icon: Icons.credit_card_rounded));
    lbs.add(Label3D(18, yPlat + 3.8, -plan.trackZ, '→ ${main.to}', color: col, dark: true));
    lbs.add(Label3D(18, yPlat + 3.8, plan.trackZ, '→ ${main.from}', color: col, dark: true));

    pts.add((bx0 - 10, 0, -14.5, StationStage.street, false));
    pts.add((bx0, yBridge, -14.5, StationStage.passage, true));
    pts.add(((bx0 + bx1) / 2, yBridge, 0, StationStage.gates, false));
    pts.add((bx1 + 5, (yBridge + yPlat) / 2, 0, StationStage.escalators, true));
    pts.add((bx1 + 11, yPlat, 0, StationStage.platform, false));
    pts.add((12, yPlat, 0, StationStage.platform, false));
  }

  // ─────────────── 3. DEEP NATM TWIN BORED CAVERN STATIONS (SİRKECİ / GAYRETTEPE / YILDIZ / ŞİŞHANE) ───────────────

  void _buildDeepTwinCavernPlatform(Mesh m, List<Label3D> lbs, double y, Color col, RailVariant main) {
    final L = plan.platformLength;
    final hL = L / 2;
    const zTube = 9.2; // Two parallel circular bored platform tunnels at z = -9.2 and z = +9.2
    const tubeR = 4.8;

    // Central arrival gallery between the two bored tunnels where the deep escalators land
    m.tiledFloor(plan.xLanding - 4, -5.2, 24.0, 5.2, y, 2.2, _floorA, _floorB);
    m.box(plan.xLanding - 4, y - 0.8, -5.2, 24.0, y, 5.2, _conc);

    // 4 Vaulted Cross-Passages (Bağlantı Tünelleri) linking the central gallery to the twin platform tubes
    for (final cx in [-48.0, -16.0, 16.0, 48.0]) {
      if (cx.abs() > hL - 8) continue;
      m.tiledFloor(cx - 3.2, -zTube, cx + 3.2, zTube, y, 2.0, _floorA, _floorB);
      // Vaulted cross-adit arch walls
      m.box(cx - 3.4, y, -4.8, cx - 3.1, y + 3.8, 4.8, const Color(0xFFCBD5E1));
      m.box(cx + 3.1, y, -4.8, cx + 3.4, y + 3.8, 4.8, const Color(0xFFCBD5E1));
      if (!reveal) {
        m.box(cx - 3.4, y + 3.8, -4.8, cx + 3.4, y + 4.1, 4.8, _conc);
      }
    }

    // Twin Parallel Bored Cylindrical Tunnels (NATM Shotcrete / Segmental Rings)
    for (final sgn in [-1.0, 1.0]) {
      final zCenter = sgn * zTube;
      final zTrack = zCenter + sgn * 1.45;
      final zPlatInner = zCenter - sgn * 3.4;
      final zPlatEdge = zCenter + sgn * 0.15;
      final zMin = math.min(zPlatInner, zPlatEdge), zMax = math.max(zPlatInner, zPlatEdge);

      // Single track inside this bored tunnel tube
      _singleTrack(m, -hL - 26, hL + 26, y - 0.95, zTrack);

      // Platform slab inside the tube
      m.tiledFloor(-hL, zMin, hL, zMax, y, 3.0, _floorA, _floorB);
      m.box(-hL, y - 0.95, zMin, hL, y, zMax, _conc, faces: 4 | 8 | 16 | 32);

      // Tactile warning strip & optional Full-Height Platform Screen Doors (PAKS)
      final tz = zPlatEdge - sgn * 0.35;
      m.quad([-hL + 1, y + 0.02, tz - 0.18], [hL - 1, y + 0.02, tz - 0.18], [hL - 1, y + 0.02, tz + 0.18],
          [-hL + 1, y + 0.02, tz + 0.18], _tactile);
      if (plan.hasPsd) {
        _platformScreenDoors(m, -hL + 4, hL - 4, y, zPlatEdge, col);
      }

      // Cylindrical NATM Arched Tunnel Lining & Structural Ribs
      const archSegs = 8;
      final maxSeg = reveal ? 5 : archSegs; // In reveal mode, leave top crown open so user can see inside the twin tubes!
      for (var s = 0; s < maxSeg; s++) {
        final a0 = math.pi * (s / archSegs);
        final a1 = math.pi * ((s + 1) / archSegs);
        // Orient arch so outer wall is closed and inner crown curves over the track
        final z0 = zCenter + sgn * math.cos(a0) * tubeR;
        final y0 = y + 0.4 + math.sin(a0) * tubeR;
        final z1 = zCenter + sgn * math.cos(a1) * tubeR;
        final y1 = y + 0.4 + math.sin(a1) * tubeR;
        final archCol = s <= 2 ? col.withValues(alpha: 0.85) : (s.isEven ? const Color(0xFFCBD5E1) : const Color(0xFFBCC6D2));
        m.quad([-hL, y0, z0], [hL, y0, z0], [hL, y1, z1], [-hL, y1, z1], archCol);
      }

      // NATM ring ribs every 12m along the bored cavern
      for (var rx = -hL + 8; rx <= hL - 8; rx += 12) {
        final zOuter = zCenter + sgn * (tubeR - 0.15);
        m.box(rx - 0.22, y, math.min(zCenter, zOuter), rx + 0.22, y + 4.6, math.max(zCenter, zOuter), const Color(0xFF94A3B8), faces: 4 | 8);
      }

      _platformFurniture(m, -hL, hL, y, (zMin + zMax) / 2, col, plan.station.name);
    }

    lbs.add(Label3D(0, y + 5.6, 0, plan.architectureTitle, sub: 'Bağlantı tünelli ikiz peron', color: col, icon: Icons.view_in_ar_rounded));
    lbs.add(Label3D(24, y + 3.6, -zTube, 'Peron 1 · ${main.to}', color: col, dark: true));
    lbs.add(Label3D(24, y + 3.6, zTube, 'Peron 2 · ${main.from}', color: col, dark: true));
  }

  // ─────────────── 4. MONUMENTAL TRANSFER HUB & WATERFRONT CUT-AND-COVER (YENİKAPI / ÜSKÜDAR / TAKSİM) ───────────────

  void _buildMonumentalHubPlatform(Mesh m, List<Label3D> lbs, double y, Color col, RailVariant main) {
    final L = plan.platformLength;
    final hL = L / 2;
    const w = 15.5;
    const h = 8.4; // Double-height monumental hall

    // Main platform & tracks
    _buildCorePlatformAndTracks(m, hL, y, w, col);

    // Double colonnade of monumental columns + Coffered atrium ceiling beams
    for (var x = -hL + 10; x <= hL - 10; x += 14) {
      for (final z in plan.island ? [-3.4, 3.4] : [-7.2, 7.2]) {
        m.cylinder(x, z, y, y + h, 0.52, const Color(0xFFE2E8F0), seg: 12);
        // Line-coloured capital ring near top of column
        m.cylinder(x, z, y + h - 1.2, y + h - 0.7, 0.56, col, seg: 12);
      }
      // Coffered transverse ceiling beam across the monumental hall
      m.box(x - 0.35, y + h - 0.65, -w, x + 0.35, y + h, w, const Color(0xFFCBD5E1));
    }

    // Overlooking Mezzanine Transfer Gallery Bridge spanning across the tracks at y + 4.4m
    final yMezz = y + 4.4;
    for (final mx in [-26.0, 22.0]) {
      m.tiledFloor(mx - 6.5, -w + 1.0, mx + 6.5, w - 1.0, yMezz, 2.0, _floorA, _floorB);
      m.box(mx - 6.5, yMezz - 0.35, -w + 1.0, mx + 6.5, yMezz, w - 1.0, _conc);
      // Glass mezzanine balustrade overlooking the trains below
      m.box(mx - 6.5, yMezz, -w + 1.2, mx - 6.3, yMezz + 1.15, w - 1.2, const Color(0xFF38BDF8));
      m.box(mx + 6.3, yMezz, -w + 1.2, mx + 6.5, yMezz + 1.15, w - 1.2, const Color(0xFF38BDF8));
    }

    // Perimeter diaphragm walls with Iznik / mosaic heritage accent panels
    m.wallX(-hL, hL, y - 0.8, y + h, -w, 4.5, const Color(0xFFE2E8F0), _wallB);
    m.wallX(-hL, hL, y - 0.8, y + h, w, 4.5, const Color(0xFFE2E8F0), _wallB);
    m.quad([-hL, y + 2.2, -w + 0.05], [hL, y + 2.2, -w + 0.05], [hL, y + 2.75, -w + 0.05], [-hL, y + 2.75, -w + 0.05], col);
    m.quad([-hL, y + 2.2, w - 0.05], [-hL, y + 2.75, w - 0.05], [hL, y + 2.75, w - 0.05], [hL, y + 2.2, w - 0.05], col);

    if (!reveal) {
      m.tiledFloor(-hL, -w, hL, w, y + h, 6, const Color(0xFFCBD5E1), const Color(0xFF94A3B8));
    }

    final transfers = plan.station.lines.where((c) => c != plan.line.code).toList();
    if (transfers.isNotEmpty) {
      lbs.add(Label3D(22, yMezz + 2.2, 0, 'Aktarma Galerisi', sub: '${transfers.join(" · ")} bağlantısı', color: col, icon: Icons.swap_horiz_rounded));
    }
    lbs.add(Label3D(26, y + 3.6, -plan.trackZ, 'Peron 1 · ${main.to}', color: col, dark: true));
    lbs.add(Label3D(26, y + 3.6, plan.trackZ, 'Peron 2 · ${main.from}', color: col, dark: true));
  }

  // ─────────────── 5. MODERN UNDERGROUND METRO & FUNICULAR PLATFORMS ───────────────

  void _buildModernUndergroundPlatform(Mesh m, List<Label3D> lbs, double y, Color col, RailVariant main) {
    final L = plan.platformLength;
    final hL = L / 2;
    const w = 13.2;
    const h = 5.6;

    _buildCorePlatformAndTracks(m, hL, y, w, col);

    // Structural columns & continuous luminaire light strips
    for (var x = -hL + 9; x <= hL - 9; x += 12) {
      if (plan.island) {
        m.cylinder(x, -2.8, y, y + h, 0.36, const Color(0xFFCBD5E1));
        m.cylinder(x, 2.8, y, y + h, 0.36, const Color(0xFFCBD5E1));
      } else {
        m.cylinder(x, -6.2, y, y + h, 0.34, const Color(0xFFCBD5E1));
        m.cylinder(x, 6.2, y, y + h, 0.34, const Color(0xFFCBD5E1));
      }
      m.box(x - 0.22, y + h - 0.35, -w, x + 0.22, y + h, w, const Color(0xFF94A3B8));
    }

    // Cladding walls + line colour identity band
    m.wallX(-hL, hL, y - 0.8, y + h, -w, 4.0, const Color(0xFFE5EAF0), _wallB);
    m.wallX(-hL, hL, y - 0.8, y + h, w, 4.0, const Color(0xFFE5EAF0), _wallB);
    m.quad([-hL, y + 2.0, -w + 0.04], [hL, y + 2.0, -w + 0.04], [hL, y + 2.45, -w + 0.04], [-hL, y + 2.45, -w + 0.04], col);
    m.quad([-hL, y + 2.0, w - 0.04], [-hL, y + 2.45, w - 0.04], [hL, y + 2.45, w - 0.04], [hL, y + 2.0, w - 0.04], col);

    if (!reveal) {
      m.tiledFloor(-hL, -w, hL, w, y + h, 5, const Color(0xFFCBD5E1), const Color(0xFF94A3B8));
    }

    lbs.add(Label3D(24, y + 3.6, -plan.trackZ, 'Peron 1 · ${main.to}', color: col, dark: true));
    lbs.add(Label3D(24, y + 3.6, plan.trackZ, 'Peron 2 · ${main.from}', color: col, dark: true));
  }

  void _buildFunicularPlatform(Mesh m, List<Label3D> lbs, double y, Color col, RailVariant main) {
    final isHistoricTunel = plan.line.code == 'F2';
    final L = plan.platformLength;
    final hL = L / 2;
    const w = 8.5, h = 5.2;

    _buildCorePlatformAndTracks(m, hL, y, w, col);
    // Funicular haul cable & sheaves between the rails
    m.box(-hL - 10, y - 0.82, -0.06, hL + 10, y - 0.76, 0.06, const Color(0xFF0F172A));

    // Historic 1875 Karaköy–Beyoğlu Tünel has warm Ottoman brick masonry walls & vaulted arch ribs
    final wallA = isHistoricTunel ? const Color(0xFFB45309) : const Color(0xFFE5EAF0);
    final wallB = isHistoricTunel ? const Color(0xFF92400E) : _wallB;
    m.wallX(-hL, hL, y - 0.8, y + h, -w, 3.0, wallA, wallB);
    m.wallX(-hL, hL, y - 0.8, y + h, w, 3.0, wallA, wallB);
    for (var x = -hL + 6; x <= hL - 6; x += 8) {
      m.box(x - 0.25, y + h - 0.6, -w, x + 0.25, y + h, w, wallB);
    }
    lbs.add(Label3D(0, y + 4.4, 0, plan.architectureTitle, color: col, icon: Icons.train_rounded));
  }

  void _buildCorePlatformAndTracks(Mesh m, double hL, double y, double w, Color col) {
    const trackDrop = 0.95;
    if (plan.island) {
      const pw = 4.9;
      _tracks(m, -hL - 26, hL + 26, y - trackDrop, plan.trackZ);
      m.tiledFloor(-hL, -pw, hL, pw, y, 2.5, _floorA, _floorB);
      m.box(-hL, y - trackDrop, -pw, hL, y, pw, _conc, faces: 4 | 8 | 16 | 32);
      for (final sgn in [-1.0, 1.0]) {
        final tz = sgn * (pw - 0.45);
        m.quad([-hL + 1, y + 0.02, tz - 0.18], [hL - 1, y + 0.02, tz - 0.18], [hL - 1, y + 0.02, tz + 0.18],
            [-hL + 1, y + 0.02, tz + 0.18], _tactile);
        if (plan.hasPsd) {
          _platformScreenDoors(m, -hL + 3, hL - 3, y, sgn * (pw - 0.08), col);
        }
      }
      _platformFurniture(m, -hL, hL, y, 0, col, plan.station.name);
    } else {
      _tracks(m, -hL - 26, hL + 26, y - trackDrop, plan.trackZ);
      for (final sgn in [-1.0, 1.0]) {
        final zInner = sgn * 3.25, zOuter = sgn * (w - 0.2);
        final z0 = math.min(zInner, zOuter), z1 = math.max(zInner, zOuter);
        m.tiledFloor(-hL, z0, hL, z1, y, 2.5, _floorA, _floorB);
        m.box(-hL, y - trackDrop, z0, hL, y, z1, _conc, faces: 4 | 8 | 16 | 32);
        final tz = sgn * 3.65;
        m.quad([-hL + 1, y + 0.02, tz - 0.18], [hL - 1, y + 0.02, tz - 0.18], [hL - 1, y + 0.02, tz + 0.18],
            [-hL + 1, y + 0.02, tz + 0.18], _tactile);
        if (plan.hasPsd) {
          _platformScreenDoors(m, -hL + 3, hL - 3, y, sgn * 3.3, col);
        }
        _platformFurniture(m, -hL, hL, y, sgn * ((3.25 + w) / 2), col, plan.station.name);
      }
    }

    // Dark tunnel portals at both ends of the platform hall
    for (final sgn in [-1.0, 1.0]) {
      final tx = sgn * hL;
      for (final tz in [-plan.trackZ, plan.trackZ]) {
        m.box(tx, y - trackDrop, tz - 2.3, tx + sgn * 26, y + 3.9, tz + 2.3, const Color(0xFF0F172A), faces: 2 | 16 | 32);
      }
    }
  }

  /// Full-Height Automated Platform Screen Doors (PAKS / Peron Ayırıcı Kapı Sistemi) for M5, M7, M8, M11, F1, F4.
  void _platformScreenDoors(Mesh m, double x0, double x1, double y, double z, Color col) {
    const hDoor = 2.55, hHeader = 3.05;
    const glassPanel = Color(0xFF38BDF8);
    const frameDark = Color(0xFF1E293B);
    // Continuous header beam with line-colour LED strip
    m.box(x0, y + hDoor, z - 0.08, x1, y + hHeader, z + 0.08, frameDark);
    m.quad([x0, y + hDoor + 0.12, z - 0.09], [x1, y + hDoor + 0.12, z - 0.09], [x1, y + hDoor + 0.28, z - 0.09],
        [x0, y + hDoor + 0.28, z - 0.09], col,
        emissive: true);
    m.quad([x0, y + hDoor + 0.12, z + 0.09], [x0, y + hDoor + 0.28, z + 0.09], [x1, y + hDoor + 0.28, z + 0.09],
        [x1, y + hDoor + 0.12, z + 0.09], col,
        emissive: true);

    // Modular glass screen partitions & sliding door portals every 5.0m (matching metro door spacing)
    for (var x = x0; x < x1 - 4.5; x += 5.0) {
      // Fixed glass screen panel
      m.box(x, y, z - 0.05, x + 2.8, y + hDoor, z + 0.05, glassPanel);
      // Stainless door pillars flanking the 1.6m sliding door opening
      m.box(x + 2.8, y, z - 0.07, x + 3.05, y + hDoor, z + 0.07, const Color(0xFFCBD5E1));
      m.box(x + 4.65, y, z - 0.07, x + 4.90, y + hDoor, z + 0.07, const Color(0xFFCBD5E1));
      // Half-open sliding glass doors
      m.box(x + 3.05, y, z - 0.03, x + 3.55, y + hDoor - 0.1, z + 0.03, const Color(0xFF7DD3FC));
      m.box(x + 4.15, y, z - 0.03, x + 4.65, y + hDoor - 0.1, z + 0.03, const Color(0xFF7DD3FC));
    }
  }

  // ─────────────── STREET LEVEL WITH REAL OSM ENTRANCE PROJECTIONS ───────────────

  void _streetWithRealEntrances(Mesh m, List<Label3D> lbs, {required double xEntry, bool waterfront = false}) {
    final x0 = xEntry - 36, x1 = 44.0;
    const z0 = -36.0, z1 = 36.0;

    // Urban plaza & road surface
    m.tiledFloor(x0, z0, x1, z1, 0, 8, const Color(0xFFCBD5E1), const Color(0xFFBCC6D2));
    // Asphalt avenue along the station axis
    m.box(x0, 0.01, -18, x1, 0.03, -8, const Color(0xFF475569), faces: 1);
    for (var x = x0 + 4; x < x1 - 4; x += 9) {
      m.box(x, 0.04, -13.2, x + 4, 0.05, -12.8, const Color(0xFFF8FAFC), faces: 1, emissive: true);
    }

    // If waterfront (e.g. Üsküdar, Kadıköy, Kabataş), render Bosphorus / Marmara shoreline & sea along +Z!
    if (waterfront) {
      m.box(x0, -0.4, 18.0, x1, 0.45, 20.2, const Color(0xFF94A3B8)); // Stone seafront quay wall (Rıhtım)
      m.tiledFloor(x0, 20.2, x1, z1 + 18, -0.35, 10, const Color(0xFF0E4D6E), const Color(0xFF155E75));
      // Glass pyramid / atrium skylight on the waterfront square
      m.ramp(-18, 0.1, -6, 3.6, -4.5, 4.5, const Color(0xFF38BDF8));
      m.ramp(6, 0.1, -6, 3.6, -4.5, 4.5, const Color(0xFF38BDF8));
      lbs.add(const Label3D(0, 2.2, 26, 'Boğaz / Sahil Rıhtımı', sub: 'İskele & Meydan Kotu', icon: Icons.waves_rounded));
    }

    for (final z in [9.5, -21.0]) {
      for (var x = x0 + 10; x < x1 - 10; x += 24) {
        _tree(m, x, z);
      }
    }

    // Main Entrance Portal canopy + real OSM secondary entrance portals & elevators
    final col = plan.line.color;
    m.box(xEntry - 1.5, 0, -3.2, xEntry + 9.5, 1.15, -2.9, _steel);
    m.box(xEntry - 1.5, 0, 2.9, xEntry + 9.5, 1.15, 3.2, _steel);
    // Iconic Istanbul Metro "M" / "Marmaray" totem pylon at main entrance
    m.cylinder(xEntry - 2.6, -3.4, 0, 5.2, 0.18, _dark);
    m.box(xEntry - 3.3, 4.2, -4.1, xEntry - 1.9, 5.4, -2.7, col, emissive: true);

    final mainEntr = plan.projectedEntrances.first;
    lbs.add(Label3D(
      xEntry - 2.6,
      6.4,
      -3.4,
      '${plan.line.code == 'B1' ? 'Marmaray' : plan.line.code} · ${mainEntr.label}',
      sub: '${plan.entranceCount} OSM girişi${plan.station.elevators > 0 ? ' · ${plan.station.elevators} asansör' : ''}',
      color: col,
      icon: Icons.directions_subway_rounded,
    ));

    // Render additional real OSM entrance portals & street elevators around the plaza
    for (var i = 1; i < math.min(plan.projectedEntrances.length, 5); i++) {
      final e = plan.projectedEntrances[i];
      final ex = (xEntry + e.dx * 0.35).clamp(x0 + 6.0, x1 - 8.0);
      final ez = e.dz.clamp(-16.0, 15.0);
      if ((ex - xEntry).abs() < 6 && ez.abs() < 5) continue;
      if (e.wheelchair) {
        // Glass street elevator kiosk
        m.box(ex - 1.3, 0, ez - 1.3, ex + 1.3, 3.1, ez + 1.3, const Color(0xFF38BDF8), top: col);
      } else {
        // Secondary street entrance headhouse
        m.box(ex - 2.8, 0, ez - 1.6, ex + 2.8, 1.1, ez + 1.6, _steel, top: col);
      }
      if (i <= 2) {
        lbs.add(Label3D(ex, 3.8, ez, e.label, color: col, icon: e.wheelchair ? Icons.elevator_rounded : Icons.login_rounded));
      }
    }
  }

  void _tree(Mesh m, double x, double z) {
    m.cylinder(x, z, 0, 2.2, 0.22, const Color(0xFF78553A), seg: 6, cap: false);
    m.cylinder(x, z, 1.8, 4.6, 1.5, const Color(0xFF4D8B55), seg: 8);
    m.cylinder(x, z, 3.6, 5.6, 1.0, const Color(0xFF5FA068), seg: 8);
  }

  void _entranceEscalator(Mesh m, double xTop, double yTop, double xBot, double yBot, Color col) {
    m.box(xTop, yBot - 0.5, -3.2, xBot, yTop - 0.2, -2.7, _conc);
    m.box(xTop, yBot - 0.5, 2.7, xBot, yTop - 0.2, 3.2, _conc);
    m.ramp(xTop, yTop, xBot, yBot, -2.6, -0.3, _steel, steps: 18, alt: _dark);
    m.ramp(xTop, yTop, xBot, yBot, 0.3, 2.6, const Color(0xFFB8C1CC), steps: 18, alt: _conc);
    for (final z in [-2.65, -0.25, 0.25, 2.65]) {
      m.ramp(xTop, yTop + 0.9, xBot, yBot + 0.9, z - 0.08, z + 0.08, col);
    }
  }

  void _passageWithBranches(Mesh m, double x0, double x1, double y, Color col) {
    const w = 4.6, h = 3.5;
    m.tiledFloor(x0, -w, x1, w, y, 2.0, _floorA, _floorB);
    m.wallX(x0, x1, y, y + h, -w, 3.0, const Color(0xFFE5EAF0), _wallB);
    m.wallX(x0, x1, y, y + h, w, 3.0, const Color(0xFFE5EAF0), _wallB);
    // Yellow tactile guidance line
    m.quad([x0, y + 0.02, -0.25], [x1, y + 0.02, -0.25], [x1, y + 0.02, 0.25], [x0, y + 0.02, 0.25], _tactile);
    // Side branch corridors representing additional OSM entrances joining the concourse
    if (plan.entranceCount >= 3) {
      final xm = (x0 + x1) / 2;
      m.tiledFloor(xm - 2.5, w, xm + 2.5, w + 9.0, y, 2.0, _floorA, _floorB);
      if (plan.entranceCount >= 4) {
        m.tiledFloor(xm - 2.5, -w - 9.0, xm + 2.5, -w, y, 2.0, _floorA, _floorB);
      }
    }
    if (!reveal) m.tiledFloor(x0, -w, x1, w, y + h, 3, _wallB, _conc);
  }

  void _concourse(Mesh m, List<Label3D> lbs, double x0, double x1, double y, Color col) {
    final w = plan.archetype == StationArchetype.monumentalTransferHub ? 12.5 : 9.8;
    const h = 4.4;
    m.tiledFloor(x0, -w, x1, w, y, 2.5, _floorA, _floorB);
    m.box(x0, y - 0.6, -w, x1, y, w, _conc, faces: 2 | 4 | 8 | 16 | 32);
    m.wallX(x0, x1, y, y + h, -w, 3.5, const Color(0xFFE5EAF0), _wallB);
    m.wallX(x0, x1, y, y + h, w, 3.5, const Color(0xFFE5EAF0), _wallB);
    if (!reveal) m.tiledFloor(x0, -w, x1, w, y + h, 4, _wallB, _conc);

    for (var x = x0 + 6; x < x1 - 4; x += 9) {
      m.cylinder(x, -w + 2.2, y, y + h, 0.38, _conc);
      m.cylinder(x, w - 2.2, y, y + h, 0.38, _conc);
    }

    // Blue İstanbulkart Biletmatik vending machines
    for (var k = 0; k < 3; k++) {
      final bx = x0 + 5 + k * 2.4;
      m.box(bx, y, -w + 0.25, bx + 1.4, y + 2.1, -w + 1.05, const Color(0xFF1D4ED8), top: const Color(0xFF60A5FA));
      m.quad([bx + 0.18, y + 1.0, -w + 1.07], [bx + 1.22, y + 1.0, -w + 1.07], [bx + 1.22, y + 1.75, -w + 1.07],
          [bx + 0.18, y + 1.75, -w + 1.07], const Color(0xFFBAE6FD),
          emissive: true);
    }

    // Security X-ray baggage scanner & walk-through metal detector
    final xs = plan.xSecurity;
    m.box(xs - 1.6, y, -3.5, xs + 1.6, y + 1.2, -1.7, const Color(0xFF475569), top: _steel);
    m.box(xs - 0.7, y + 1.2, -3.3, xs + 0.7, y + 2.0, -1.9, const Color(0xFF334155));
    m.box(xs - 0.25, y, -1.2, xs + 0.25, y + 2.2, -1.0, _steel);
    m.box(xs - 0.25, y, 0.4, xs + 0.25, y + 2.2, 0.6, _steel);
    m.box(xs - 0.25, y + 2.0, -1.2, xs + 0.25, y + 2.25, 0.6, col);
    lbs.add(Label3D(xs, y + 3.4, -1.5, 'Güvenlik & X-Ray', sub: '−${(-y).round()} m Konkors', icon: Icons.shield_outlined));

    _fareGates(m, plan.xGates, y, col);
    lbs.add(Label3D(plan.xGates, y + 3.4, 2.0, 'Turnikeler', sub: 'İstanbulkart · QR', icon: Icons.credit_card_rounded));
  }

  void _fareGates(Mesh m, double x, double y, Color col) {
    for (var k = -3; k <= 3; k++) {
      final z = k * 1.45;
      m.box(x - 0.85, y, z - 0.16, x + 0.85, y + 1.05, z + 0.16, _steel, top: const Color(0xFFF8FAFC));
      m.box(x - 0.75, y + 1.05, z - 0.12, x - 0.42, y + 1.12, z + 0.12, const Color(0xFFF59E0B), emissive: true);
      if (k < 3) {
        m.box(x - 0.05, y + 0.15, z + 0.22, x + 0.05, y + 0.9, z + 0.62, const Color(0xFFEF4444));
      }
    }
  }

  void _escalatorBank(Mesh m, double xTop, double yTop, double xBot, double yBot, Color col) {
    const w = 4.6;
    m.box(xTop, yBot - 0.8, -w, xBot, yTop, -w + 0.45, _conc);
    m.box(xTop, yBot - 0.8, w - 0.45, xBot, yTop, w, _conc);
    final steps = ((yTop - yBot).abs() * 2.5).round().clamp(14, 52);
    // 3 parallel escalators + central staircase
    m.ramp(xTop, yTop, xBot, yBot, -3.9, -2.1, _steel, steps: steps, alt: _dark);
    m.ramp(xTop, yTop, xBot, yBot, -1.7, 0.1, const Color(0xFFB8C1CC), steps: steps, alt: _conc);
    m.ramp(xTop, yTop, xBot, yBot, 0.5, 2.2, _steel, steps: steps, alt: _dark);
    m.ramp(xTop, yTop, xBot, yBot, 2.5, 3.9, _steel, steps: steps, alt: _dark);
    for (final z in [-4.0, -2.0, 0.3, 2.35, 4.0]) {
      m.ramp(xTop, yTop + 0.95, xBot, yBot + 0.95, z - 0.09, z + 0.09, col);
    }

    // Intermediate transfer landing ring for ultra-deep stations (Sirkeci -60m, Gayrettepe -72m, Yıldız -71m, Şişhane -45m)
    if ((yTop - yBot).abs() >= 24) {
      final xm = (xTop + xBot) / 2, ym = (yTop + yBot) / 2;
      m.box(xm - 3.5, ym - 0.6, -w - 1.2, xm + 3.5, ym + 3.6, w + 1.2, const Color(0xFFCBD5E1), faces: 4 | 8);
    }
  }

  void _platformFurniture(Mesh m, double x0, double x1, double y, double zCenter, Color col, String name) {
    for (var x = x0 + 18; x <= x1 - 18; x += 26) {
      // Modern bench
      m.box(x - 1.9, y, zCenter - 0.5, x + 1.9, y + 0.52, zCenter + 0.5, col);
      // Illuminated station name totem & passenger information display
      m.cylinder(x + 6, zCenter, y, y + 2.8, 0.10, _dark, seg: 6);
      m.box(x + 4.7, y + 2.15, zCenter - 0.16, x + 7.3, y + 2.75, zCenter + 0.16, col);
    }
  }

  void _singleTrack(Mesh m, double x0, double x1, double y, double zc) {
    m.box(x0, y - 0.2, zc - 1.6, x1, y, zc + 1.6, const Color(0xFF334155), faces: 1);
    for (var x = x0; x < x1; x += 3.0) {
      m.box(x, y, zc - 1.2, x + 0.4, y + 0.08, zc + 1.2, const Color(0xFF475569), faces: 1);
    }
    for (final r in [-0.72, 0.72]) {
      m.box(x0, y + 0.08, zc + r - 0.06, x1, y + 0.2, zc + r + 0.06, const Color(0xFF94A3B8), faces: 1 | 4 | 8);
    }
  }

  void _tracks(Mesh m, double x0, double x1, double y, double zAbs) {
    for (final sgn in [-1.0, 1.0]) {
      _singleTrack(m, x0, x1, y, sgn * zAbs);
    }
  }

  void _buildSurfaceOrViaduct(Mesh m, List<Label3D> lbs, List<(double, double, double, StationStage, bool)> pts) {
    final p = plan;
    final L = p.platformLength;
    final hL = L / 2;
    final y = p.yPlatform;
    final col = p.line.color;
    final main = p.line.variants.first;

    // Urban street boulevard below
    m.tiledFloor(-hL - 25, -32, hL + 25, 32, 0, 8, const Color(0xFFCBD5E1), const Color(0xFFBCC6D2));
    if (p.elevated) {
      // Concrete box-girder viaduct & flared hammerhead piers
      m.box(-hL - 20, y - 1.8, -11.5, hL + 20, y - 0.8, 11.5, _conc);
      for (var x = -hL; x <= hL; x += 22) {
        m.box(x - 1.4, 0, -4.2, x + 1.4, y - 1.8, 4.2, _conc);
        // Arched steel-and-glass viaduct canopy ribs
        for (final sgn in [-1.0, 1.0]) {
          m.box(x - 0.22, y, sgn * 10.6, x + 0.22, y + 4.4, sgn * 11.0, _steel);
        }
        m.box(x - 0.22, y + 4.4, -11.0, x + 0.22, y + 4.8, 11.0, col);
      }
      // Ground-level ticket concourse under viaduct + escalator up to elevated platform
      _fareGates(m, -14, 0, col);
      m.ramp(-12, 0, -2, y, -2.0, 2.0, _steel, steps: 20, alt: _dark);
      pts.add((-24, 0, 0, StationStage.street, false));
      pts.add((-14, 0, 0, StationStage.gates, false));
      pts.add((-7, y / 2, 0, StationStage.escalators, true));
      pts.add((0, y, 0, StationStage.platform, false));
      lbs.add(const Label3D(-14, 3.0, 0, 'Zemin Kat Turnike Holü', sub: 'Viyadük altı giriş', icon: Icons.credit_card_rounded));
    } else {
      pts.add((-20, y, -6, StationStage.street, false));
      pts.add((-8, y, -4, StationStage.gates, false));
      pts.add((6, y, 0, StationStage.platform, false));
    }

    _buildCorePlatformAndTracks(m, hL, y, 11.2, col);
    lbs.add(Label3D(0, y + 5.2, 0, p.architectureTitle, color: col));
    lbs.add(Label3D(16, y + 3.2, -p.trackZ, '→ ${main.to}', color: col, dark: true));
    lbs.add(Label3D(16, y + 3.2, p.trackZ, '→ ${main.from}', color: col, dark: true));
  }

  /// Train mesh for a station's line, sized to the platform.
  static Mesh trainModelFor(StationPlan plan) {
    final c = plan.line.code;
    final kind = switch (plan.line.mode) {
      RailMode.suburban => VehicleKind.marmaray,
      RailMode.metro => (c == 'M5' || c == 'M7' || c == 'M8' || c == 'M11') ? VehicleKind.metroDriverless : VehicleKind.metro,
      RailMode.tram => (c == 'T2' || c == 'T3') ? VehicleKind.nostalgicTram : VehicleKind.tram,
      RailMode.funicular => VehicleKind.funicular,
      RailMode.cable => VehicleKind.cable,
    };
    final cars = switch (plan.line.mode) {
      RailMode.suburban => 5,
      RailMode.metro => c == 'M6' ? 2 : 4,
      RailMode.tram => (c == 'T2' || c == 'T3') ? 1 : 4,
      _ => 2,
    };
    return VehicleModels.build(kind, accent: plan.line.color, cars: cars);
  }

  /// Places a train on the track for direction [dir] (+1 or −1) at [offsetM] along the track.
  static Mesh? trainAt(StationPlan plan, int dir, double offsetM, Mesh model) {
    final limit = plan.platformLength * 0.85;
    if (offsetM.abs() > limit) return null;
    final m = Mesh();
    final z = (dir >= 0 ? -1 : 1) * plan.trackZ;
    final x = dir >= 0 ? offsetM : -offsetM;
    final yaw = dir >= 0 ? 0.0 : math.pi;
    m.addTransformed(model, x, plan.yPlatform - 0.8, z, yaw: yaw);
    return m;
  }
}
