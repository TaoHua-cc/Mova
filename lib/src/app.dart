import 'package:flutter/material.dart';

import 'app_route_observer.dart';
import 'brand.dart';
import 'media_center.dart';

class YingjiApp extends StatelessWidget {
  const YingjiApp({super.key});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: yingjiAppearance,
    builder: (context, _) => _buildApp(),
  );

  Widget _buildApp() {
    final isLight =
        yingjiAppearance.themeMode == ThemeMode.light ||
        (yingjiAppearance.themeMode == ThemeMode.system &&
            WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.light);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '映迹',
      theme: ThemeData(
        brightness: isLight ? Brightness.light : Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: isLight
            ? const Color(0xFFF3F4F7)
            : YingjiColors.canvas,
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: YingjiColors.focus,
              brightness: isLight ? Brightness.light : Brightness.dark,
            ).copyWith(
              primary: isLight ? const Color(0xFF315D98) : YingjiColors.focus,
              onPrimary: isLight ? Colors.white : YingjiColors.canvas,
              surface: isLight
                  ? const Color(0xFFF9FAFC)
                  : YingjiColors.elevated,
              onSurface: isLight ? const Color(0xFF17191E) : YingjiColors.ink,
            ),
        fontFamily: YingjiFonts.family,
        fontFamilyFallback: [...YingjiFonts.fallback, 'Segoe UI'],
        visualDensity: VisualDensity.compact,
        textTheme:
            const TextTheme(
              displayLarge: TextStyle(
                color: YingjiColors.ink,
                fontSize: 72,
                height: .96,
                letterSpacing: -2.5,
                fontWeight: FontWeight.w900,
              ),
              headlineLarge: TextStyle(
                color: YingjiColors.ink,
                fontSize: 42,
                height: 1.05,
                letterSpacing: -1.2,
                fontWeight: FontWeight.w800,
              ),
              headlineSmall: TextStyle(
                color: YingjiColors.ink,
                fontSize: 26,
                height: 1.1,
                letterSpacing: -.35,
                fontWeight: FontWeight.w800,
              ),
              bodyLarge: TextStyle(
                color: YingjiColors.ink,
                fontSize: 15,
                height: 1.55,
                letterSpacing: .08,
                fontWeight: FontWeight.w500,
              ),
              bodyMedium: TextStyle(
                color: YingjiColors.ink,
                height: 1.45,
                letterSpacing: .06,
                fontWeight: FontWeight.w500,
              ),
              bodySmall: TextStyle(
                color: YingjiColors.muted,
                height: 1.4,
                letterSpacing: .08,
                fontWeight: FontWeight.w500,
              ),
              titleLarge: TextStyle(
                color: YingjiColors.ink,
                fontWeight: FontWeight.w800,
              ),
            ).apply(
              bodyColor: isLight ? const Color(0xFF17191E) : YingjiColors.ink,
              displayColor: isLight
                  ? const Color(0xFF17191E)
                  : YingjiColors.ink,
            ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: Colors.white,
          inactiveTrackColor: Colors.white24,
          thumbColor: Colors.white,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            foregroundColor: YingjiColors.canvas,
            backgroundColor: YingjiColors.ink,
            disabledBackgroundColor: const Color(0x33FFFFFF),
            disabledForegroundColor: const Color(0x77FFFFFF),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
            shape: const StadiumBorder(),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: YingjiColors.ink,
            backgroundColor: YingjiGlass.chrome(),
            side: BorderSide(color: YingjiGlass.line()),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
            shape: const StadiumBorder(),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: YingjiColors.ink,
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
            shape: const StadiumBorder(),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
            foregroundColor: const WidgetStatePropertyAll(YingjiColors.ink),
            animationDuration: const Duration(milliseconds: 160),
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return Colors.white.withValues(alpha: .18);
              }
              if (states.contains(WidgetState.hovered)) {
                return Colors.white.withValues(alpha: .1);
              }
              return Colors.transparent;
            }),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: YingjiColors.line,
          thickness: 1,
          space: 1,
        ),
        chipTheme: ChipThemeData(
          backgroundColor: YingjiGlass.chrome(),
          selectedColor: YingjiColors.ink,
          disabledColor: YingjiGlass.chrome(strength: .42),
          side: BorderSide(color: YingjiGlass.line()),
          shape: const StadiumBorder(),
          labelStyle: const TextStyle(
            color: YingjiColors.ink,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
          secondaryLabelStyle: const TextStyle(
            color: YingjiColors.canvas,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? YingjiColors.canvas
                : YingjiColors.ink,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? YingjiColors.ink
                : const Color(0x33FFFFFF),
          ),
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
        scrollbarTheme: const ScrollbarThemeData(
          thickness: WidgetStatePropertyAll(4),
          radius: Radius.circular(99),
          thumbColor: WidgetStatePropertyAll(Color(0x55FFFFFF)),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xF0292B31),
          contentTextStyle: TextStyle(color: YingjiColors.ink),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: YingjiGlass.surface(strength: 1.12),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20)),
            side: BorderSide(color: YingjiGlass.line()),
          ),
          titleTextStyle: TextStyle(
            color: YingjiColors.ink,
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
          contentTextStyle: TextStyle(color: YingjiColors.muted, height: 1.45),
        ),
        inputDecorationTheme: InputDecorationTheme(
          labelStyle: const TextStyle(color: YingjiColors.muted),
          hintStyle: const TextStyle(color: YingjiColors.quiet),
          filled: true,
          fillColor: YingjiGlass.chrome(),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: YingjiGlass.line()),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: YingjiColors.focus),
          ),
          errorBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: YingjiColors.danger),
          ),
        ),
      ),
      home: const MediaCenterShell(),
      navigatorObservers: [yingjiRouteObserver],
    );
  }
}
