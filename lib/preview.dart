import 'package:flutter/material.dart';

import 'detector.dart';

class DetectorPreview extends StatefulWidget {
  final DetectionList detectionList;

  const DetectorPreview({
    super.key,
    required this.detectionList,
  });

  @override
  _DetectorPreviewState createState() => _DetectorPreviewState();
}

class _DetectorPreviewState extends State<DetectorPreview> {
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _DetectorPreviewPainter(widget.detectionList),
    );
  }
}

class _DetectorPreviewPainter extends CustomPainter {
  final DetectionList detections;

  _DetectorPreviewPainter(this.detections);

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final textBackgroundPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    const TextStyle textStyle = TextStyle(
      color: Colors.white,
      fontSize: 6.0,
    );

    for (var detection in detections.detections) {
      // バウンディングボックスの計算
      final rect = detection.scaledRect(size.width, size.height);

      // バウンディングボックスの描画
      canvas.drawRect(rect, boxPaint);

      // テキストサイズの計算
      final textSpan = TextSpan(
        text: '${detection.label} (${detection.confidence.toStringAsFixed(2)})',
        style: textStyle,
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();

      // テキストの背景の描画
      final textWidth = textPainter.width;
      final textHeight = textPainter.height;
      canvas.drawRect(
        Rect.fromLTWH(rect.left, rect.top, textWidth + 6, textHeight + 6),
        textBackgroundPaint,
      );

      // テキストの描画
      textPainter.paint(canvas, rect.topLeft);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}