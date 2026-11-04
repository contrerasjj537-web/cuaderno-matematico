import 'dart:math' as math;

import 'package:flutter/material.dart';

enum PointerStyle { ninguno, punto, lapiz, marcador }

/// Dibuja el puntero sobre la hoja. La punta queda exactamente en el punto de
/// contacto; [position] se actualiza sin reconstruir la pantalla.
class PenCursorPainter extends CustomPainter {
  final ValueNotifier<Offset?> position;
  final PointerStyle style;
  final Color color;
  final double radius; // radio del trazo, en pantalla
  final bool eraser;
  final double eraserRadius;

  PenCursorPainter({
    required this.position,
    required this.style,
    required this.color,
    required this.radius,
    required this.eraser,
    required this.eraserRadius,
  }) : super(repaint: position);

  @override
  void paint(Canvas canvas, Size size) {
    final p = position.value;
    if (p == null) return;

    if (eraser) {
      canvas.drawCircle(
          p,
          eraserRadius,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.07)
            ..style = PaintingStyle.fill);
      canvas.drawCircle(
          p,
          eraserRadius,
          Paint()
            ..color = Colors.black54
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
      return;
    }

    switch (style) {
      case PointerStyle.ninguno:
        break;
      case PointerStyle.punto:
        canvas.drawCircle(p, radius, Paint()..color = color.withValues(alpha: 0.35));
        canvas.drawCircle(
            p,
            radius,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1);
        break;
      case PointerStyle.lapiz:
        _pencil(canvas, p);
        break;
      case PointerStyle.marcador:
        _marker(canvas, p);
        break;
    }
  }

  Paint get _outline => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1
    ..color = Colors.black54;

  void _pencil(Canvas c, Offset p) {
    c.save();
    c.translate(p.dx, p.dy);
    c.rotate(-math.pi / 4); // el cuerpo sube hacia la derecha

    final wood = Path()
      ..moveTo(0, 0)
      ..lineTo(16, -5)
      ..lineTo(16, 5)
      ..close();
    c.drawPath(wood, Paint()..color = const Color(0xFFF1D3A5));
    c.drawPath(wood, _outline);

    final lead = Path()
      ..moveTo(0, 0)
      ..lineTo(5, -1.9)
      ..lineTo(5, 1.9)
      ..close();
    c.drawPath(lead, Paint()..color = color);

    const body = Rect.fromLTRB(16, -5, 56, 5);
    c.drawRect(body, Paint()..color = const Color(0xFFFFC107));
    c.drawRect(body, _outline);

    const ferrule = Rect.fromLTRB(56, -5, 62, 5);
    c.drawRect(ferrule, Paint()..color = const Color(0xFFB0BEC5));
    c.drawRect(ferrule, _outline);

    final eraserRect = RRect.fromLTRBR(62, -5, 70, 5, const Radius.circular(2));
    c.drawRRect(eraserRect, Paint()..color = const Color(0xFFEF9A9A));
    c.drawRRect(eraserRect, _outline);

    c.restore();
  }

  void _marker(Canvas c, Offset p) {
    c.save();
    c.translate(p.dx, p.dy);
    c.rotate(-math.pi / 4);

    final nib = Path()
      ..moveTo(0, 0)
      ..lineTo(10, -6)
      ..lineTo(10, 6)
      ..close();
    c.drawPath(nib, Paint()..color = color);
    c.drawPath(nib, _outline);

    final body = RRect.fromLTRBR(10, -7, 52, 7, const Radius.circular(3));
    c.drawRRect(body, Paint()..color = const Color(0xFFECEFF1));
    c.drawRRect(body, _outline);

    c.drawRect(const Rect.fromLTRB(10, -7, 22, 7), Paint()..color = color);

    final cap = RRect.fromLTRBR(52, -6, 60, 6, const Radius.circular(3));
    c.drawRRect(cap, Paint()..color = color);
    c.drawRRect(cap, _outline);

    c.restore();
  }

  @override
  bool shouldRepaint(PenCursorPainter old) =>
      old.style != style ||
      old.color != color ||
      old.radius != radius ||
      old.eraser != eraser ||
      old.eraserRadius != eraserRadius;
}
