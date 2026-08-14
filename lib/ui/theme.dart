import 'package:flutter/material.dart';

abstract final class CastColors {
  static const background = Color(0xff07111f);
  static const panel = Color(0xff0d1b2d);
  static const panelLight = Color(0xff13253c);
  static const cyan = Color(0xff20d9e7);
  static const blue = Color(0xff4388ff);
  static const green = Color(0xff44d49c);
  static const red = Color(0xffff647c);
  static const text = Color(0xffeef6ff);
  static const muted = Color(0xff8ba2bc);
  static const border = Color(0xff203750);
}

ThemeData buildCastFlowTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: CastColors.cyan,
    brightness: Brightness.dark,
    surface: CastColors.panel,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: CastColors.background,
    colorScheme: scheme.copyWith(
      primary: CastColors.cyan,
      secondary: CastColors.blue,
      surface: CastColors.panel,
      error: CastColors.red,
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        fontWeight: FontWeight.w800,
        color: CastColors.text,
      ),
      titleLarge: TextStyle(
        fontWeight: FontWeight.w800,
        color: CastColors.text,
      ),
      titleMedium: TextStyle(
        fontWeight: FontWeight.w700,
        color: CastColors.text,
      ),
      bodyMedium: TextStyle(color: CastColors.text),
      bodySmall: TextStyle(color: CastColors.muted),
    ),
    cardTheme: CardThemeData(
      color: CastColors.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: CastColors.border),
        borderRadius: BorderRadius.circular(18),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: CastColors.background,
      border: OutlineInputBorder(
        borderSide: const BorderSide(color: CastColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: CastColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: CastColors.panelLight,
      contentTextStyle: TextStyle(color: CastColors.text),
    ),
  );
}
