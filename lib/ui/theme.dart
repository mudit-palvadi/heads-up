/// Design tokens for Heads Up.
///
/// Every value here is a rule from the dyslexia design table in `prd.md` §7.
/// They live in code rather than only in prose so that a widget cannot quietly
/// violate them: contrast, line spacing, alignment and the word budget are all
/// expressed once, here.
library;

import 'package:flutter/material.dart';

abstract final class HeadsUpColors {
  /// PRD §7: high contrast — white on dark navy, >= 4.5:1.
  static const Color background = Color(0xFF1A1A2E);

  /// Slightly lifted surface for cards/sheets, still >= 4.5:1 on [background].
  static const Color surface = Color(0xFF24243D);

  static const Color textPrimary = Color(0xFFFFFFFF);

  /// Used for sub-text and footers. Still clears 4.5:1 on [background],
  /// deliberately NOT a low-contrast grey.
  static const Color textSecondary = Color(0xFFB8B8CC);

  /// PRD §3.3: urgent accent for deadlines landing today or earlier.
  static const Color urgent = Color(0xFFFF6B35);

  /// PRD §3.1: the amber play button.
  static const Color accent = Color(0xFFFFAB40);

  /// PRD §3.2: the empty state is a feature, not an afterthought — so it gets
  /// a calm, legible green rather than the usual grey.
  static const Color calm = Color(0xFFA8E6A3);
}

abstract final class HeadsUpText {
  /// PRD §7: system sans-serif only. Never serif, never italic — both are
  /// measurably harder for dyslexic readers.
  static const String fontFamily = 'Roboto';

  /// PRD §7: 1.3x minimum line spacing so lines do not visually merge.
  static const double lineHeight = 1.3;

  static const TextStyle header = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    height: lineHeight,
    fontStyle: FontStyle.normal,
    fontWeight: FontWeight.w600,
    color: HeadsUpColors.textSecondary,
  );

  /// Line 1 of a widget row. Caps at 2 lines, ~7 words (PRD §7).
  static const TextStyle itemWhat = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: lineHeight,
    fontStyle: FontStyle.normal,
    fontWeight: FontWeight.w600,
    color: HeadsUpColors.textPrimary,
  );

  /// Line 2 of a widget row — the action, plus the deadline in plain language.
  static const TextStyle itemDoIt = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    height: lineHeight,
    fontStyle: FontStyle.normal,
    fontWeight: FontWeight.w400,
    color: HeadsUpColors.textPrimary,
  );

  static const TextStyle footer = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    height: lineHeight,
    fontStyle: FontStyle.normal,
    color: HeadsUpColors.textSecondary,
  );

  /// PRD §3.2: the empty state is large, calm and centred.
  static const TextStyle emptyState = TextStyle(
    fontFamily: fontFamily,
    fontSize: 20,
    height: lineHeight,
    fontStyle: FontStyle.normal,
    fontWeight: FontWeight.w600,
    color: HeadsUpColors.calm,
  );
}

abstract final class HeadsUpSpacing {
  static const double gutter = 16;
  static const double rowGap = 10;

  /// PRD §3.1: the widget never shows more than three items. Three rows only.
  static const int maxWidgetItems = 3;
}

/// Maximum words allowed on one widget line (PRD §7: "max 2 lines per widget
/// item, ~7 words per line").
///
/// Gemma is prompted for short lines, but a 1B model will occasionally
/// overrun. This is the last line of defence so the widget can never render an
/// unreadable block of text.
String clampToWordBudget(String text, {int maxWords = 7}) {
  final words = text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.length <= maxWords) return text.trim();
  return '${words.take(maxWords).join(' ')}...';
}

ThemeData buildHeadsUpTheme() {
  const scheme = ColorScheme.dark(
    primary: HeadsUpColors.accent,
    onPrimary: HeadsUpColors.background,
    secondary: HeadsUpColors.calm,
    onSecondary: HeadsUpColors.background,
    surface: HeadsUpColors.surface,
    onSurface: HeadsUpColors.textPrimary,
    error: HeadsUpColors.urgent,
    onError: HeadsUpColors.background,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: HeadsUpColors.background,
    // PRD §7: left-aligned everywhere, never justified.
    textTheme: const TextTheme(
      bodyLarge: HeadsUpText.itemWhat,
      bodyMedium: HeadsUpText.itemDoIt,
      labelSmall: HeadsUpText.footer,
    ).apply(
      bodyColor: HeadsUpColors.textPrimary,
      displayColor: HeadsUpColors.textPrimary,
      fontFamily: HeadsUpText.fontFamily,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: HeadsUpColors.background,
      foregroundColor: HeadsUpColors.textPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: HeadsUpText.fontFamily,
        fontSize: 20,
        height: HeadsUpText.lineHeight,
        fontWeight: FontWeight.w700,
        color: HeadsUpColors.textPrimary,
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: HeadsUpColors.surface,
      border: OutlineInputBorder(borderSide: BorderSide.none),
    ),
    listTileTheme: const ListTileThemeData(
      textColor: HeadsUpColors.textPrimary,
      iconColor: HeadsUpColors.textSecondary,
    ),
  );
}