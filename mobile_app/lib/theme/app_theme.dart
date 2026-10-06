import 'package:flutter/material.dart';

class AppTheme {
  // Pure Black & White High Contrast Minimalist UI (zero colorful distractions)
  static const Color background = Color(0xFFF9FAFB);
  static const Color surface = Colors.white;
  static const Color surfaceDark = Color(0xFF09090B); // Pure carbon black
  static const Color textPrimary = Color(0xFF09090B);
  static const Color textSecondary = Color(0xFF52525B);
  static const Color textMuted = Color(0xFF71717A);

  // High contrast monochrome accents
  static const Color accentBlack = Color(0xFF09090B);
  static const Color accentGray = Color(0xFF27272A);
  static const Color lightGray = Color(0xFFF4F4F5);

  // Subtle clean status dots
  static const Color statusLive = Color(0xFF10B981);
  static const Color statusGreen = Color(0xFF10B981);
  static const Color directionCyan = Color(0xFF06B6D4); // Vibrant Cyan for D direction
  static const Color directionPurple = Color(0xFFA855F7); // Vibrant Purple for G direction
  static const Color metroDefault = Color(0xFF0284C7); // Metro default Blue

  // Dark Surface & Card colors matching website
  static const Color cardDark = Color(0xFF0B132B);
  static const Color cardBorderDark = Color(0xFF1E293B);
  static const Color bannerCruiseDark = Color(0xFF0C2444);
  static const Color textLight = Color(0xFFF8FAFC);
  static const Color textMutedDark = Color(0xFF94A3B8);

  // Border & Dividers
  static const Color borderLight = Color(0xFFE4E4E7);
  static const Color borderMedium = Color(0xFFD4D4D8);

  // Modern crisp shadows
  static final List<BoxShadow> pillShadow = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.06),
      blurRadius: 16,
      spreadRadius: 1,
      offset: const Offset(0, 4),
    ),
  ];

  static final List<BoxShadow> sheetShadow = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.10),
      blurRadius: 24,
      spreadRadius: 0,
      offset: const Offset(0, -6),
    ),
  ];

  static final List<BoxShadow> hudShadow = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.25),
      blurRadius: 20,
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
