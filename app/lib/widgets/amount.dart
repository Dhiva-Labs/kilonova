import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Atomic units per XMR.
final BigInt _piconero = BigInt.from(10).pow(12);

/// Formats atomic units as XMR. Trailing zeros are dropped unless [full],
/// which always shows all 12 decimals.
String formatXmr(BigInt atomic, {bool full = false}) {
  final whole = atomic ~/ _piconero;
  var fraction = (atomic % _piconero).toString().padLeft(12, '0');
  if (!full) {
    fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
    if (fraction.isEmpty) fraction = '0';
  }
  return '$whole.$fraction';
}

/// An XMR amount in the mono face. Tapping toggles full 12-decimal
/// precision.
class AmountText extends StatefulWidget {
  const AmountText(
    this.atomic, {
    super.key,
    this.size = 14,
    this.color,
    this.prefix = '',
  });

  final BigInt atomic;
  final double size;
  final Color? color;
  final String prefix;

  @override
  State<AmountText> createState() => _AmountTextState();
}

class _AmountTextState extends State<AmountText> {
  bool _full = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _full = !_full),
      child: Text(
        '${widget.prefix}${formatXmr(widget.atomic, full: _full)} XMR',
        style: monoStyle(context, size: widget.size, color: widget.color),
      ),
    );
  }
}
