import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/transit_models.dart';
import '../services/transit_provider.dart';
import '../theme/app_theme.dart';

/// Modern, original bottom sheet displaying real-time approaching buses,
/// passing lines, and stop metadata for "İstanbul Bizim".
class BusStopDetailSheet extends StatefulWidget {
  final BusStop stop;
  final TransitProvider provider;
  final VoidCallback onClose;
  final Function(String) onSelectLine;
  final VoidCallback? onOpenAr;

  const BusStopDetailSheet({
    super.key,
    required this.stop,
    required this.provider,
    required this.onClose,
    required this.onSelectLine,
    this.onOpenAr,
  });

  @override
  State<BusStopDetailSheet> createState() => _BusStopDetailSheetState();
}

class _BusStopDetailSheetState extends State<BusStopDetailSheet> {
  List<StopArrival>? _arrivals;
  List<String> _passingLines = [];
  String? _selectedLineFilter; // null = Tümü
  bool _loading = true;
  Timer? _refreshTimer;
  final ScrollController _chipScrollController = ScrollController();

  BusStop get stop => widget.stop;
  TransitProvider get provider => widget.provider;
  VoidCallback get onClose => widget.onClose;
  Function(String) get onSelectLine => widget.onSelectLine;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void didUpdateWidget(BusStopDetailSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stop.code != widget.stop.code) {
      _arrivals = null;
      _selectedLineFilter = null;
      _loading = true;
      _load();
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _chipScrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final code = stop.code;
    final lines = provider.getPassingLinesForStop(stop);
    final res = await provider.loadStopArrivals(stop, lineFilter: _selectedLineFilter);
    if (!mounted || code != stop.code) return;
    setState(() {
      _passingLines = lines;
      _arrivals = res;
      _loading = false;
    });
  }

  void _selectFilter(String? line) {
    if (_selectedLineFilter == line) return;
    HapticFeedback.selectionClick();
    setState(() {
      _selectedLineFilter = line;
      _loading = true;
    });
    _load();
  }

  Future<void> _openDirections() async {
    HapticFeedback.lightImpact();
    final url = Uri.parse('https://maps.google.com/?q=${stop.lat},${stop.lon}');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final arrivals = _arrivals ?? [];
    final visibleArrivals = _selectedLineFilter == null
        ? arrivals
        : arrivals.where((a) => a.line == _selectedLineFilter).toList();

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.74,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0F141C),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10), width: 1.0),
        boxShadow: const [
          BoxShadow(
            color: Color(0x99000000),
            blurRadius: 32,
            spreadRadius: 0,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header Section
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildHeader(),
            ),

            const SizedBox(height: 12),

            // Action Buttons Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildActionRow(),
            ),

            const SizedBox(height: 14),

            // Passing Lines Horizontal Carousel
            if (_passingLines.isNotEmpty) ...[
              _buildPassingLinesSection(arrivals),
              const SizedBox(height: 14),
            ],

            // Approaching Vehicles Section Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildArrivalsHeader(visibleArrivals.length),
            ),

            const SizedBox(height: 8),

            // Approaching Vehicles List or State
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _buildArrivalsContent(visibleArrivals),
              ),
            ),

            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// Stop identity: bus stop badge, name, code, direction chip & close button
  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Stop Icon Badge
        Container(
          width: 44,
          height: 44,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0284C7), Color(0xFF025A8E)],
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0284C7).withValues(alpha: 0.25),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: const Icon(
            Icons.directions_bus_rounded,
            color: Colors.white,
            size: 24,
          ),
        ),
        const SizedBox(width: 12),

        // Stop Name, District, Code & Direction
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stop.name,
                style: const TextStyle(
                  color: AppTheme.textLight,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  letterSpacing: -0.2,
                  height: 1.2,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),

              // Badges Row: District & Stop Code
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (stop.district.isNotEmpty)
                    Text(
                      stop.district,
                      style: const TextStyle(
                        color: AppTheme.textMutedDark,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: Text(
                      'Durak: ${stop.code}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        color: Color(0xFF38BDF8),
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  if (stop.direction.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF06B6D4).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.navigation_rounded, size: 9.5, color: Color(0xFF06B6D4)),
                          const SizedBox(width: 3),
                          Text(
                            stop.direction,
                            style: const TextStyle(
                              color: Color(0xFF06B6D4),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(width: 8),

        // Close button
        GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            onClose();
          },
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 32,
            height: 32,
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
    );
  }

  /// Action buttons: Directions & AR navigation
  Widget _buildActionRow() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _openDirections,
            icon: const Icon(Icons.near_me_rounded, size: 15, color: Colors.white),
            label: const Text(
              'Yol Tarifi Al',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        if (widget.onOpenAr != null) ...[
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () {
              HapticFeedback.lightImpact();
              widget.onOpenAr!();
            },
            icon: const Icon(Icons.view_in_ar_rounded, size: 15, color: Color(0xFF38BDF8)),
            label: const Text(
              'AR Yön',
              style: TextStyle(
                color: Color(0xFF38BDF8),
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF38BDF8),
              side: BorderSide(color: const Color(0xFF38BDF8).withValues(alpha: 0.35)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// "Geçen Hatlar" section with interactive line pills
  Widget _buildPassingLinesSection(List<StopArrival> arrivals) {
    final activeLinesWithArrivals = arrivals.map((a) => a.line).toSet();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Text(
                'Geçen Hatlar',
                style: TextStyle(
                  color: AppTheme.textLight,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  letterSpacing: -0.1,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${_passingLines.length}',
                  style: const TextStyle(
                    color: AppTheme.textMutedDark,
                    fontWeight: FontWeight.w700,
                    fontSize: 10.5,
                  ),
                ),
              ),
              const Spacer(),
              if (_selectedLineFilter != null)
                GestureDetector(
                  onTap: () => _selectFilter(null),
                  child: const Text(
                    'Tümünü Göster',
                    style: TextStyle(
                      color: Color(0xFF38BDF8),
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Horizontal Line Pills
        SizedBox(
          height: 36,
          child: ListView.builder(
            controller: _chipScrollController,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _passingLines.length + 1,
            itemBuilder: (context, idx) {
              if (idx == 0) {
                final isSelected = _selectedLineFilter == null;
                return _buildFilterPill(
                  label: 'Tümü',
                  hasLiveVehicle: activeLinesWithArrivals.isNotEmpty,
                  isSelected: isSelected,
                  accentColor: const Color(0xFF0284C7),
                  onTap: () => _selectFilter(null),
                );
              }
              final line = _passingLines[idx - 1];
              final isSelected = _selectedLineFilter == line;
              final hasLive = activeLinesWithArrivals.contains(line);
              final accentColor = AppTheme.lineColor(line);

              return _buildFilterPill(
                label: line,
                hasLiveVehicle: hasLive,
                isSelected: isSelected,
                accentColor: accentColor,
                onTap: () => _selectFilter(line),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFilterPill({
    required String label,
    required bool hasLiveVehicle,
    required bool isSelected,
    required Color accentColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? accentColor.withValues(alpha: 0.22)
              : const Color(0xFF161B24),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? accentColor
                : Colors.white.withValues(alpha: 0.10),
            width: isSelected ? 1.4 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasLiveVehicle && !isSelected) ...[
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 5),
                decoration: const BoxDecoration(
                  color: Color(0xFF10B981),
                  shape: BoxShape.circle,
                ),
              ),
            ],
            Text(
              label,
              style: TextStyle(
                fontFamily: label == 'Tümü' ? null : 'monospace',
                color: isSelected ? Colors.white : AppTheme.textLight,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Section Header for Approaching Vehicles
  Widget _buildArrivalsHeader(int count) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF10B981),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF10B981).withValues(alpha: 0.6),
                blurRadius: 6,
              ),
            ],
          ),
        ),
        const Text(
          'Yaklaşan Araçlar',
          style: TextStyle(
            color: AppTheme.textLight,
            fontWeight: FontWeight.w700,
            fontSize: 13,
            letterSpacing: -0.1,
          ),
        ),
        const SizedBox(width: 6),
        if (count > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count Canlı',
              style: const TextStyle(
                color: Color(0xFF10B981),
                fontWeight: FontWeight.w700,
                fontSize: 10.5,
              ),
            ),
          ),
        const Spacer(),
        // Small active pulse indicator
        const Text(
          'Canlı Takip',
          style: TextStyle(
            color: AppTheme.textMutedDark,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  /// Body list of vehicles, loading state, or empty state
  Widget _buildArrivalsContent(List<StopArrival> visibleArrivals) {
    if (_loading && _arrivals == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
            ),
            SizedBox(width: 10),
            Flexible(
              child: Text(
                'Canlı filo taranıyor, yaklaşan araçlar hesaplanıyor…',
                style: TextStyle(
                  color: AppTheme.textMutedDark,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    if (visibleArrivals.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.radar_rounded,
              size: 28,
              color: Colors.white.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 8),
            Text(
              _selectedLineFilter != null
                  ? '$_selectedLineFilter hattında şu anda bu durağa yaklaşan araç bulunmuyor.'
                  : 'Bu duraktan geçen hatlarda şu anda yaklaşan aktif canlı araç tespit edilmedi.',
              style: const TextStyle(
                color: AppTheme.textMutedDark,
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'Yukarıdaki hat listesinden bir hatta dokunarak güzergahı haritada inceleyebilirsiniz.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const BouncingScrollPhysics(),
      itemCount: visibleArrivals.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, idx) {
        return _buildVehicleCard(visibleArrivals[idx]);
      },
    );
  }

  /// Vehicle arrival card: Line pill, destination, Kapı / Door tag, amenities, and ETA badge
  Widget _buildVehicleCard(StopArrival item) {
    final lineAccent = AppTheme.lineColor(item.line);

    return ValueListenableBuilder<int>(
      valueListenable: provider.clock,
      builder: (_, _, _) {
        final now = DateTime.now();
        final totalSeconds = math.max(0, item.etaAt.difference(now).inSeconds);
        final minutes = math.max(1, (totalSeconds / 60).round());
        final isImminent = totalSeconds <= 180; // <= 3 minutes
        final progressFactor = (1.0 - (minutes / 25.0)).clamp(0.1, 1.0);

        return GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            if (item.line.isNotEmpty) {
              onSelectLine(item.line);
            }
          },
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF141923),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isImminent
                    ? const Color(0xFF10B981).withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.08),
                width: isImminent ? 1.4 : 1.0,
              ),
              boxShadow: [
                if (isImminent)
                  BoxShadow(
                    color: const Color(0xFF10B981).withValues(alpha: 0.08),
                    blurRadius: 12,
                    offset: const Offset(0, 2),
                  ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Left Line Badge
                Container(
                  width: 52,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: lineAccent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: lineAccent.withValues(alpha: 0.5),
                      width: 1.2,
                    ),
                  ),
                  child: Text(
                    item.line.isNotEmpty ? item.line : 'İETT',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: lineAccent,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Middle Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Destination
                      Text(
                        item.headsign.isNotEmpty ? item.headsign : '${item.line} Hattı',
                        style: const TextStyle(
                          color: AppTheme.textLight,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          height: 1.25,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),

                      // Meta tags: Door/Bus ID + Distance / Speed
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (item.busId.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Kapı ${item.busId}',
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  color: AppTheme.textMutedDark,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          if (item.distM > 0)
                            Text(
                              item.distM >= 1000
                                  ? '${(item.distM / 1000).toStringAsFixed(1)} km uzakta'
                                  : '${item.distM} m uzakta',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          if (item.speed > 0)
                            Text(
                              '• ${item.speed.round()} km/s',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.4),
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // Progress Bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: Container(
                          height: 3,
                          width: double.infinity,
                          color: Colors.white.withValues(alpha: 0.08),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: progressFactor,
                            child: Container(
                              decoration: BoxDecoration(
                                color: isImminent
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFF0284C7),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),

                      // Amenities / Features row
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const NeverScrollableScrollPhysics(),
                        child: Row(
                          children: [
                            if (item.haveWifi)
                              _buildFeatureIcon(Icons.wifi_rounded, 'WiFi'),
                            if (item.haveUsb)
                              _buildFeatureIcon(Icons.usb_rounded, 'USB'),
                            if (item.haveAccessibility)
                              _buildFeatureIcon(Icons.accessible_rounded, 'Erişilebilir'),
                            if (item.haveAir)
                              _buildFeatureIcon(Icons.ac_unit_rounded, 'Klima'),
                            if (item.haveBicycle)
                              _buildFeatureIcon(Icons.pedal_bike_rounded, 'Bisiklet'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),

                // Right ETA Countdown Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: isImminent
                        ? const Color(0xFF10B981).withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isImminent
                          ? const Color(0xFF10B981).withValues(alpha: 0.4)
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        isImminent && totalSeconds <= 60 ? '< 1' : '$minutes',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: isImminent ? const Color(0xFF10B981) : Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                          height: 1.0,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'dakika',
                        style: TextStyle(
                          color: isImminent
                              ? const Color(0xFF10B981).withValues(alpha: 0.9)
                              : AppTheme.textMutedDark,
                          fontWeight: FontWeight.w600,
                          fontSize: 9.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFeatureIcon(IconData icon, String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: Colors.white.withValues(alpha: 0.55)),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 9.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
