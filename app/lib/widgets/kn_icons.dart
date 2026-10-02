import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Kilonova's own glyphs for core actions. Everything else uses Material
/// Symbols. Drawn on a 20px grid with a 1.5px square-capped stroke; the
/// stroke scales with the icon.
enum KnIcons { send, receive, scan, paste, contacts, lock, sync, wallet }

/// One [KnIcons] glyph, in [color] or the ambient icon color.
class KnIcon extends StatelessWidget {
  const KnIcon(this.icon, {super.key, this.size = 20, this.color});

  final KnIcons icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: KnIconPainter(
          icon,
          color ?? IconTheme.of(context).color ?? context.kn.text,
        ),
      ),
    );
  }
}

class KnIconPainter extends CustomPainter {
  const KnIconPainter(this.icon, this.color);

  final KnIcons icon;
  final Color color;

  /// The grid every glyph is drawn on.
  static const box = 20.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / box, size.height / box);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter;
    final fill = Paint()..color = color;

    void poly(List<Offset> points) =>
        canvas.drawPath(Path()..addPolygon(points, false), line);

    switch (icon) {
      case KnIcons.send:
        poly(const [Offset(6, 12), Offset(15, 3)]);
        poly(const [Offset(8.5, 3), Offset(15, 3), Offset(15, 9.5)]);
        poly(const [Offset(3, 17), Offset(10, 17)]);
      case KnIcons.receive:
        poly(const [Offset(14, 3), Offset(5, 12)]);
        poly(const [Offset(5, 5.5), Offset(5, 12), Offset(11.5, 12)]);
        poly(const [Offset(3, 17), Offset(17, 17)]);
      case KnIcons.scan:
        const a = 3.0, b = 17.0, l = 4.0;
        poly(const [Offset(a, a + l), Offset(a, a), Offset(a + l, a)]);
        poly(const [Offset(b - l, a), Offset(b, a), Offset(b, a + l)]);
        poly(const [Offset(b, b - l), Offset(b, b), Offset(b - l, b)]);
        poly(const [Offset(a + l, b), Offset(a, b), Offset(a, b - l)]);
        poly(const [Offset(7, 10), Offset(13, 10)]);
      case KnIcons.paste:
        poly(const [
          Offset(7, 4),
          Offset(4, 4),
          Offset(4, 17.5),
          Offset(16, 17.5),
          Offset(16, 4),
          Offset(13, 4),
        ]);
        canvas.drawRect(const Rect.fromLTRB(7, 2.5, 13, 5.5), line);
      case KnIcons.contacts:
        canvas
          ..drawCircle(const Offset(7.5, 8), 3.5, line)
          ..drawCircle(const Offset(12.5, 8), 3.5, line);
        poly(const [Offset(3, 16), Offset(17, 16)]);
      case KnIcons.lock:
        canvas.drawPath(
          Path()
            ..moveTo(6.5, 9)
            ..lineTo(6.5, 6.5)
            ..arcToPoint(
              const Offset(13.5, 6.5),
              radius: const Radius.circular(3.5),
            )
            ..lineTo(13.5, 9),
          line,
        );
        canvas.drawRect(const Rect.fromLTRB(4.5, 9, 15.5, 17), line);
      case KnIcons.sync:
        const center = Offset(10, 10), r = 6.5;
        canvas
          ..drawCircle(center, r, line)
          ..drawCircle(
            center + Offset(cos(-pi / 4), sin(-pi / 4)) * r,
            2,
            fill,
          );
      case KnIcons.wallet:
        canvas.drawRRect(
          RRect.fromLTRBR(3, 5, 17, 16, const Radius.circular(2)),
          line,
        );
        poly(const [
          Offset(17, 8.5),
          Offset(12.5, 8.5),
          Offset(12.5, 12.5),
          Offset(17, 12.5),
        ]);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(KnIconPainter old) =>
      old.icon != icon || old.color != color;
}
