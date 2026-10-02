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

/// Like [formatXmr], with the whole part grouped in thousands:
/// `2,607.498016962174`. For display only; [parseXmr] does not read it.
String formatXmrGrouped(BigInt atomic, {bool full = false}) {
  final p = _XmrParts.of(atomic, full: full);
  return '${p.whole}.${p.head}${p.tail}';
}

/// An amount split for display: grouped whole part, the first four
/// decimals, and the remaining significant decimals.
class _XmrParts {
  const _XmrParts(this.whole, this.head, this.tail);

  factory _XmrParts.of(BigInt atomic, {required bool full}) {
    final plain = formatXmr(atomic, full: full);
    final dot = plain.indexOf('.');
    final fraction = plain.substring(dot + 1);
    final split = fraction.length < 4 ? fraction.length : 4;
    return _XmrParts(
      _group(plain.substring(0, dot)),
      fraction.substring(0, split),
      fraction.substring(split),
    );
  }

  final String whole;
  final String head;
  final String tail;

  static String _group(String digits) {
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }
}

/// An XMR amount in the mono face: grouped whole part, four decimals at full
/// strength, and any further decimals smaller in `textSecondary`, so the
/// eye lands on the part that matters. Tapping toggles all 12 decimals at
/// one size.
class AmountText extends StatefulWidget {
  const AmountText(
    this.atomic, {
    super.key,
    this.size,
    this.color,
    this.prefix = '',
    this.unit = ' XMR',
    this.style,
  });

  final BigInt atomic;

  /// Font size of the main part. Defaults to [style]'s size, else 14.
  final double? size;

  /// Color of the main part. The tail and [unit] stay `textSecondary`.
  final Color? color;

  /// A sign such as `+` or `-`.
  final String prefix;

  /// Shown after the number in `textSecondary`; empty to hide.
  final String unit;

  /// Base style, such as `textTheme.displayLarge` for the balance. Always
  /// set in the mono face with tabular figures.
  final TextStyle? style;

  @override
  State<AmountText> createState() => _AmountTextState();
}

class _AmountTextState extends State<AmountText> {
  bool _full = false;

  @override
  Widget build(BuildContext context) {
    final c = context.kn;
    final mono = monoStyle(
      context,
      size: widget.size ?? widget.style?.fontSize ?? 14,
    );
    final base = (widget.style?.merge(mono) ?? mono).copyWith(
      color: widget.color ?? c.text,
    );
    final dim = base.copyWith(color: c.textSecondary);
    final p = _XmrParts.of(widget.atomic, full: _full);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _full = !_full),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${widget.prefix}${p.whole}.${p.head}', style: base),
            if (p.tail.isNotEmpty)
              TextSpan(
                text: p.tail,
                // Full precision is one run at one size.
                style: _full
                    ? base
                    : dim.copyWith(fontSize: base.fontSize! * 0.8),
              ),
            if (widget.unit.isNotEmpty) TextSpan(text: widget.unit, style: dim),
          ],
        ),
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
