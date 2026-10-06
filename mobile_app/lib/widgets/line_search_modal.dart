import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class LineSearchModal extends StatefulWidget {
  final List<String> popularLines;
  final Function(String) onSelectLine;

  const LineSearchModal({
    super.key,
    required this.popularLines,
    required this.onSelectLine,
  });

  @override
  State<LineSearchModal> createState() => _LineSearchModalState();
}

class _LineSearchModalState extends State<LineSearchModal> {
  final TextEditingController _controller = TextEditingController();
  String _filter = '';

  final List<Map<String, String>> _allFeaturedLines = [
    {'code': '500T', 'desc': 'Tuzla Şifa - Cevizlibağ'},
    {'code': '15B', 'desc': 'Güzeltepe - Üsküdar'},
    {'code': '34G', 'desc': 'Beylikdüzü - Söğütlüçeşme (Metrobüs)'},
    {'code': '34AS', 'desc': 'Avcılar - Söğütlüçeşme (Metrobüs)'},
    {'code': '34BZ', 'desc': 'Beylikdüzü - Zincirlikuyu (Metrobüs)'},
    {'code': '15F', 'desc': 'Beykoz - Kadıköy'},
    {'code': '11US', 'desc': 'Sultanbeyli - Üsküdar'},
    {'code': '16D', 'desc': 'Altkaynarca - Kadıköy'},
    {'code': '19F', 'desc': 'Fındıklı Mah. - Kadıköy'},
    {'code': '14R', 'desc': 'Rasathane - Kadıköy'},
    {'code': '129T', 'desc': 'Bostancı - Taksim'},
    {'code': '522', 'desc': 'Alemdağ - Çıksalın'},
    {'code': 'E-10', 'desc': 'Sabiha Gökçen HL - Kadıköy'},
    {'code': 'E-11', 'desc': 'Sabiha Gökçen HL - Kadıköy Ekspres'},
    {'code': '25G', 'desc': 'Sarıyer - Hacıosman - Mecidiyeköy'},
    {'code': '40T', 'desc': 'İstinye Dereiçi - Taksim'},
    {'code': '76D', 'desc': 'Bahçeşehir - Taksim'},
    {'code': '89C', 'desc': 'Başakşehir 4.-1.Etap - Taksim'},
    {'code': '97T', 'desc': 'Basın Sitesi - Taksim'},
    {'code': '145T', 'desc': 'Beylikdüzü - Taksim'},
  ];

  @override
  Widget build(BuildContext context) {
    final filtered = _allFeaturedLines.where((item) {
      if (_filter.isEmpty) return true;
      final q = _filter.toUpperCase();
      return item['code']!.toUpperCase().contains(q) || item['desc']!.toUpperCase().contains(q);
    }).toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag indicator
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.borderMedium,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Otobüs veya Hat Ara',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: AppTheme.textPrimary,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 24),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Big Minimal Search Input
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.borderLight, width: 1.5),
            ),
            child: TextField(
              controller: _controller,
              autofocus: true,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'Örn: 500T, 15B, 34G...',
                hintStyle: TextStyle(
                  color: AppTheme.textMuted,
                  fontWeight: FontWeight.w500,
                  fontSize: 16,
                ),
                border: InputBorder.none,
                icon: const Icon(Icons.search_rounded, color: AppTheme.accentBlack, size: 24),
                suffixIcon: _filter.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 20),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _filter = '');
                        },
                      )
                    : null,
              ),
              onChanged: (val) {
                setState(() => _filter = val.trim());
              },
              onSubmitted: (val) {
                if (val.trim().isNotEmpty) {
                  widget.onSelectLine(val.trim().toUpperCase());
                  Navigator.pop(context);
                }
              },
            ),
          ),
          const SizedBox(height: 16),

          // Custom Input Submit Pill if typed
          if (_filter.isNotEmpty && !filtered.any((item) => item['code'] == _filter.toUpperCase()))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GestureDetector(
                onTap: () {
                  widget.onSelectLine(_filter.toUpperCase());
                  Navigator.pop(context);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: AppTheme.accentBlack,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      Text(
                        'Hat ${_filter.toUpperCase()} Canlı Takibe Başla',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Line List
          Expanded(
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, _) => const Divider(color: AppTheme.borderLight, height: 1),
              itemBuilder: (context, index) {
                final item = filtered[index];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                  leading: Container(
                    width: 60,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.borderMedium),
                    ),
                    child: Center(
                      child: Text(
                        item['code']!,
                        style: const TextStyle(
                          color: AppTheme.accentBlack,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                  title: Text(
                    item['desc']!,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.textSecondary,
                  ),
                  onTap: () {
                    widget.onSelectLine(item['code']!);
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
