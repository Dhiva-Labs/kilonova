import 'package:flutter/material.dart';

import '../theme/theme.dart';

enum KnButtonVariant { primary, secondary, text }

/// The app's buttons. Primary is the gold action; secondary a quiet filled
/// one beside it; text a link-like action. All change to a solid color on
/// hover and press.
class KnButton extends StatelessWidget {
  const KnButton.primary(
    this.label, {
    super.key,
    required this.onPressed,
    this.icon,
    this.expand = false,
  }) : variant = KnButtonVariant.primary;

  const KnButton.secondary(
    this.label, {
    super.key,
    required this.onPressed,
    this.icon,
    this.expand = false,
  }) : variant = KnButtonVariant.secondary;

  const KnButton.text(
    this.label, {
    super.key,
    required this.onPressed,
    this.icon,
    this.expand = false,
  }) : variant = KnButtonVariant.text;

  final String label;

  /// Null disables the button.
  final VoidCallback? onPressed;

  /// Shown before the label, usually a [KnIcon] at 20px. It takes the
  /// button's foreground color unless it sets its own.
  final Widget? icon;

  /// Full width, for phone layouts.
  final bool expand;
  final KnButtonVariant variant;

  @override
  Widget build(BuildContext context) {
    final c = context.kn;
    final icon = this.icon;
    final child = icon == null
        ? Text(label)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              const SizedBox(width: 8),
              Flexible(child: Text(label)),
            ],
          );
    // Phone layouts are tighter; desktop buttons are 44px.
    final height = context.isPhoneWidth ? 40.0 : 44.0;

    final Widget button = switch (variant) {
      KnButtonVariant.primary => FilledButton(
        onPressed: onPressed,
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, height)),
        ),
        child: child,
      ),
      KnButtonVariant.secondary => FilledButton(
        onPressed: onPressed,
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, height)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? c.surfaceRaised
                : s.contains(WidgetState.hovered) ||
                      s.contains(WidgetState.focused) ||
                      s.contains(WidgetState.pressed)
                ? c.border
                : c.surfaceRaised,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.textSecondary : c.text,
          ),
          iconColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.textSecondary : c.text,
          ),
        ),
        child: child,
      ),
      KnButtonVariant.text => TextButton(onPressed: onPressed, child: child),
    };
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// A 36px square icon button with a 20px glyph. The tooltip is required:
/// an icon alone does not say what it does.
class KnIconButton extends StatelessWidget {
  const KnIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  /// A [KnIcon] or a Material [Icon].
  final Widget icon;
  final String tooltip;

  /// Null disables the button.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(icon: icon, tooltip: tooltip, onPressed: onPressed);
  }
}
