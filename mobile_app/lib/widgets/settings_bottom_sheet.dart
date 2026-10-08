import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/transit_provider.dart';
import '../theme/app_theme.dart';

class SettingsBottomSheet extends StatefulWidget {
  final TransitProvider provider;
  final VoidCallback onClose;

  const SettingsBottomSheet({
    super.key,
    required this.provider,
    required this.onClose,
  });

  @override
  State<SettingsBottomSheet> createState() => _SettingsBottomSheetState();
}

class _SettingsBottomSheetState extends State<SettingsBottomSheet> {
  int _selectedTab = 0; // 0: Ayarlar, 1: Hakkında, 2: Destek & Bağış

  @override
  Widget build(BuildContext context) {
    final isNight = widget.provider.isNightMode;
    final bg = isNight ? const Color(0xFF0D1117) : AppTheme.surface;
    final border = isNight ? Colors.white.withValues(alpha: 0.12) : AppTheme.borderLight;
    final textPrimary = isNight ? Colors.white : AppTheme.textPrimary;
    final textSecondary = isNight ? Colors.white70 : AppTheme.textSecondary;

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(32),
          topRight: Radius.circular(32),
        ),
        border: Border.all(color: border, width: 1.2),
        boxShadow: AppTheme.sheetShadow,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            // Drag handle
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: isNight ? Colors.white24 : AppTheme.borderMedium,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Top Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0284C7).withValues(alpha: 0.18),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.settings_rounded,
                          color: Color(0xFF38BDF8),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Ayarlar & Tercihler',
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ],
                  ),
                  GestureDetector(
                    onTap: widget.onClose,
                    child: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: isNight ? Colors.white10 : AppTheme.background,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Tab Switcher Pills (Ayarlar | Hakkında | Bağış)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: isNight ? Colors.white.withValues(alpha: 0.06) : AppTheme.lightGray,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: border),
                ),
                child: Row(
                  children: [
                    _buildTabButton(0, 'Tercihler', Icons.tune_rounded),
                    _buildTabButton(1, 'Hakkında', Icons.info_outline_rounded),
                    _buildTabButton(2, 'Bağış & Destek', Icons.favorite_rounded, isHeart: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Tab Content
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: _buildTabContent(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton(int index, String label, IconData icon, {bool isHeart = false}) {
    final isSelected = _selectedTab == index;
    final isNight = widget.provider.isNightMode;

    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedTab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? (isNight ? Colors.white : AppTheme.accentBlack)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 6,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: isSelected
                    ? (isHeart ? const Color(0xFFEF4444) : (isNight ? AppTheme.surfaceDark : Colors.white))
                    : (isHeart ? const Color(0xFFF87171) : (isNight ? Colors.white70 : AppTheme.textSecondary)),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? (isNight ? AppTheme.surfaceDark : Colors.white)
                      : (isNight ? Colors.white70 : AppTheme.textSecondary),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_selectedTab) {
      case 0:
        return _buildPreferencesSection();
      case 1:
        return _buildAboutSection();
      case 2:
        return _buildDonationSection();
      default:
        return const SizedBox.shrink();
    }
  }

  // 1. TERCIHLER / PREFERENCES SECTION
  Widget _buildPreferencesSection() {
    final p = widget.provider;
    final isNight = p.isNightMode;
    final textPrimary = isNight ? Colors.white : AppTheme.textPrimary;
    final textSecondary = isNight ? Colors.white70 : AppTheme.textSecondary;
    final cardBg = isNight ? Colors.white.withValues(alpha: 0.05) : AppTheme.lightGray;
    final border = isNight ? Colors.white.withValues(alpha: 0.08) : AppTheme.borderLight;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tema Seçimi (Karanlık / Aydınlık Mod)
        _buildSectionHeader('Görünüm & Tema Modu'),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: border),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        isNight ? Icons.nightlight_round : Icons.wb_sunny_rounded,
                        color: isNight ? const Color(0xFFFEF08A) : const Color(0xFFF59E0B),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isNight ? 'Karanlık Mod (Varsayılan)' : 'Aydınlık Mod',
                            style: TextStyle(
                              color: textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            isNight ? 'Carto Dark All yüksek kontrast' : 'Carto Light All harita katmanı',
                            style: TextStyle(
                              color: textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Switch.adaptive(
                    value: isNight,
                    onChanged: (_) => p.toggleNightMode(),
                    activeThumbColor: const Color(0xFF0284C7),
                    activeTrackColor: const Color(0xFF0284C7).withValues(alpha: 0.5),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Otomatik Güncelleme & Canlı Akış
        _buildSectionHeader('Canlı GPS & Otomatik Güncelleme'),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: border),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.sync_rounded,
                        color: Color(0xFF10B981),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Otomatik Canlı Senkronizasyon',
                            style: TextStyle(
                              color: textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            p.autoRefreshEnabled ? 'Arka planda canlı GPS verileri yenileniyor' : 'Yalnızca manuel yenileme',
                            style: TextStyle(
                              color: textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Switch.adaptive(
                    value: p.autoRefreshEnabled,
                    onChanged: (val) => p.toggleAutoRefresh(val),
                    activeThumbColor: const Color(0xFF10B981),
                    activeTrackColor: const Color(0xFF10B981).withValues(alpha: 0.5),
                  ),
                ],
              ),
              if (p.autoRefreshEnabled) ...[
                const Divider(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Yenileme Aralığı:',
                      style: TextStyle(
                        color: textSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Row(
                      children: [10, 15, 30].map((sec) {
                        final isSel = p.refreshIntervalSec == sec;
                        return Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: GestureDetector(
                            onTap: () => p.setRefreshInterval(sec),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: isSel ? const Color(0xFF0284C7) : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isSel ? const Color(0xFF0284C7) : border,
                                ),
                              ),
                              child: Text(
                                '${sec}s',
                                style: TextStyle(
                                  color: isSel ? Colors.white : textSecondary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11.5,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Harita Görünüm Seçenekleri
        _buildSectionHeader('Harita Katmanları & Detaylar'),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: border),
          ),
          child: Column(
            children: [
              _buildSmallToggle(
                'Otobüs Durakları İkonları',
                'Tüm İETT duraklarını haritada göster',
                p.showBusStops,
                (_) => p.toggleBusStops(),
              ),
              const Divider(height: 18),
              _buildSmallToggle(
                'Raylı Sistem Hatları',
                'Metro, Tramvay ve Marmaray ray güzergahları',
                p.showMetroLines,
                (_) => p.toggleMetroLines(),
              ),
              const Divider(height: 18),
              _buildSmallToggle(
                'Simüle Edilen Metro Trenleri',
                '60 FPS kinematik hareketli trenler',
                p.showMetroTrains,
                (_) => p.toggleMetroTrains(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildSmallToggle(String title, String desc, bool val, ValueChanged<bool> onChange) {
    final isNight = widget.provider.isNightMode;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: isNight ? Colors.white : AppTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              Text(
                desc,
                style: TextStyle(
                  color: isNight ? Colors.white60 : AppTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        Switch.adaptive(
          value: val,
          onChanged: onChange,
          activeThumbColor: const Color(0xFF0284C7),
          activeTrackColor: const Color(0xFF0284C7).withValues(alpha: 0.5),
        ),
      ],
    );
  }

  // 2. HAKKINDA / ABOUT SECTION
  Widget _buildAboutSection() {
    final isNight = widget.provider.isNightMode;
    final textSecondary = isNight ? Colors.white70 : AppTheme.textSecondary;
    final cardBg = isNight ? Colors.white.withValues(alpha: 0.05) : AppTheme.lightGray;
    final border = isNight ? Colors.white.withValues(alpha: 0.08) : AppTheme.borderLight;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // App branding card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF0C2444), Color(0xFF0A192F)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF1E3A8A).withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF0284C7), Color(0xFF38BDF8)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0284C7).withValues(alpha: 0.4),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Icon(Icons.directions_bus_rounded, color: Colors.white, size: 24),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'İstanbul Bizim',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.4,
                        ),
                      ),
                      Text(
                        'Versiyon 1.2.0 • Ultra-Hızlı Canlı Ulaşım',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'İstanbul Bizim, İBB Açık Veri Portalı ve İETT canlı filo GPS ağını doğrudan işleyerek, hiçbir reklam veya hantal arayüz olmadan anlık otobüs ve metro takibi sunan açık kaynaklı bir topluluk projesidir.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        _buildSectionHeader('Veri Kaynakları & Altyapı'),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: border),
          ),
          child: Column(
            children: [
              _buildDataRow(Icons.cloud_done_rounded, 'İETT Filo Durum GPS', 'Canlı SOAP Gerçekleşme Servisi'),
              const Divider(height: 16),
              _buildDataRow(Icons.schedule_rounded, 'İBB Açık Veri Portalı', 'Resmi Planlanan Sefer Saatleri (data.ibb.gov.tr)'),
              const Divider(height: 16),
              _buildDataRow(Icons.subway_rounded, 'Metro İstanbul', 'Resmi Hat Güzergahları ve İstasyon Listesi'),
              const Divider(height: 16),
              _buildDataRow(Icons.map_rounded, 'CARTO Basemaps', 'Yüksek Çözünürlüklü Retina Vektör Harita Katmanı'),
            ],
          ),
        ),
        const SizedBox(height: 16),

        _buildSectionHeader('Çevrimdışı ve Önbellek Özelliği'),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.offline_pin_rounded, color: Color(0xFF10B981), size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Tüm hat güzergahları, durak listeleri, son canlı araç konumları ve sefer tarifeleri cihazınızda güvenle önbelleğe alınır. İnternet kesilse bile son veriler ve tarifeler kesintisiz olarak görüntülenebilir.',
                  style: TextStyle(
                    color: textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildDataRow(IconData icon, String title, String subtitle) {
    final isNight = widget.provider.isNightMode;
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF38BDF8)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: isNight ? Colors.white : AppTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: isNight ? Colors.white60 : AppTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 3. BAGIS & DESTEK / DONATION SECTION
  Widget _buildDonationSection() {
    final isNight = widget.provider.isNightMode;
    final textSecondary = isNight ? Colors.white70 : AppTheme.textSecondary;
    final cardBg = isNight ? Colors.white.withValues(alpha: 0.05) : AppTheme.lightGray;
    final border = isNight ? Colors.white.withValues(alpha: 0.08) : AppTheme.borderLight;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Gratitude Banner
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF831843), Color(0xFF4C0519)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF831843).withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.volunteer_activism_rounded, color: Color(0xFFF472B6), size: 26),
                  SizedBox(width: 10),
                  Text(
                    'Projeyi Destekleyin',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'İstanbul Bizim tamamen ücretsiz, reklamsız ve açık kaynaklıdır. Sunucu, Cloudflare Workers ve API altyapı giderlerini karşılamamıza bir kahve ısmarlayarak destek olabilirsiniz! ☕',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        _buildSectionHeader('Destek Seçenekleri'),

        // Buy Me a Coffee / Patreon Option
        _buildDonationCard(
          title: 'Bir Kahve Ismarla (Buy Me a Coffee)',
          subtitle: 'buymeacoffee.com/istanbulbizim',
          icon: Icons.coffee_rounded,
          color: const Color(0xFFF59E0B),
          copyValue: 'https://buymeacoffee.com/istanbulbizim',
        ),
        const SizedBox(height: 10),

        // GitHub Sponsors
        _buildDonationCard(
          title: 'GitHub Sponsors',
          subtitle: 'github.com/sponsors/istanbulbizim',
          icon: Icons.code_rounded,
          color: const Color(0xFFA855F7),
          copyValue: 'https://github.com/sponsors/istanbulbizim',
        ),
        const SizedBox(height: 10),

        // Kripto Destek (TRC20 / USDT)
        _buildDonationCard(
          title: 'USDT (TRC-20) Kripto Bağışı',
          subtitle: 'TZ1a...9K8x (Kopyalamak için dokunun)',
          icon: Icons.currency_bitcoin_rounded,
          color: const Color(0xFF10B981),
          copyValue: 'TZ1a9K8xIstanbulBizimDonationWallet2026',
        ),
        const SizedBox(height: 16),

        // Transparency note
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: border),
          ),
          child: Row(
            children: [
              const Icon(Icons.favorite_rounded, color: Color(0xFFEF4444), size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Toplanan tüm bağışlar doğrudan Cloudflare sunucu masrafları, domain yenilemeleri ve harita kotaları için kullanılmaktadır. Desteğiniz için teşekkür ederiz! ❤️',
                  style: TextStyle(
                    color: textSecondary,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _buildDonationCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required String copyValue,
  }) {
    final isNight = widget.provider.isNightMode;
    final cardBg = isNight ? Colors.white.withValues(alpha: 0.06) : AppTheme.lightGray;
    final border = isNight ? Colors.white.withValues(alpha: 0.10) : AppTheme.borderMedium;

    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: copyValue));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text('Kopyalandı: $copyValue')),
              ],
            ),
            duration: const Duration(seconds: 2),
            backgroundColor: AppTheme.accentBlack,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isNight ? Colors.white : AppTheme.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: isNight ? Colors.white60 : AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: isNight ? Colors.white12 : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.copy_rounded, size: 12, color: isNight ? Colors.white70 : AppTheme.textPrimary),
                  const SizedBox(width: 4),
                  Text(
                    'Kopyala',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: isNight ? Colors.white70 : AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    final isNight = widget.provider.isNightMode;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: isNight ? Colors.white60 : AppTheme.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
