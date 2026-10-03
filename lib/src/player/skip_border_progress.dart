import 'package:flutter/material.dart';

/// Countdown drawn on the capsule edge, without sampling the video.
class SkipBorderProgress extends CustomPainter {
  const SkipBorderProgress(this.remaining);
  final double remaining;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(1),
          Radius.circular(size.height / 2),
        ),
      );
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    for (final metric in path.computeMetrics()) {
      canvas.drawPath(
        metric.extractPath(0, metric.length * remaining.clamp(0, 1)),
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(SkipBorderProgress oldDelegate) =>
      remaining != oldDelegate.remaining;
}
