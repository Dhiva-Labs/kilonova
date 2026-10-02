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

final _xmrAmount = RegExp(r'^(\d*)(?:\.(\d{0,12}))?$');

/// Parses an XMR amount such as `1.5` or `.25` into atomic units. Returns
/// null for anything else, including more than 12 decimals.
BigInt? parseXmr(String text) {
  final match = _xmrAmount.firstMatch(text.trim());
  if (match == null) return null;
  final whole = match.group(1)!;
  final fraction = match.group(2) ?? '';
  if (whole.isEmpty && fraction.isEmpty) return null;
  return BigInt.parse(whole.isEmpty ? '0' : whole) * _piconero +
      BigInt.parse(fraction.padRight(12, '0'));
}
