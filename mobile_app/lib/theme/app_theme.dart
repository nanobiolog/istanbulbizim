import 'package:flutter/material.dart';

class AppTheme {
  // Ultra-clean high contrast navigation colors (Inspired by Apple Maps & modern turn-by-turn navigation)
  static const Color background = Color(0xFFF8F9FA);
  static const Color surface = Colors.white;
  static const Color surfaceDark = Color(0xFF1E2022);
  static const Color textPrimary = Color(0xFF111827);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textMuted = Color(0xFF9CA3AF);

  // Modern Accent Colors
  static const Color accentBlack = Color(0xFF121316);
  static const Color accentBlue = Color(0xFF2563EB);
  static const Color accentTeal = Color(0xFF0D9488);
  static const Color directionCyan = Color(0xFF06B6D4);
  static const Color directionPurple = Color(0xFFA855F7);
  static const Color speedGreen = Color(0xFF10B981);
  static const Color speedYellow = Color(0xFFF59E0B);
  static const Color speedRed = Color(0xFFEF4444);

  // Border & Dividers
  static const Color borderLight = Color(0xFFE5E7EB);
  static const Color borderMedium = Color(0xFFD1D5DB);

  // Card & Button Shadows (crisp, modern)
  static final List<BoxShadow> pillShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.08),
      blurRadius: 18,
      spreadRadius: 2,
      offset: const Offset(0, 6),
    ),
    BoxShadow(
      color: Colors.black.withOpacity(0.04),
      blurRadius: 4,
      offset: const Offset(0, 2),
    ),
  ];

  static final List<BoxShadow> sheetShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.12),
      blurRadius: 28,
      spreadRadius: 0,
      offset: const Offset(0, -6),
    ),
  ];

  static final List<BoxShadow> hudShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.20),
      blurRadius: 16,
      spreadRadius: 0,
      offset: const Offset(0, 8),
    ),
  ];

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accentBlack,
        primary: accentBlack,
        surface: surface,
      ),
      fontFamily: '-apple-system',
    );
  }
}
