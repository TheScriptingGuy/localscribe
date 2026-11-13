import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Colours that do not change between light and dark mode.
abstract final class Palette {
  /// The only decorative colour: the AI gradient on Ask-AI surfaces.
  static const aiGradient = LinearGradient(colors: [
    Color(0xFF8B5CF6),
    Color(0xFF3B82F6),
    Color(0xFF22D3EE),
    Color(0xFF34D399),
  ]);
}

/// Monochrome, paper-like palette (light) and its inverse (dark). Read it with
/// `context.colors`; it follows the active [Theme].
@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color ground; // page background
  final Color surface; // cards, sheets, bottom bar
  final Color fill; // grey pills, play button
  final Color text; // primary ink
  final Color inverse; // content drawn on top of [text]-coloured surfaces
  final Color muted;
  final Color faint;
  final Color line;
  final Color danger;
  final Color dangerContainer;
  final Color onDangerContainer;

  const AppColors({
    required this.ground,
    required this.surface,
    required this.fill,
    required this.text,
    required this.inverse,
    required this.muted,
    required this.faint,
    required this.line,
    required this.danger,
    required this.dangerContainer,
    required this.onDangerContainer,
  });

  static const light = AppColors(
    ground: Color(0xFFF8F8F8),
    surface: Color(0xFFFFFFFF),
    fill: Color(0xFFEDEDED),
    text: Color(0xFF111111),
    inverse: Color(0xFFFFFFFF),
    muted: Color(0xFF8E8E8E),
    faint: Color(0xFFBDBDBD),
    line: Color(0xFFE6E6E6),
    danger: Color(0xFFD93025),
    dangerContainer: Color(0xFFFDECEA),
    onDangerContainer: Color(0xFF8C1D18),
  );

  static const dark = AppColors(
    ground: Color(0xFF0F0F0F),
    surface: Color(0xFF1B1B1B),
    fill: Color(0xFF2A2A2A),
    text: Color(0xFFF2F2F2),
    inverse: Color(0xFF111111),
    muted: Color(0xFF9A9A9A),
    faint: Color(0xFF5C5C5C),
    line: Color(0xFF2E2E2E),
    danger: Color(0xFFFF6B60),
    dangerContainer: Color(0xFF3A1B18),
    onDangerContainer: Color(0xFFFFB4AB),
  );

  @override
  AppColors copyWith({
    Color? ground,
    Color? surface,
    Color? fill,
    Color? text,
    Color? inverse,
    Color? muted,
    Color? faint,
    Color? line,
    Color? danger,
    Color? dangerContainer,
    Color? onDangerContainer,
  }) =>
      AppColors(
        ground: ground ?? this.ground,
        surface: surface ?? this.surface,
        fill: fill ?? this.fill,
        text: text ?? this.text,
        inverse: inverse ?? this.inverse,
        muted: muted ?? this.muted,
        faint: faint ?? this.faint,
        line: line ?? this.line,
        danger: danger ?? this.danger,
        dangerContainer: dangerContainer ?? this.dangerContainer,
        onDangerContainer: onDangerContainer ?? this.onDangerContainer,
      );

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      ground: l(ground, other.ground),
      surface: l(surface, other.surface),
      fill: l(fill, other.fill),
      text: l(text, other.text),
      inverse: l(inverse, other.inverse),
      muted: l(muted, other.muted),
      faint: l(faint, other.faint),
      line: l(line, other.line),
      danger: l(danger, other.danger),
      dangerContainer: l(dangerContainer, other.dangerContainer),
      onDangerContainer: l(onDangerContainer, other.onDangerContainer),
    );
  }
}

extension AppColorsContext on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}

/// Page padding used across screens.
const pagePadding = EdgeInsets.symmetric(horizontal: 24);

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final isDark = brightness == Brightness.dark;

  final scheme = (isDark ? const ColorScheme.dark() : const ColorScheme.light())
      .copyWith(
    primary: c.text,
    onPrimary: c.inverse,
    secondary: c.text,
    onSecondary: c.inverse,
    surface: c.ground,
    onSurface: c.text,
    onSurfaceVariant: c.muted,
    surfaceContainerLowest: c.surface,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.fill,
    surfaceContainerHighest: c.fill,
    primaryContainer: c.fill,
    onPrimaryContainer: c.text,
    outline: c.muted,
    outlineVariant: c.line,
    error: c.danger,
    errorContainer: c.dangerContainer,
    onErrorContainer: c.onDangerContainer,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.ground,
    splashFactory: InkSparkle.splashFactory,
    extensions: [c],
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (_) =>
          const Icon(Icons.arrow_back_ios_new, size: 22),
    ),
  );
  final text = base.textTheme.apply(bodyColor: c.text, displayColor: c.text);
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));
  final iconBrightness = isDark ? Brightness.light : Brightness.dark;

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
    appBarTheme: AppBarTheme(
      backgroundColor: c.ground,
      foregroundColor: c.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: iconBrightness,
        systemNavigationBarColor: c.surface,
        systemNavigationBarIconBrightness: iconBrightness,
      ),
      titleTextStyle:
          TextStyle(color: c.text, fontSize: 18, fontWeight: FontWeight.w600),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: c.text,
      unselectedLabelColor: c.muted,
      labelStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      unselectedLabelStyle:
          const TextStyle(fontSize: 18, fontWeight: FontWeight.w400),
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: c.text, width: 2.5)),
      dividerColor: Colors.transparent,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      tabAlignment: TabAlignment.center,
    ),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.text,
        foregroundColor: c.inverse,
        shape: pill,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        side: BorderSide(color: c.faint),
        shape: pill,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.text),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.text),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.line),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.text,
      subtitleTextStyle: TextStyle(color: c.muted, fontSize: 14),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.text, width: 1.5),
      ),
      labelStyle: TextStyle(color: c.muted),
      floatingLabelStyle: TextStyle(color: c.text),
      hintStyle: TextStyle(color: c.faint),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.text,
      linearTrackColor: c.line,
      circularTrackColor: Colors.transparent,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.text,
      inactiveTrackColor: c.line,
      thumbColor: c.text,
      overlayColor: c.text.withValues(alpha: 0.08),
      trackHeight: 2,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.inverse : c.muted),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.text : c.fill),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStatePropertyAll(c.text)),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? c.text : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? c.inverse : c.text),
        side: WidgetStatePropertyAll(BorderSide(color: c.faint)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.fill,
      selectedColor: c.text,
      checkmarkColor: c.inverse,
      side: BorderSide.none,
      labelStyle: WidgetStateTextStyle.resolveWith((s) => TextStyle(
          color: s.contains(WidgetState.selected) ? c.inverse : c.text,
          fontSize: 13)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.text,
      contentTextStyle: TextStyle(color: c.inverse),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: c.faint,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: c.text,
      collapsedIconColor: c.muted,
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
            Text(subtitle!,
                style: t.bodyMedium?.copyWith(color: context.colors.muted)),
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
            color: context.colors.surface,
            borderRadius: BorderRadius.circular(radius - 1.5),
          ),
          child: child,
        ),
      ),
    );
  }
}
