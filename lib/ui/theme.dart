import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Monochrome, paper-like look: off-white ground, black ink, grey meta text,
/// hairline dividers. The only colour is the AI gradient on Ask-AI surfaces.
abstract final class Palette {
  static const ground = Color(0xFFF8F8F8);
  static const surface = Color(0xFFFFFFFF);
  static const fill = Color(0xFFEDEDED); // grey pills, play button
  static const text = Color(0xFF111111);
  static const muted = Color(0xFF8E8E8E);
  static const faint = Color(0xFFBDBDBD);
  static const line = Color(0xFFE6E6E6);
  static const danger = Color(0xFFD93025);

  static const aiGradient = LinearGradient(colors: [
    Color(0xFF8B5CF6),
    Color(0xFF3B82F6),
    Color(0xFF22D3EE),
    Color(0xFF34D399),
  ]);
}

/// Page padding used across screens.
const pagePadding = EdgeInsets.symmetric(horizontal: 24);

ThemeData buildTheme() {
  const scheme = ColorScheme.light(
    primary: Palette.text,
    onPrimary: Colors.white,
    secondary: Palette.text,
    onSecondary: Colors.white,
    surface: Palette.ground,
    onSurface: Palette.text,
    onSurfaceVariant: Palette.muted,
    surfaceContainerLowest: Palette.surface,
    surfaceContainerLow: Palette.surface,
    surfaceContainer: Palette.surface,
    surfaceContainerHigh: Palette.fill,
    surfaceContainerHighest: Palette.fill,
    primaryContainer: Palette.fill,
    onPrimaryContainer: Palette.text,
    outline: Palette.muted,
    outlineVariant: Palette.line,
    error: Palette.danger,
    errorContainer: Color(0xFFFDECEA),
    onErrorContainer: Color(0xFF8C1D18),
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.ground,
    splashFactory: InkSparkle.splashFactory,
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (_) =>
          const Icon(Icons.arrow_back_ios_new, size: 22),
    ),
  );
  final text = base.textTheme.apply(bodyColor: Palette.text, displayColor: Palette.text);
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));

  return base.copyWith(
    textTheme: text.copyWith(
      // The big, thin page titles ("All files"-style headers).
      displayMedium: text.displayMedium
          ?.copyWith(fontWeight: FontWeight.w300, letterSpacing: -1.5),
      displaySmall: text.displaySmall?.copyWith(fontWeight: FontWeight.w300),
      headlineMedium:
          text.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 17, height: 1.5),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Palette.ground,
      foregroundColor: Palette.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: Palette.surface,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      titleTextStyle: TextStyle(
          color: Palette.text, fontSize: 18, fontWeight: FontWeight.w600),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: Palette.text,
      unselectedLabelColor: Palette.muted,
      labelStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      unselectedLabelStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w400),
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: Palette.text, width: 2.5)),
      dividerColor: Colors.transparent,
      overlayColor: WidgetStatePropertyAll(Colors.transparent),
      tabAlignment: TabAlignment.center,
    ),
    dividerTheme: const DividerThemeData(color: Palette.line, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Palette.text,
        foregroundColor: Colors.white,
        shape: pill,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Palette.text,
        side: const BorderSide(color: Palette.faint),
        shape: pill,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Palette.text),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: Palette.text),
    ),
    cardTheme: CardThemeData(
      color: Palette.surface,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Palette.line),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: Palette.text,
      subtitleTextStyle: TextStyle(color: Palette.muted, fontSize: 14),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Palette.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Palette.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Palette.text, width: 1.5),
      ),
      labelStyle: const TextStyle(color: Palette.muted),
      floatingLabelStyle: const TextStyle(color: Palette.text),
      hintStyle: const TextStyle(color: Palette.faint),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Palette.text,
      linearTrackColor: Palette.line,
      circularTrackColor: Colors.transparent,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: Palette.text,
      inactiveTrackColor: Palette.line,
      thumbColor: Palette.text,
      overlayColor: Color(0x14000000),
      trackHeight: 2,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : Palette.muted),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Palette.text : Palette.fill),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    radioTheme: const RadioThemeData(fillColor: WidgetStatePropertyAll(Palette.text)),
    chipTheme: const ChipThemeData(
      backgroundColor: Palette.fill,
      side: BorderSide.none,
      labelStyle: TextStyle(color: Palette.text, fontSize: 13),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Palette.text,
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Palette.surface,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: Palette.faint,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Palette.surface,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: Palette.surface,
      surfaceTintColor: Colors.transparent,
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
      iconColor: Palette.text,
      collapsedIconColor: Palette.muted,
    ),
  );
}

/// Large, thin page header, e.g. "All files".
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final EdgeInsets padding;
  const PageHeader(this.title,
      {super.key,
      this.subtitle,
      this.padding = const EdgeInsets.fromLTRB(24, 16, 24, 20)});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.displayMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: t.bodyMedium?.copyWith(color: Palette.muted)),
          ],
        ],
      ),
    );
  }
}

/// Outlined box with the AI gradient as its border.
class GradientBorder extends StatelessWidget {
  final Widget child;
  final double radius;
  const GradientBorder({super.key, required this.child, this.radius = 14});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: Palette.aiGradient,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1.5),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Palette.surface,
            borderRadius: BorderRadius.circular(radius - 1.5),
          ),
          child: child,
        ),
      ),
    );
  }
}
