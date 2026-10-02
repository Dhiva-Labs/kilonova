import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// The sync indicator from docs/DESIGN.md: a thin orbit with a gold arc for
/// progress and a dot at its end. Purely progress-driven, so it never
/// animates on its own.
class SyncOrbit extends StatelessWidget {
  const SyncOrbit({super.key, required this.progress, this.size = 28});

  /// 0 to 1.
  final double progress;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.kn;
    return CustomPaint(
      size: Size.square(size),
      painter: _OrbitPainter(
        progress: progress.clamp(0, 1),
        track: c.border,
        arc: c.accent,
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.progress,
    required this.track,
    required this.arc,
  });

  final double progress;
  final Color track;
  final Color arc;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.09;
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - stroke;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, line..color = track);
    final sweep = 2 * pi * progress;
    if (sweep > 0) {
      canvas.drawArc(rect, -pi / 2, sweep, false, line..color = arc);
    }
    final end = -pi / 2 + sweep;
    canvas.drawCircle(
      center + Offset(cos(end), sin(end)) * radius,
      stroke * 1.2,
      Paint()..color = arc,
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter old) =>
      old.progress != progress || old.track != track || old.arc != arc;
}
