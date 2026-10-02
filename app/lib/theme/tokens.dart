import 'package:flutter/painting.dart';

/// The Kilonova color tokens. This is the only file under `lib/` allowed to
/// contain color literals; see docs/DESIGN.md.
///
/// Contrast between these pairs is enforced by
/// `test/theme/contrast_test.dart`.
class KnColors {
  const KnColors({
    required this.bg,
    required this.surface,
    required this.border,
    required this.text,
    required this.textSecondary,
    required this.accent,
    required this.onAccent,
    required this.accentHover,
    required this.received,
    required this.error,
    required this.testnetStrip,
    required this.onTestnetStrip,
  });

  /// Page background.
  final Color bg;

  /// Cards, sheets and dialogs.
  final Color surface;

  /// 1px dividers. Never used as a card outline color.
  final Color border;

  /// Body text and amounts.
  final Color text;

  /// Labels, metadata and the pending state.
  final Color textSecondary;

  /// Kilonova gold: the single interactive color.
  final Color accent;

  /// Text and icons placed on [accent].
  final Color onAccent;

  /// Solid background for hovered, focused or pressed accent controls.
  /// Interactive states change color, never opacity.
  final Color accentHover;

  /// Incoming transactions. Always paired with an icon and a label.
  final Color received;

  /// Errors. Always paired with an icon and a message.
  final Color error;

  /// Solid strip shown on stagenet and testnet screens.
  final Color testnetStrip;

  /// Text placed on [testnetStrip].
  final Color onTestnetStrip;

  static const light = KnColors(
    bg: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    border: Color(0xFFDDE1E8),
    text: Color(0xFF121722),
    textSecondary: Color(0xFF5A6275),
    accent: Color(0xFF7A5B00),
    onAccent: Color(0xFFFFFFFF),
    accentHover: Color(0xFF5E4600),
    received: Color(0xFF1E7346),
    error: Color(0xFFB3261E),
    testnetStrip: Color(0xFF006F80),
    onTestnetStrip: Color(0xFFFFFFFF),
  );

  static const dark = KnColors(
    bg: Color(0xFF0B0F17),
    surface: Color(0xFF131926),
    border: Color(0xFF1F2633),
    text: Color(0xFFE8ECF4),
    textSecondary: Color(0xFF9AA3B5),
    accent: Color(0xFFE8B931),
    onAccent: Color(0xFF0B0F17),
    accentHover: Color(0xFFF2CC5C),
    received: Color(0xFF5FD39A),
    error: Color(0xFFFF8A80),
    testnetStrip: Color(0xFF4FD3E6),
    onTestnetStrip: Color(0xFF0B0F17),
  );
}

/// Font families bundled under `assets/fonts/`.
abstract final class KnFonts {
  static const sans = 'IBM Plex Sans';
  static const mono = 'IBM Plex Mono';
}

/// Spacing scale, in logical pixels.
abstract final class KnSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 40.0;
}
