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

/// From this width up the app uses two panes and desktop-sized controls.
const knDesktopWidth = 720.0;

extension KnLayoutContext on BuildContext {
  bool get isPhoneWidth => MediaQuery.sizeOf(this).width < knDesktopWidth;
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
    surfaceContainerHighest: c.surfaceRaised,
    surfaceTint: c.surface,
  );

  final text = _textTheme(c);
  const cardRadius = BorderRadius.all(Radius.circular(KnRadius.md));

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    fontFamily: KnFonts.sans,
    textTheme: text,
    splashFactory: NoSplash.splashFactory,
    // Ink highlights are opaque tokens, so hovered rows and menu items get a
    // solid fill rather than a translucent overlay.
    hoverColor: c.surfaceRaised,
    highlightColor: c.surfaceRaised,
    focusColor: c.surfaceRaised,
    splashColor: Colors.transparent,
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
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      // Fields keep their fill on hover; the border carries focus.
      hoverColor: Colors.transparent,
      floatingLabelBehavior: FloatingLabelBehavior.never,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      labelStyle: text.bodyMedium!.copyWith(color: c.textSecondary),
      hintStyle: text.bodyMedium!.copyWith(color: c.textSecondary),
      helperStyle: text.bodySmall,
      errorStyle: text.bodySmall!.copyWith(color: c.error),
      suffixStyle: text.bodyMedium!.copyWith(color: c.textSecondary),
      border: _outline(c.border),
      enabledBorder: _outline(c.border),
      disabledBorder: _outline(c.border),
      focusedBorder: _outline(c.accent, width: 2),
      errorBorder: _outline(c.error),
      focusedErrorBorder: _outline(c.error, width: 2),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.border,
      selectionHandleColor: c.accent,
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.textSecondary,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.onAccent : c.textSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.surfaceRaised,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.border,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: c.surface,
      elevation: 0,
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.border),
        borderRadius: cardRadius,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: c.surface,
      modalBackgroundColor: c.surface,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: false,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.border),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(KnRadius.md),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: c.surface,
      elevation: 0,
      textStyle: text.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(text.bodyMedium),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.border),
        borderRadius: cardRadius,
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surface),
        surfaceTintColor: WidgetStatePropertyAll(c.surface),
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            side: BorderSide(color: c.border),
            borderRadius: cardRadius,
          ),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
        textStyle: WidgetStatePropertyAll(text.bodyMedium),
        foregroundColor: WidgetStatePropertyAll(c.text),
        backgroundColor: _states(c.surface, c.surfaceRaised),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.text,
      contentTextStyle: text.bodyMedium!.copyWith(color: c.bg),
      actionTextColor: c.bg,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(KnRadius.sm)),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbVisibility: const WidgetStatePropertyAll(false),
      trackVisibility: const WidgetStatePropertyAll(false),
      thickness: const WidgetStatePropertyAll(4),
      thumbColor: WidgetStatePropertyAll(c.textSecondary),
      radius: const Radius.circular(2),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.textSecondary,
      textColor: c.text,
      tileColor: c.bg,
      contentPadding: const EdgeInsets.symmetric(horizontal: KnSpace.md),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? c.surfaceRaised
              : _isActive(s)
              ? c.accentHover
              : c.accent,
        ),
        foregroundColor: _enabled(c.onAccent, c.textSecondary),
        iconColor: _enabled(c.onAccent, c.textSecondary),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        shape: _controlShape,
        // The spec'd geometry is the hit area; no invisible padding.
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 20),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: _enabled(c.accent, c.textSecondary),
        iconColor: _enabled(c.accent, c.textSecondary),
        backgroundColor: _states(Colors.transparent, c.surfaceRaised),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        shape: _controlShape,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
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
        shape: _controlShape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: _enabled(c.textSecondary, c.border),
        backgroundColor: _states(Colors.transparent, c.surfaceRaised),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        iconSize: const WidgetStatePropertyAll(20),
        minimumSize: const WidgetStatePropertyAll(Size.square(36)),
        maximumSize: const WidgetStatePropertyAll(Size.square(36)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: _controlShape,
      ),
    ),
  );
}

/// Buttons and inputs share one corner radius, rather than Material's pills.
const _controlShape = WidgetStatePropertyAll(
  RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(KnRadius.sm)),
  ),
);

OutlineInputBorder _outline(Color color, {double width = 1}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(KnRadius.sm),
      borderSide: BorderSide(color: color, width: width),
    );

bool _isActive(Set<WidgetState> s) =>
    s.contains(WidgetState.hovered) ||
    s.contains(WidgetState.focused) ||
    s.contains(WidgetState.pressed);

/// Rest color, switching to a solid [active] color on hover, focus or press.
WidgetStateProperty<Color> _states(Color rest, Color active) =>
    WidgetStateProperty.resolveWith((s) => _isActive(s) ? active : rest);

WidgetStateProperty<Color> _enabled(Color enabled, Color disabled) =>
    WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? disabled : enabled,
    );

/// The type scale from docs/design/REDESIGN.md. Widgets ask for a role and
/// get the same size, weight and color everywhere.
TextTheme _textTheme(KnColors c) {
  TextStyle style(
    double size,
    double line,
    FontWeight weight,
    Color color, {
    bool mono = false,
  }) => TextStyle(
    fontFamily: mono ? KnFonts.mono : KnFonts.sans,
    fontSize: size,
    height: line / size,
    fontWeight: weight,
    color: color,
    fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
  );
  const regular = FontWeight.w400;
  const medium = FontWeight.w500;

  return TextTheme(
    displayLarge: style(40, 48, medium, c.text, mono: true),
    headlineMedium: style(24, 32, medium, c.text),
    headlineSmall: style(24, 32, medium, c.text),
    titleLarge: style(18, 24, medium, c.text),
    titleMedium: style(15, 20, medium, c.text),
    titleSmall: style(14, 20, medium, c.text),
    bodyLarge: style(15, 22, regular, c.text),
    bodyMedium: style(14, 20, regular, c.text),
    bodySmall: style(13, 18, regular, c.textSecondary),
    // Buttons replace this color with their own foreground.
    labelLarge: style(14, 20, medium, c.text),
    labelMedium: style(12, 16, medium, c.textSecondary),
    labelSmall: style(11, 16, medium, c.textSecondary),
  );
}

/// Monospace style for amounts, addresses, txids and block heights. Figures
/// are tabular so columns of numbers line up.
TextStyle monoStyle(BuildContext context, {double size = 14, Color? color}) =>
    TextStyle(
      fontFamily: KnFonts.mono,
      fontSize: size,
      color: color ?? context.kn.text,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
