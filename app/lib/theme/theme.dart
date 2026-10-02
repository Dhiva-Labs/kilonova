import 'package:flutter/material.dart';

import 'tokens.dart';

/// Carries [KnColors] through the widget tree so widgets can reach tokens
/// that Material's [ColorScheme] has no slot for.
class KnTheme extends ThemeExtension<KnTheme> {
  const KnTheme(this.colors);

  final KnColors colors;

  @override
  KnTheme copyWith({KnColors? colors}) => KnTheme(colors ?? this.colors);

  // Token sets switch with the brightness; there is nothing to interpolate.
  @override
  KnTheme lerp(KnTheme? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

extension KnThemeContext on BuildContext {
  KnColors get kn => Theme.of(this).extension<KnTheme>()!.colors;
}

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.light ? KnColors.light : KnColors.dark;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    secondary: c.accent,
    onSecondary: c.onAccent,
    error: c.error,
    onError: c.bg,
    surface: c.surface,
    onSurface: c.text,
    onSurfaceVariant: c.textSecondary,
    outline: c.border,
    outlineVariant: c.border,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.bg,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surface,
    surfaceContainerHighest: c.surface,
    surfaceTint: c.surface,
  );

  final text = _textTheme(c);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    fontFamily: KnFonts.sans,
    textTheme: text,
    splashFactory: NoSplash.splashFactory,
    extensions: [KnTheme(c)],
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.text,
      surfaceTintColor: c.bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      iconColor: c.textSecondary,
      textColor: c.text,
      tileColor: c.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: KnSpace.md),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: _states(c.accent, c.accentHover),
        foregroundColor: WidgetStatePropertyAll(c.onAccent),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: _states(c.accent, c.accentHover),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accent : c.surface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.onAccent : c.text,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: c.border)),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(c.text),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => _isActive(s) ? c.border : Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
  );
}

bool _isActive(Set<WidgetState> s) =>
    s.contains(WidgetState.hovered) ||
    s.contains(WidgetState.focused) ||
    s.contains(WidgetState.pressed);

/// Rest color, switching to a solid [active] color on hover, focus or press.
WidgetStateProperty<Color> _states(Color rest, Color active) =>
    WidgetStateProperty.resolveWith((s) => _isActive(s) ? active : rest);

TextTheme _textTheme(KnColors c) {
  TextStyle style(double size, FontWeight weight, Color color) => TextStyle(
    fontFamily: KnFonts.sans,
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: 1.4,
  );
  const regular = FontWeight.w400;
  const medium = FontWeight.w500;

  return TextTheme(
    headlineMedium: style(26, medium, c.text),
    headlineSmall: style(22, medium, c.text),
    titleLarge: style(20, medium, c.text),
    titleMedium: style(16, medium, c.text),
    titleSmall: style(14, medium, c.text),
    bodyLarge: style(16, regular, c.text),
    bodyMedium: style(14, regular, c.text),
    bodySmall: style(12, regular, c.textSecondary),
    labelLarge: style(14, medium, c.text),
    labelMedium: style(12, medium, c.textSecondary),
    labelSmall: style(11, medium, c.textSecondary),
  );
}

/// Monospace style for amounts, addresses, txids and block heights.
TextStyle monoStyle(BuildContext context, {double size = 14, Color? color}) =>
    TextStyle(
      fontFamily: KnFonts.mono,
      fontSize: size,
      color: color ?? context.kn.text,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
