import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../models/transit_models.dart';
import '../theme/app_theme.dart';

class LineSearchModal extends StatefulWidget {
  final List<String> popularLines;
  final List<LineInfo>? allLines;
  final Function(String) onSelectLine;

  const LineSearchModal({
    super.key,
    required this.popularLines,
    this.allLines,
    required this.onSelectLine,
  });

  @override
  State<LineSearchModal> createState() => _LineSearchModalState();
}

class _LineSearchModalState extends State<LineSearchModal> {
  final TextEditingController _controller = TextEditingController();
  String _filter = '';
  List<LineInfo> _lines = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.allLines != null && widget.allLines!.isNotEmpty) {
      _lines = List.from(widget.allLines!);
    } else {
      _loadLinesFromAssets();
    }
  }

  Future<void> _loadLinesFromAssets() async {
    setState(() => _isLoading = true);
    try {
      final jsonStr = await rootBundle.loadString('assets/data/bus_lines.json');
      final dynamic list = jsonDecode(jsonStr);
      if (list is List) {
        if (mounted) {
          setState(() {
            _lines = list
                .whereType<Map<String, dynamic>>()
                .map((m) => LineInfo.fromJson(m))
                .toList();
            _isLoading = false;
          });
          return;
        }
      }
    } catch (_) {}

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  static String _normalize(String input) {
    return input
        .trim()
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ş', 's')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll('İ', 'i')
        .replaceAll('I', 'i');
  }

  List<LineInfo> _filterAndSortLines() {
    if (_lines.isEmpty) return [];

    final q = _normalize(_filter);
    if (q.isEmpty) {
      // Prioritize popular lines first, then alphabetical
      final popSet = widget.popularLines.map((e) => e.toUpperCase()).toSet();
      final popularList = <LineInfo>[];
      final others = <LineInfo>[];

      for (final l in _lines) {
        if (popSet.contains(l.code.toUpperCase())) {
          popularList.add(l);
        } else {
          others.add(l);
        }
      }

      // Sort popular list in the order of widget.popularLines
      popularList.sort((a, b) {
        final idxA = widget.popularLines.indexOf(a.code);
        final idxB = widget.popularLines.indexOf(b.code);
        return idxA.compareTo(idxB);
      });

      return [...popularList, ...others];
    }

    // Filter with scoring
    final scored = <({LineInfo item, int score})>[];

    for (final item in _lines) {
      final codeNorm = _normalize(item.code);
      final descNorm = _normalize(item.desc);

      int score = 9999;

      if (codeNorm == q) {
        // Exact code match (e.g. "14BK" matches "14BK")
        score = 0;
      } else if (codeNorm.startsWith(q)) {
        // Code prefix (e.g. "14" matches "14B", "14BK")
        score = 10 + (codeNorm.length - q.length);
      } else if (codeNorm.contains(q)) {
        score = 50 + (codeNorm.length - q.length);
      } else if (descNorm.startsWith(q)) {
        score = 100;
      } else {
        final words = descNorm.split(RegExp(r'[\s\-/]+'));
        if (words.any((w) => w.startsWith(q))) {
          score = 150;
        } else if (descNorm.contains(q)) {
          score = 200;
        }
      }

      if (score < 9999) {
        scored.add((item: item, score: score));
      }
    }

    scored.sort((a, b) {
      final cmp = a.score.compareTo(b.score);
      if (cmp != 0) return cmp;
      return a.item.code.compareTo(b.item.code);
    });

    return scored.map((s) => s.item).toList();
  }

  void _submitSelection(String code) {
    final clean = code.trim().toUpperCase();
    if (clean.isNotEmpty) {
      widget.onSelectLine(clean);
      Navigator.pop(context);
    }
  }

  Widget _buildTypeBadge(String type) {
    Color bg;
    Color fg;
    String label;

    switch (type.toLowerCase()) {
      case 'metrobus':
        bg = const Color(0xFFFEE2E2);
        fg = const Color(0xFFE11D48);
        label = 'METROBÜS';
        break;
      case 'express':
        bg = const Color(0xFFEFF6FF);
        fg = const Color(0xFF2563EB);
        label = 'EKSPRES';
        break;
      case 'metro':
        bg = const Color(0xFFE0F2FE);
        fg = const Color(0xFF0284C7);
        label = 'METRO';
        break;
      case 'tram':
        bg = const Color(0xFFFFEDD5);
        fg = const Color(0xFFEA580C);
        label = 'TRAMVAY';
      case 'marmaray':
        bg = const Color(0xFFFFE4E6);
        fg = const Color(0xFFB4192D);
        label = 'MARMARAY';
        break;
      default:
        bg = AppTheme.borderLight;
        fg = AppTheme.textSecondary;
        label = 'İETT';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filterAndSortLines();
    final hasExactMatch = filtered.any((item) => _normalize(item.code) == _normalize(_filter));

    return Material(
      color: AppTheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.88,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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

          // Header with count
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Text(
                    'Otobüs ve Hat Ara',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.borderMedium),
                    ),
                    child: Text(
                      _filter.isEmpty ? '${_lines.length} Hat' : '${filtered.length} Hat',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 24),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Search Input Bar
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
                hintText: 'Örn: 14BK, 500T, 15B, 34G...',
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
                  if (filtered.isNotEmpty) {
                    _submitSelection(filtered.first.code);
                  } else {
                    _submitSelection(val.trim());
                  }
                }
              },
            ),
          ),
          const SizedBox(height: 12),

          // Quick Popular Line Chips when search input is empty
          if (_filter.isEmpty && widget.popularLines.isNotEmpty) ...[
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: widget.popularLines.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, idx) {
                  final popLine = widget.popularLines[idx];
                  return GestureDetector(
                    onTap: () => _submitSelection(popLine),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: AppTheme.background,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: AppTheme.borderMedium),
                      ),
                      child: Text(
                        popLine,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Dynamic Manual Search Pill if user typed something not matched exactly
          if (_filter.isNotEmpty && !hasExactMatch)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GestureDetector(
                onTap: () => _submitSelection(_filter),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.accentBlack,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Hat ${_filter.toUpperCase()} Canlı Takibe Başla',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Loading Indicator or List
          if (_isLoading)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(color: AppTheme.accentBlack),
              ),
            )
          else if (filtered.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search_off_rounded, size: 48, color: AppTheme.textMuted),
                    const SizedBox(height: 8),
                    Text(
                      '"$_filter" ile eşleşen hat bulunamadı',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                physics: const BouncingScrollPhysics(),
                itemCount: filtered.length,
                separatorBuilder: (_, _) => const Divider(color: AppTheme.borderLight, height: 1),
                itemBuilder: (context, index) {
                  final item = filtered[index];
                  final isPopular = widget.popularLines.contains(item.code);

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                    leading: Container(
                      width: 68,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: isPopular ? AppTheme.surfaceDark : AppTheme.background,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isPopular ? AppTheme.accentBlack : AppTheme.borderMedium,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          item.code,
                          style: TextStyle(
                            color: isPopular ? Colors.white : AppTheme.accentBlack,
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.desc,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14.5,
                              color: AppTheme.textPrimary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _buildTypeBadge(item.type),
                      ],
                    ),
                    trailing: const Icon(
                      Icons.chevron_right_rounded,
                      color: AppTheme.textSecondary,
                      size: 20,
                    ),
                    onTap: () => _submitSelection(item.code),
                  );
                },
              ),
            ),
        ],
      ),
    ),
  ),
);
  }
}
