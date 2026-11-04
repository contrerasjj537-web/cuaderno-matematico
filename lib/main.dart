// Cuaderno v3
// Requiere:  flutter pub add flutter_math_fork http
//
// Novedades v3: fondo tipo pizarra (verde, negra o cualquier color), tiza,
// puntero visible (punto, lápiz o marcador), selección con lazo y conversión
// de escritura a mano en LaTeX (manual o automática al hacer una pausa).
// Archivos auxiliares: recognizer.dart, pen_cursor.dart, color_dialog.dart.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import 'color_dialog.dart';
import 'pen_cursor.dart';
import 'recognizer.dart';

void main() => runApp(const CuadernoApp());

class CuadernoApp extends StatelessWidget {
  const CuadernoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Cuaderno',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: const NotebookPage(),
      );
}

// ───────────────────────── Constantes y enums ─────────────────────────

const double kPageW = 794; // ~ A4 vertical
const double kPageH = 1123;

enum PaperType {
  cuadriculada,
  rayada,
  dobleLinea,
  blanca,
  puntos,
  milimetrada,
  cartesiana,
}

enum ToolType {
  pluma,
  boligrafo,
  lapiz,
  resaltador,
  tiza,
  borrador,
  mover,
  lazo,
  linea,
  flecha,
  circulo,
  rectangulo,
  ejes,
  formula,
}

extension ToolX on ToolType {
  bool get isInk => const {
        ToolType.pluma,
        ToolType.boligrafo,
        ToolType.lapiz,
        ToolType.resaltador,
        ToolType.tiza,
      }.contains(this);

  bool get isShape => const {
        ToolType.linea,
        ToolType.flecha,
        ToolType.circulo,
        ToolType.rectangulo,
        ToolType.ejes,
      }.contains(this);
}

// ───────────────────────── Utilidades ─────────────────────────

List<double> _o(Offset p) => [p.dx, p.dy];

Offset _off(dynamic l) =>
    Offset((l[0] as num).toDouble(), (l[1] as num).toDouble());

double _segDist(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final ap = p - a;
  final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / len2).clamp(0.0, 1.0).toDouble();
  return (p - (a + ab * t)).distance;
}

// ───────────────────────── Modelo ─────────────────────────

class Cmd {
  final VoidCallback undo;
  final VoidCallback redo;
  Cmd(this.undo, this.redo);
}

abstract class Item {
  bool hit(Offset p, double tol);
  void translate(Offset d);
  Map<String, dynamic> toJson();

  static Item fromJson(Map<String, dynamic> j) {
    switch (j['t']) {
      case 'stroke':
        return Stroke.fromJson(j);
      case 'shape':
        return ShapeItem.fromJson(j);
      default:
        return FormulaItem.fromJson(j);
    }
  }
}

/// Trazo a mano alzada.
class Stroke extends Item {
  final ToolType tool;
  final Color color;
  final double width;
  final List<Offset> points;
  final List<double> pressures;

  Stroke({
    required this.tool,
    required this.color,
    required this.width,
    required this.points,
    required this.pressures,
  });

  @override
  bool hit(Offset p, double tol) {
    if (points.length == 1) return (points.first - p).distance <= tol;
    for (var i = 1; i < points.length; i++) {
      if (_segDist(p, points[i - 1], points[i]) <= tol) return true;
    }
    return false;
  }

  @override
  void translate(Offset d) {
    for (var i = 0; i < points.length; i++) {
      points[i] += d;
    }
  }

  // Arreglos planos (Firestore no admite arreglos anidados).
  @override
  Map<String, dynamic> toJson() => {
        't': 'stroke',
        'tool': tool.name,
        'color': color.toARGB32(),
        'width': width,
        'x': [for (final p in points) p.dx],
        'y': [for (final p in points) p.dy],
        'p': pressures,
      };

  factory Stroke.fromJson(Map<String, dynamic> j) {
    final xs = (j['x'] as List).map((e) => (e as num).toDouble()).toList();
    final ys = (j['y'] as List).map((e) => (e as num).toDouble()).toList();
    return Stroke(
      tool: ToolType.values.byName(j['tool'] as String),
      color: Color(j['color'] as int),
      width: (j['width'] as num).toDouble(),
      points: [for (var i = 0; i < xs.length; i++) Offset(xs[i], ys[i])],
      pressures: (j['p'] as List).map((e) => (e as num).toDouble()).toList(),
    );
  }
}

/// Figura geométrica definida por dos puntos.
class ShapeItem extends Item {
  final ToolType kind;
  final Color color;
  final double width;
  final bool dashed;
  Offset a;
  Offset b;

  ShapeItem({
    required this.kind,
    required this.color,
    required this.width,
    required this.dashed,
    required this.a,
    required this.b,
  });

  @override
  bool hit(Offset p, double tol) {
    switch (kind) {
      case ToolType.linea:
      case ToolType.flecha:
        return _segDist(p, a, b) <= tol;
      case ToolType.circulo:
        return ((p - a).distance - (b - a).distance).abs() <= tol;
      case ToolType.rectangulo:
        final r = Rect.fromPoints(a, b);
        return _segDist(p, r.topLeft, r.topRight) <= tol ||
            _segDist(p, r.topRight, r.bottomRight) <= tol ||
            _segDist(p, r.bottomRight, r.bottomLeft) <= tol ||
            _segDist(p, r.bottomLeft, r.topLeft) <= tol;
      default: // ejes
        final r = Rect.fromPoints(a, b);
        final c = r.center;
        return _segDist(p, Offset(r.left, c.dy), Offset(r.right, c.dy)) <= tol ||
            _segDist(p, Offset(c.dx, r.top), Offset(c.dx, r.bottom)) <= tol;
    }
  }

  @override
  void translate(Offset d) {
    a += d;
    b += d;
  }

  @override
  Map<String, dynamic> toJson() => {
        't': 'shape',
        'kind': kind.name,
        'color': color.toARGB32(),
        'width': width,
        'dashed': dashed,
        'a': _o(a),
        'b': _o(b),
      };

  factory ShapeItem.fromJson(Map<String, dynamic> j) => ShapeItem(
        kind: ToolType.values.byName(j['kind'] as String),
        color: Color(j['color'] as int),
        width: (j['width'] as num).toDouble(),
        dashed: j['dashed'] as bool,
        a: _off(j['a']),
        b: _off(j['b']),
      );
}

/// Fórmula LaTeX (se dibuja como widget).
class FormulaItem extends Item {
  String latex;
  Offset pos;
  double size;
  final Color color;

  FormulaItem({
    required this.latex,
    required this.pos,
    required this.size,
    required this.color,
  });

  @override
  bool hit(Offset p, double tol) => false; // la manejan sus propios gestos

  @override
  void translate(Offset d) => pos += d;

  @override
  Map<String, dynamic> toJson() => {
        't': 'formula',
        'latex': latex,
        'pos': _o(pos),
        'size': size,
        'color': color.toARGB32(),
      };

  factory FormulaItem.fromJson(Map<String, dynamic> j) => FormulaItem(
        latex: j['latex'] as String,
        pos: _off(j['pos']),
        size: (j['size'] as num).toDouble(),
        color: Color(j['color'] as int),
      );
}

class NotePage {
  PaperType paper;
  Color bg;
  final List<Item> items;
  final List<Cmd> undo = [];
  final List<Cmd> redo = [];

  NotePage({
    this.paper = PaperType.cuadriculada,
    this.bg = const Color(0xFFFFFEF8),
    List<Item>? items,
  }) : items = items ?? [];

  bool get dark => bg.computeLuminance() < 0.4;

  Map<String, dynamic> toJson() => {
        'paper': paper.name,
        'bg': bg.toARGB32(),
        'items': [for (final i in items) i.toJson()],
      };

  factory NotePage.fromJson(Map<String, dynamic> j) => NotePage(
        paper: PaperType.values.byName(j['paper'] as String),
        bg: Color((j['bg'] as int?) ?? 0xFFFFFEF8),
        items: [
          for (final i in j['items'] as List)
            Item.fromJson(Map<String, dynamic>.from(i as Map)),
        ],
      );
}

// ───────────────────────── Dibujo ─────────────────────────

void drawStroke(Canvas canvas, Stroke s) {
  final paint = Paint()
    ..color = s.color
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = s.width
    ..isAntiAlias = true;

  switch (s.tool) {
    case ToolType.resaltador:
      paint
        ..color = s.color.withValues(alpha: 0.35)
        ..strokeWidth = s.width * 5
        ..strokeCap = StrokeCap.square;
      break;
    case ToolType.lapiz:
      paint
        ..color = s.color.withValues(alpha: 0.75)
        ..strokeWidth = s.width * 0.8;
      break;
    case ToolType.boligrafo:
      paint.strokeWidth = s.width * 0.7;
      break;
    case ToolType.tiza:
      paint
        ..color = s.color.withValues(alpha: 0.88)
        ..strokeWidth = s.width * 1.6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.7);
      break;
    default:
      break;
  }

  final pts = s.points;
  if (pts.length == 1) {
    canvas.drawCircle(pts.first, paint.strokeWidth / 2 + 0.5,
        paint..style = PaintingStyle.fill);
    return;
  }

  if (s.tool == ToolType.pluma) {
    for (var i = 1; i < pts.length; i++) {
      paint.strokeWidth = s.width * (0.5 + s.pressures[i]);
      canvas.drawLine(pts[i - 1], pts[i], paint);
    }
    return;
  }

  final path = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (var i = 1; i < pts.length; i++) {
    final mid = Offset(
        (pts[i - 1].dx + pts[i].dx) / 2, (pts[i - 1].dy + pts[i].dy) / 2);
    path.quadraticBezierTo(pts[i - 1].dx, pts[i - 1].dy, mid.dx, mid.dy);
  }
  path.lineTo(pts.last.dx, pts.last.dy);
  canvas.drawPath(path, paint);
  if (s.tool == ToolType.tiza) _chalkGrain(canvas, s);
}

/// Granos alrededor del trazo para imitar el polvo de la tiza.
void _chalkGrain(Canvas canvas, Stroke s) {
  double h(double x) {
    final v = math.sin(x) * 43758.5453;
    return v - v.floorToDouble();
  }

  final dots = <Offset>[];
  final r = s.width * 1.6;
  for (var i = 0; i < s.points.length; i += 2) {
    final p = s.points[i];
    for (var k = 0; k < 3; k++) {
      final a = h(p.dx * 12.9898 + p.dy * 78.233 + k * 3.1) * math.pi * 2;
      final d = h(p.dx * 4.1 + p.dy * 9.7 + k) * r;
      dots.add(p + Offset(math.cos(a), math.sin(a)) * d);
    }
  }
  canvas.drawPoints(
      ui.PointMode.points,
      dots,
      Paint()
        ..color = s.color.withValues(alpha: 0.55)
        ..strokeWidth = 1.1
        ..strokeCap = StrokeCap.round);
}

void _drawPath(Canvas c, Path path, Paint paint, bool dashed) {
  if (!dashed) {
    c.drawPath(path, paint);
    return;
  }
  for (final m in path.computeMetrics()) {
    double d = 0;
    while (d < m.length) {
      c.drawPath(m.extractPath(d, math.min(d + 8, m.length)), paint);
      d += 14;
    }
  }
}

void _drawLine(Canvas c, Offset a, Offset b, Paint paint, bool dashed) {
  _drawPath(c, Path()..moveTo(a.dx, a.dy)..lineTo(b.dx, b.dy), paint, dashed);
}

void drawArrowHead(Canvas c, Offset from, Offset to, Paint paint,
    {double size = 14}) {
  final ang = math.atan2(to.dy - from.dy, to.dx - from.dx);
  for (final spread in const [0.45, -0.45]) {
    final tip = to - Offset(math.cos(ang + spread), math.sin(ang + spread)) * size;
    c.drawLine(to, tip, paint);
  }
}

void drawShape(Canvas c, ShapeItem s) {
  final paint = Paint()
    ..color = s.color
    ..style = PaintingStyle.stroke
    ..strokeWidth = s.width * 0.8
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  switch (s.kind) {
    case ToolType.linea:
      _drawLine(c, s.a, s.b, paint, s.dashed);
      break;
    case ToolType.flecha:
      _drawLine(c, s.a, s.b, paint, s.dashed);
      drawArrowHead(c, s.a, s.b, paint);
      break;
    case ToolType.circulo:
      final path = Path()
        ..addOval(Rect.fromCircle(center: s.a, radius: (s.b - s.a).distance));
      _drawPath(c, path, paint, s.dashed);
      break;
    case ToolType.rectangulo:
      final path = Path()..addRect(Rect.fromPoints(s.a, s.b));
      _drawPath(c, path, paint, s.dashed);
      break;
    case ToolType.ejes:
      final r = Rect.fromPoints(s.a, s.b);
      final o = r.center;
      final left = Offset(r.left, o.dy), right = Offset(r.right, o.dy);
      final bottom = Offset(o.dx, r.bottom), top = Offset(o.dx, r.top);
      c.drawLine(left, right, paint);
      c.drawLine(bottom, top, paint);
      drawArrowHead(c, left, right, paint);
      drawArrowHead(c, bottom, top, paint);
      final tick = Paint()
        ..color = s.color
        ..strokeWidth = paint.strokeWidth * 0.7;
      const step = 24.0;
      for (double x = o.dx + step; x < r.right - 10; x += step) {
        c.drawLine(Offset(x, o.dy - 3), Offset(x, o.dy + 3), tick);
      }
      for (double x = o.dx - step; x > r.left + 4; x -= step) {
        c.drawLine(Offset(x, o.dy - 3), Offset(x, o.dy + 3), tick);
      }
      for (double y = o.dy + step; y < r.bottom - 4; y += step) {
        c.drawLine(Offset(o.dx - 3, y), Offset(o.dx + 3, y), tick);
      }
      for (double y = o.dy - step; y > r.top + 10; y -= step) {
        c.drawLine(Offset(o.dx - 3, y), Offset(o.dx + 3, y), tick);
      }
      break;
    default:
      break;
  }
}

void drawItem(Canvas c, Item it) {
  if (it is Stroke) {
    drawStroke(c, it);
  } else if (it is ShapeItem) {
    drawShape(c, it);
  }
}

void _grid(Canvas c, Size s, double step, Paint p) {
  for (double x = step; x < s.width; x += step) {
    c.drawLine(Offset(x, 0), Offset(x, s.height), p);
  }
  for (double y = step; y < s.height; y += step) {
    c.drawLine(Offset(0, y), Offset(s.width, y), p);
  }
}

class PaperPainter extends CustomPainter {
  final PaperType type;
  final Color bg;
  PaperPainter(this.type, this.bg);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final dark = bg.computeLuminance() < 0.4;

    final blue = Paint()
      ..color = dark
          ? Colors.white.withValues(alpha: 0.2)
          : const Color(0xFF90CAF9).withValues(alpha: 0.7)
      ..strokeWidth = 0.8;

    switch (type) {
      case PaperType.cuadriculada:
        _grid(canvas, size, 24, blue);
        break;

      case PaperType.rayada:
        for (double y = 60; y < size.height; y += 30) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), blue);
        }
        _margin(canvas, size);
        break;

      case PaperType.dobleLinea:
        const s = 52.0, gap = 26.0;
        final dash = Paint()
          ..color = blue.color.withValues(alpha: 0.5)
          ..strokeWidth = 0.6;
        for (double y = 60; y < size.height; y += s) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), blue);
          canvas.drawLine(Offset(0, y + gap), Offset(size.width, y + gap), blue);
          for (double x = 0; x < size.width; x += 10) {
            canvas.drawLine(
                Offset(x, y + gap / 2), Offset(x + 5, y + gap / 2), dash);
          }
        }
        _margin(canvas, size);
        break;

      case PaperType.puntos:
        final pts = <Offset>[
          for (double x = 24; x < size.width; x += 24)
            for (double y = 24; y < size.height; y += 24) Offset(x, y),
        ];
        canvas.drawPoints(
            ui.PointMode.points,
            pts,
            Paint()
              ..color = dark ? Colors.white54 : const Color(0xFF78909C)
              ..strokeWidth = 2.2
              ..strokeCap = StrokeCap.round);
        break;

      case PaperType.milimetrada:
        const red = Color(0xFFE57373);
        for (int i = 1; i * 6 < size.width; i++) {
          final w = i % 10 == 0 ? 1.2 : (i % 5 == 0 ? 0.8 : 0.3);
          canvas.drawLine(
              Offset(i * 6.0, 0),
              Offset(i * 6.0, size.height),
              Paint()
                ..color = red.withValues(alpha: 0.6)
                ..strokeWidth = w);
        }
        for (int i = 1; i * 6 < size.height; i++) {
          final w = i % 10 == 0 ? 1.2 : (i % 5 == 0 ? 0.8 : 0.3);
          canvas.drawLine(
              Offset(0, i * 6.0),
              Offset(size.width, i * 6.0),
              Paint()
                ..color = red.withValues(alpha: 0.6)
                ..strokeWidth = w);
        }
        break;

      case PaperType.cartesiana:
        _grid(canvas, size, 24, blue);
        final ox = (size.width / 2 / 24).round() * 24.0;
        final oy = (size.height / 2 / 24).round() * 24.0;
        final axis = Paint()
          ..color = dark ? Colors.white70 : Colors.black87
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round;
        final xa = Offset(12, oy), xb = Offset(size.width - 12, oy);
        final ya = Offset(ox, size.height - 12), yb = Offset(ox, 12);
        canvas.drawLine(xa, xb, axis);
        canvas.drawLine(ya, yb, axis);
        drawArrowHead(canvas, xa, xb, axis, size: 10);
        drawArrowHead(canvas, ya, yb, axis, size: 10);
        break;

      case PaperType.blanca:
        break;
    }
  }

  void _margin(Canvas canvas, Size size) {
    canvas.drawLine(
      const Offset(56, 0),
      Offset(56, size.height),
      Paint()
        ..color = const Color(0xFFEF9A9A)
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(PaperPainter old) => old.type != type || old.bg != bg;
}

/// Elementos ya confirmados de la página (se repinta solo si cambia [version]).
class InkPainter extends CustomPainter {
  final List<Item> items;
  final int version;
  InkPainter(this.items, this.version);

  @override
  void paint(Canvas canvas, Size size) {
    for (final it in items) {
      drawItem(canvas, it);
    }
  }

  @override
  bool shouldRepaint(InkPainter old) =>
      old.version != version || !identical(old.items, items);
}

/// Elemento que se está dibujando en este momento.
class LivePainter extends CustomPainter {
  final Item? item;
  LivePainter(this.item);

  @override
  void paint(Canvas canvas, Size size) {
    if (item != null) drawItem(canvas, item!);
  }

  @override
  bool shouldRepaint(LivePainter old) => true;
}

// ─────────────── Selección y reconocimiento (v3) ───────────────

Rect itemBounds(Item it) {
  if (it is Stroke) {
    var l = double.infinity, t = double.infinity;
    var r = -double.infinity, b = -double.infinity;
    for (final p in it.points) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b).inflate(it.width + 1);
  }
  if (it is ShapeItem) {
    if (it.kind == ToolType.circulo) {
      return Rect.fromCircle(center: it.a, radius: (it.b - it.a).distance);
    }
    return Rect.fromPoints(it.a, it.b);
  }
  if (it is FormulaItem) {
    return it.pos &
        Size(it.size * math.max(2, it.latex.length * 0.5), it.size * 1.6);
  }
  return Rect.zero;
}

bool _inPoly(Offset p, List<Offset> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) &&
        p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

/// Dibuja los trazos en negro sobre fondo blanco (lo que mejor reconocen
/// los motores de OCR matemático) y devuelve un PNG.
Future<Uint8List> renderItemsPng(List<Item> items, Rect bounds) async {
  final r = bounds.inflate(18);
  final k = (900 / math.max(r.width, r.height)).clamp(0.6, 3.0).toDouble();
  final w = (r.width * k).ceil();
  final h = (r.height * k).ceil();
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = Colors.white);
  c.scale(k);
  c.translate(-r.left, -r.top);
  c.saveLayer(
      null,
      Paint()
        ..colorFilter = const ColorFilter.mode(Colors.black, BlendMode.srcIn));
  for (final it in items) {
    drawItem(c, it);
  }
  c.restore();
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

class SelectionPainter extends CustomPainter {
  final Rect? bounds;
  final List<Offset> lasso;
  SelectionPainter(this.bounds, this.lasso);

  @override
  void paint(Canvas canvas, Size size) {
    const c = Color(0xFF3F51B5);
    final line = Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    if (bounds != null) {
      final r = bounds!.inflate(6);
      canvas.drawRect(r, Paint()..color = c.withValues(alpha: 0.07));
      _drawPath(canvas, Path()..addRect(r), line, true);
    }
    if (lasso.length > 1) {
      final path = Path()..moveTo(lasso.first.dx, lasso.first.dy);
      for (final p in lasso.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      _drawPath(canvas, path, line, true);
    }
  }

  @override
  bool shouldRepaint(SelectionPainter old) => true;
}

// ───────────────────────── Pantalla ─────────────────────────

class NotebookPage extends StatefulWidget {
  const NotebookPage({super.key});

  @override
  State<NotebookPage> createState() => _NotebookPageState();
}

class _NotebookPageState extends State<NotebookPage> {
  // Documento
  final List<NotePage> pages = [NotePage()];
  int pageIdx = 0;
  NotePage get page => pages[pageIdx];
  int _version = 0;

  // Herramientas
  ToolType tool = ToolType.pluma;
  Color color = const Color(0xDD000000);
  double width = 2.5;
  bool dashed = false;
  bool snap = false;
  bool fingerDraws = true; // true: el dedo dibuja; false: el dedo mueve la hoja
  PointerStyle pointerStyle = PointerStyle.lapiz;
  bool autoConvert = false;

  // Para activar el reconocimiento real, cambia MockRecognizer por:
  //   MathpixRecognizer('APP_ID', 'APP_KEY')   (solo pruebas)
  //   EndpointRecognizer(Uri.parse('https://.../reconocer'))   (recomendado)
  final MathRecognizer recognizer = MockRecognizer();

  // Puntero, selección y reconocimiento
  final ValueNotifier<Offset?> _cursor = ValueNotifier<Offset?>(null);
  final Set<Item> selection = {};
  List<Offset> _lasso = [];
  bool _selMoving = false;
  final List<Stroke> _recent = [];
  Timer? _autoTimer;
  int _recogToken = 0;
  bool _converting = false;
  ({String latex, List<Item> items, Rect bounds})? _suggestion;

  // Vista (zoom / desplazamiento)
  double scale = 1;
  Offset offset = Offset.zero;
  Size viewport = Size.zero;

  // Gestos
  final Map<int, Offset> _touches = {};
  Offset _lastC = Offset.zero;
  double _lastD = 1;
  bool _drawing = false;
  Item? _live;
  Item? _moving;
  Offset _moveTotal = Offset.zero;
  Offset _lastP = Offset.zero;
  List<Item> _erased = [];
  Offset _fTotal = Offset.zero;

  static const lightPalette = [
    Color(0xDD000000),
    Color(0xFF1565C0),
    Color(0xFFC62828),
    Color(0xFF2E7D32),
    Color(0xFFEF6C00),
    Color(0xFF6A1B9A),
  ];

  // Colores tipo tiza para fondos oscuros.
  static const darkPalette = [
    Color(0xFFF5F5F0),
    Color(0xFFFFEB3B),
    Color(0xFF80DEEA),
    Color(0xFFF48FB1),
    Color(0xFFA5D6A7),
    Color(0xFFFFAB91),
  ];

  static const _paperNames = {
    PaperType.cuadriculada: 'Cuadriculada',
    PaperType.rayada: 'Rayada',
    PaperType.dobleLinea: 'Doble línea',
    PaperType.blanca: 'Blanca',
    PaperType.puntos: 'Punteada',
    PaperType.milimetrada: 'Milimetrada',
    PaperType.cartesiana: 'Plano cartesiano',
  };

  static const _toolIcons = {
    ToolType.pluma: Icons.edit,
    ToolType.boligrafo: Icons.create,
    ToolType.lapiz: Icons.draw,
    ToolType.resaltador: Icons.border_color,
    ToolType.tiza: Icons.brush,
    ToolType.borrador: Icons.cleaning_services,
    ToolType.mover: Icons.open_with,
    ToolType.lazo: Icons.gesture,
    ToolType.linea: Icons.horizontal_rule,
    ToolType.flecha: Icons.arrow_right_alt,
    ToolType.circulo: Icons.circle_outlined,
    ToolType.rectangulo: Icons.crop_square,
    ToolType.ejes: Icons.stacked_line_chart,
    ToolType.formula: Icons.functions,
  };

  static const _toolNames = {
    ToolType.pluma: 'Pluma',
    ToolType.boligrafo: 'Bolígrafo',
    ToolType.lapiz: 'Lápiz',
    ToolType.resaltador: 'Resaltador',
    ToolType.tiza: 'Tiza',
    ToolType.borrador: 'Borrador',
    ToolType.mover: 'Mover / editar',
    ToolType.lazo: 'Lazo: seleccionar y convertir a LaTeX',
    ToolType.linea: 'Línea',
    ToolType.flecha: 'Flecha',
    ToolType.circulo: 'Círculo (centro y radio)',
    ToolType.rectangulo: 'Rectángulo',
    ToolType.ejes: 'Ejes cartesianos',
    ToolType.formula: 'Fórmula LaTeX',
  };

  static const _snippets = <(String, String)>[
    ('Fracción', r'\frac{a}{b}'),
    ('Raíz', r'\sqrt{x}'),
    ('Potencia', r'x^{2}'),
    ('Subíndice', r'x_{1}'),
    ('Integral', r'\int_{a}^{b} f(x)\,dx'),
    ('Sumatoria', r'\sum_{i=1}^{n} i'),
    ('Límite', r'\lim_{x \to 0} \frac{\sin x}{x}'),
    ('Derivada', r'\frac{dy}{dx}'),
    ('Sistema', r'\begin{cases} x + y = 5 \\ x - y = 1 \end{cases}'),
    ('Matriz', r'\begin{pmatrix} a & b \\ c & d \end{pmatrix}'),
    ('π θ', r'\pi \quad \theta'),
    ('≤ ≥ ≠', r'\leq \quad \geq \quad \neq'),
  ];

  // ── Utilidades ──

  Offset _toPage(Offset local) => (local - offset) / scale;

  Offset _snap(Offset p) => snap
      ? Offset((p.dx / 12).round() * 12.0, (p.dy / 12).round() * 12.0)
      : p;

  void _changed() => setState(() => _version++);

  void _push(NotePage pg, Cmd c) {
    pg.undo.add(c);
    pg.redo.clear();
  }

  double _pressure(PointerEvent e) {
    final isStylus = e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus;
    if (!isStylus || e.pressureMax <= e.pressureMin) return 0.5;
    final v = (e.pressure - e.pressureMin) / (e.pressureMax - e.pressureMin);
    return v.clamp(0.1, 1.0).toDouble();
  }

  void _fit() {
    if (viewport.isEmpty) return;
    const margin = 12.0;
    final s = ((viewport.width - 2 * margin) / kPageW).clamp(0.3, 4.0).toDouble();
    setState(() {
      scale = s;
      offset = Offset((viewport.width - kPageW * s) / 2, margin);
    });
  }

  void _zoomAt(Offset focal, double factor) {
    final ns = (scale * factor).clamp(0.3, 5.0).toDouble();
    final anchor = (focal - offset) / scale;
    setState(() {
      scale = ns;
      offset = focal - anchor * ns;
    });
  }

  // ── Zoom con dos dedos ──

  void _startPinch() {
    final v = _touches.values.take(2).toList();
    _lastC = (v[0] + v[1]) / 2;
    _lastD = math.max((v[0] - v[1]).distance, 1.0);
  }

  void _updatePinch() {
    final v = _touches.values.take(2).toList();
    final c = (v[0] + v[1]) / 2;
    final d = math.max((v[0] - v[1]).distance, 1.0);
    final ns = (scale * d / _lastD).clamp(0.3, 5.0).toDouble();
    final anchor = (_lastC - offset) / scale;
    setState(() {
      scale = ns;
      offset = c - anchor * ns;
    });
    _lastC = c;
    _lastD = d;
  }

  // ── Eventos de puntero ──

  void _onDown(PointerDownEvent e) {
    _cursor.value = e.localPosition;
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) {
      return;
    }
    if (e.kind == PointerDeviceKind.touch) {
      _touches[e.pointer] = e.localPosition;
      if (_touches.length >= 2) {
        _cursor.value = null;
        _cancelGesture();
        _startPinch();
        return;
      }
      if (!fingerDraws) return; // el dedo solo mueve la hoja
    }
    _beginTool(_toPage(e.localPosition), e);
  }

  void _onMove(PointerMoveEvent e) {
    if (_touches.length < 2) _cursor.value = e.localPosition;
    if (e.kind == PointerDeviceKind.touch) {
      if (!_touches.containsKey(e.pointer)) return;
      _touches[e.pointer] = e.localPosition;
      if (_touches.length >= 2) {
        _updatePinch();
        return;
      }
      if (!fingerDraws) {
        setState(() => offset += e.delta);
        return;
      }
    }
    _updateTool(_toPage(e.localPosition), e);
  }

  void _onUp(PointerEvent e) {
    if (e.kind == PointerDeviceKind.touch) {
      final wasPinch = _touches.length >= 2;
      _cursor.value = null;
      _touches.remove(e.pointer);
      if (wasPinch || !fingerDraws) return;
    }
    _endTool();
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || kb.isMetaPressed) {
      _zoomAt(e.localPosition, e.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1);
    } else {
      setState(() => offset -= e.scrollDelta);
    }
  }

  void _cancelGesture() {
    _endTool(commit: false);
  }

  // ── Herramientas ──

  void _beginTool(Offset p, PointerEvent e) {
    switch (tool) {
      case ToolType.borrador:
        _drawing = true;
        _erased = [];
        _eraseAt(p);
        break;

      case ToolType.mover:
        _drawing = true;
        _moving =
            page.items.reversed.where((it) => it.hit(p, 12 / scale)).firstOrNull;
        _moveTotal = Offset.zero;
        _lastP = p;
        break;

      case ToolType.lazo:
        {
          _drawing = true;
          final b = _selectionBounds();
          if (b != null && b.inflate(10 / scale).contains(p)) {
            _selMoving = true;
            _moveTotal = Offset.zero;
            _lastP = p;
          } else {
            _selMoving = false;
            selection.clear();
            setState(() => _lasso = [p]);
          }
        }
        break;

      case ToolType.formula:
        _editFormula(pos: _snap(p));
        break;

      case ToolType.linea:
      case ToolType.flecha:
      case ToolType.circulo:
      case ToolType.rectangulo:
      case ToolType.ejes:
        {
          _drawing = true;
          final a = _snap(p);
          setState(() => _live = ShapeItem(
              kind: tool, color: color, width: width, dashed: dashed, a: a, b: a));
        }
        break;

      case ToolType.pluma:
      case ToolType.boligrafo:
      case ToolType.lapiz:
      case ToolType.resaltador:
      case ToolType.tiza:
        _drawing = true;
        setState(() => _live = Stroke(
              tool: tool,
              color: color,
              width: width,
              points: [p],
              pressures: [_pressure(e)],
            ));
        break;
    }
  }

  void _updateTool(Offset p, PointerEvent e) {
    if (!_drawing) return;

    if (tool == ToolType.borrador) {
      _eraseAt(p);
      return;
    }
    if (tool == ToolType.lazo) {
      if (_selMoving) {
        final d = p - _lastP;
        _lastP = p;
        for (final it in selection) {
          it.translate(d);
        }
        _moveTotal += d;
        _changed();
      } else {
        setState(() => _lasso.add(p));
      }
      return;
    }
    if (tool == ToolType.mover) {
      final m = _moving;
      if (m == null) return;
      final d = p - _lastP;
      _lastP = p;
      m.translate(d);
      _moveTotal += d;
      _changed();
      return;
    }

    final live = _live;
    if (live is Stroke) {
      setState(() {
        live.points.add(p);
        live.pressures.add(_pressure(e));
      });
    } else if (live is ShapeItem) {
      setState(() => live.b = _snap(p));
    }
  }

  void _endTool({bool commit = true}) {
    if (!_drawing) return;
    _drawing = false;
    final pg = page;

    if (tool == ToolType.borrador) {
      final removed = List<Item>.of(_erased);
      if (removed.isNotEmpty) {
        _push(
          pg,
          Cmd(() => pg.items.addAll(removed),
              () => pg.items.removeWhere(removed.contains)),
        );
      }
      _erased = [];
    } else if (tool == ToolType.mover) {
      final m = _moving;
      final t = _moveTotal;
      if (m != null && t != Offset.zero) {
        _push(pg, Cmd(() => m.translate(-t), () => m.translate(t)));
      }
      _moving = null;
    } else if (tool == ToolType.lazo) {
      if (_selMoving) {
        final t = _moveTotal;
        final sel = selection.toList();
        if (t != Offset.zero) {
          _push(
            pg,
            Cmd(() {
              for (final it in sel) {
                it.translate(-t);
              }
            }, () {
              for (final it in sel) {
                it.translate(t);
              }
            }),
          );
        }
        _selMoving = false;
      } else if (commit) {
        _finishLasso();
      } else {
        _lasso = [];
      }
    } else {
      final it = _live;
      _live = null;
      if (commit && it != null) {
        final degenerate = it is ShapeItem && (it.a - it.b).distance < 3;
        if (!degenerate) {
          pg.items.add(it);
          _push(pg, Cmd(() => pg.items.remove(it), () => pg.items.add(it)));
          if (it is Stroke && it.tool != ToolType.resaltador) {
            _onInkCommitted(it);
          }
        }
      }
    }
    _changed();
  }

  void _eraseAt(Offset p) {
    final tol = 12 / scale;
    final hit = page.items.where((it) => it.hit(p, tol)).toList();
    if (hit.isEmpty) return;
    page.items.removeWhere(hit.contains);
    _erased.addAll(hit);
    _changed();
  }

  // ── Deshacer / rehacer ──

  void _undo() {
    final pg = page;
    if (pg.undo.isEmpty) return;
    final c = pg.undo.removeLast();
    c.undo();
    pg.redo.add(c);
    _resetRecognition();
    _changed();
  }

  void _redo() {
    final pg = page;
    if (pg.redo.isEmpty) return;
    final c = pg.redo.removeLast();
    c.redo();
    pg.undo.add(c);
    _resetRecognition();
    _changed();
  }

  // ── Páginas ──

  void _goto(int i) {
    _drawing = false;
    _live = null;
    _resetRecognition();
    setState(() {
      pageIdx = i;
      _adaptInk();
      _version++;
    });
  }

  void _addPage() {
    pages.insert(pageIdx + 1, NotePage(paper: page.paper, bg: page.bg));
    _goto(pageIdx + 1);
  }

  Future<void> _deletePage() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Borrar esta página?'),
        content: const Text('Se perderá todo lo escrito en ella.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Borrar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      if (pages.length == 1) {
        pages[0] = NotePage();
      } else {
        pages.removeAt(pageIdx);
        pageIdx = math.min(pageIdx, pages.length - 1);
      }
      _version++;
    });
  }

  // ── Fórmulas ──

  Future<void> _editFormula({
    FormulaItem? existing,
    Offset? pos,
    String? initial,
    double? initialSize,
    List<Item>? replace,
  }) async {
    final ctrl = TextEditingController(
        text: existing?.latex ?? initial ?? r'\frac{a}{b}');
    double size = existing?.size ?? initialSize ?? 28;

    void insert(String s) {
      final t = ctrl.text;
      final sel = ctrl.selection;
      final start = sel.isValid ? sel.start : t.length;
      final end = sel.isValid ? sel.end : t.length;
      ctrl.value = TextEditingValue(
        text: t.replaceRange(start, end, s),
        selection: TextSelection.collapsed(offset: start + s.length),
      );
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(existing == null ? 'Nueva fórmula' : 'Editar fórmula'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    maxLines: null,
                    decoration: const InputDecoration(
                        labelText: 'LaTeX', border: OutlineInputBorder()),
                    onChanged: (_) => setD(() {}),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in _snippets)
                        ActionChip(
                          label: Text(s.$1),
                          onPressed: () {
                            insert(s.$2);
                            setD(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 64),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black26),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ctrl.text.trim().isEmpty
                          ? const Text('Vista previa')
                          : Math.tex(
                              ctrl.text,
                              textStyle:
                                  TextStyle(
                                      fontSize: size,
                                      color: Theme.of(ctx).colorScheme.onSurface),
                              mathStyle: MathStyle.display,
                              onErrorFallback: (_) => const Text(
                                'Fórmula no válida',
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                    ),
                  ),
                  Slider(
                    min: 16,
                    max: 64,
                    value: size,
                    onChanged: (v) => setD(() => size = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Aceptar')),
          ],
        ),
      ),
    );

    if (ok != true || !mounted) return;
    final text = ctrl.text.trim();
    if (text.isEmpty) return;
    final pg = page;

    if (existing != null) {
      final oldL = existing.latex, oldS = existing.size;
      existing.latex = text;
      existing.size = size;
      _push(pg, Cmd(() {
        existing.latex = oldL;
        existing.size = oldS;
      }, () {
        existing.latex = text;
        existing.size = size;
      }));
    } else if (pos != null) {
      final old = replace ?? const <Item>[];
      final f = FormulaItem(
        latex: text,
        pos: pos,
        size: size,
        color: old.whereType<Stroke>().firstOrNull?.color ?? color,
      );
      pg.items.removeWhere(old.contains);
      pg.items.add(f);
      _push(
        pg,
        Cmd(() {
          pg.items.remove(f);
          pg.items.addAll(old);
        }, () {
          pg.items.removeWhere(old.contains);
          pg.items.add(f);
        }),
      );
      if (replace != null) {
        _recent.clear();
        selection.clear();
        _suggestion = null;
      }
    }
    _changed();
  }

  void _deleteFormula(FormulaItem f) {
    final pg = page;
    pg.items.remove(f);
    _push(pg, Cmd(() => pg.items.add(f), () => pg.items.remove(f)));
    _changed();
  }

  Widget _formulaWidget(FormulaItem f) {
    final movable = tool == ToolType.mover;
    return IgnorePointer(
      ignoring: !(movable || tool == ToolType.borrador),
      child: GestureDetector(
        onTap: () {
          if (tool == ToolType.borrador) {
            _deleteFormula(f);
          } else if (movable) {
            _editFormula(existing: f);
          }
        },
        onPanStart: (_) => _fTotal = Offset.zero,
        onPanUpdate: (d) {
          if (!movable) return;
          final dl = d.delta / scale;
          f.pos += dl;
          _fTotal += dl;
          setState(() {});
        },
        onPanEnd: (_) {
          final t = _fTotal;
          _fTotal = Offset.zero;
          if (movable && t != Offset.zero) {
            _push(page, Cmd(() => f.pos -= t, () => f.pos += t));
          }
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: movable
                ? Border.all(color: Colors.indigo.withValues(alpha: 0.35))
                : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Math.tex(
              f.latex,
              textStyle: TextStyle(fontSize: f.size, color: f.color),
              mathStyle: MathStyle.display,
              onErrorFallback: (_) => Text(f.latex,
                  style: const TextStyle(color: Colors.red, fontSize: 14)),
            ),
          ),
        ),
      ),
    );
  }

  // ── Fondo, puntero y colores (v3) ──

  static const _boards = {
    'Papel crema': Color(0xFFFFFEF8),
    'Blanco': Color(0xFFFFFFFF),
    'Pizarra verde': Color(0xFF2B4D3E),
    'Pizarra negra': Color(0xFF1C1C1E),
    'Pizarra azul': Color(0xFF1F2F4A),
  };

  static const _pointerNames = {
    PointerStyle.ninguno: 'Sin puntero',
    PointerStyle.punto: 'Punto',
    PointerStyle.lapiz: 'Lápiz',
    PointerStyle.marcador: 'Marcador',
  };

  List<Color> get _palette => page.dark ? darkPalette : lightPalette;

  /// Si el color de tinta no se ve sobre el fondo, cambia a uno legible.
  void _adaptInk() {
    final l = color.computeLuminance();
    if (page.dark && l < 0.35) {
      color = darkPalette.first;
    } else if (!page.dark && l > 0.7) {
      color = lightPalette.first;
    }
  }

  void _setBg(Color c) {
    page.bg = c;
    _adaptInk();
    _changed();
  }

  Future<void> _onHojaMenu(String v) async {
    if (v.startsWith('paper:')) {
      page.paper = PaperType.values.byName(v.substring(6));
      _changed();
    } else if (v == 'bg:custom') {
      final c = await pickColor(context, page.bg, title: 'Color del fondo');
      if (c != null && mounted) _setBg(c);
    } else if (v.startsWith('bg:')) {
      final c = _boards[v.substring(3)];
      if (c != null) _setBg(c);
    } else if (v == 'all') {
      for (final p in pages) {
        p.bg = page.bg;
      }
      _changed();
    }
  }

  void _onHover(PointerHoverEvent e) => _cursor.value = e.localPosition;

  @override
  void dispose() {
    _autoTimer?.cancel();
    _cursor.dispose();
    super.dispose();
  }

  // ── Selección con lazo ──

  Rect? _selectionBounds() {
    Rect? r;
    for (final it in selection) {
      if (!page.items.contains(it)) continue;
      final b = itemBounds(it);
      r = r == null ? b : r.expandToInclude(b);
    }
    return r;
  }

  List<Offset> _samples(Item it) {
    if (it is Stroke) {
      final step = math.max(1, it.points.length ~/ 40);
      return [for (var i = 0; i < it.points.length; i += step) it.points[i]];
    }
    if (it is ShapeItem) return [it.a, it.b, (it.a + it.b) / 2];
    return const [];
  }

  void _finishLasso() {
    final poly = _lasso;
    _lasso = [];
    selection.clear();
    if (poly.length >= 2) {
      var l = double.infinity, t = double.infinity;
      var r = -double.infinity, b = -double.infinity;
      for (final p in poly) {
        l = math.min(l, p.dx);
        t = math.min(t, p.dy);
        r = math.max(r, p.dx);
        b = math.max(b, p.dy);
      }
      if (r - l < 8 && b - t < 8) {
        // Toque simple: selecciona el elemento que esté debajo.
        final hit = page.items.reversed
            .where((it) => it is! FormulaItem && it.hit(poly.first, 12 / scale))
            .firstOrNull;
        if (hit != null) selection.add(hit);
      } else {
        for (final it in page.items) {
          final pts = _samples(it);
          if (pts.isEmpty) continue;
          final inside = pts.where((q) => _inPoly(q, poly)).length;
          if (inside / pts.length >= 0.6) selection.add(it);
        }
      }
    }
    _changed();
  }

  void _deleteSelection() {
    final pg = page;
    final sel = selection.where(pg.items.contains).toList();
    if (sel.isEmpty) return;
    pg.items.removeWhere(sel.contains);
    _push(pg,
        Cmd(() => pg.items.addAll(sel), () => pg.items.removeWhere(sel.contains)));
    selection.clear();
    _changed();
  }

  // ── Escritura a mano → LaTeX ──

  void _resetRecognition() {
    _autoTimer?.cancel();
    _recent.clear();
    _suggestion = null;
    _converting = false;
    _recogToken++;
    selection.clear();
  }

  /// Cada trazo terminado se acumula; al hacer una pausa (modo automático)
  /// se intenta reconocer todo lo escrito en esa ráfaga.
  void _onInkCommitted(Stroke s) {
    _recent.add(s);
    _recogToken++;
    _suggestion = null;
    _converting = false;
    _autoTimer?.cancel();
    if (autoConvert) {
      _autoTimer = Timer(const Duration(milliseconds: 1600), () {
        if (!mounted) return;
        final items = _recent.where(page.items.contains).toList();
        if (items.isNotEmpty) _recognize(items);
      });
    }
  }

  Future<void> _recognize(List<Item> items) async {
    final strokes = items.whereType<Stroke>().toList();
    if (strokes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Selecciona trazos hechos a mano para convertirlos')));
      return;
    }
    final token = ++_recogToken;
    final bounds =
        strokes.map(itemBounds).reduce((a, b) => a.expandToInclude(b));
    setState(() {
      _converting = true;
      _suggestion = null;
    });
    try {
      final png = await renderItemsPng(strokes, bounds);
      final latex = await recognizer.recognize(png);
      if (!mounted || token != _recogToken) return;
      setState(() {
        _converting = false;
        _suggestion = (latex: latex, items: strokes, bounds: bounds);
      });
    } catch (e) {
      if (!mounted || token != _recogToken) return;
      setState(() => _converting = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo convertir: $e')));
    }
  }

  double _guessSize(Rect b) => (b.height * 0.7).clamp(20.0, 56.0).toDouble();

  void _acceptSuggestion() {
    final s = _suggestion;
    if (s == null) return;
    final pg = page;
    final items = s.items;
    final f = FormulaItem(
      latex: s.latex,
      pos: s.bounds.topLeft,
      size: _guessSize(s.bounds),
      color: items.whereType<Stroke>().firstOrNull?.color ?? color,
    );
    pg.items.removeWhere(items.contains);
    pg.items.add(f);
    _push(
      pg,
      Cmd(() {
        pg.items.remove(f);
        pg.items.addAll(items);
      }, () {
        pg.items.removeWhere(items.contains);
        pg.items.add(f);
      }),
    );
    _recent.clear();
    selection.clear();
    _suggestion = null;
    _changed();
  }

  void _editSuggestion() {
    final s = _suggestion;
    if (s == null) return;
    _editFormula(
      pos: s.bounds.topLeft,
      initial: s.latex,
      initialSize: _guessSize(s.bounds),
      replace: s.items,
    );
  }

  // ── Interfaz ──

  Widget _pageView() {
    final pg = page;
    return SizedBox(
      width: kPageW,
      height: kPageH,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black38)],
        ),
        child: ClipRect(
          child: Stack(
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                    child: CustomPaint(painter: PaperPainter(pg.paper, pg.bg))),
              ),
              Positioned.fill(
                child: RepaintBoundary(
                    child: CustomPaint(painter: InkPainter(pg.items, _version))),
              ),
              Positioned.fill(
                child: CustomPaint(painter: LivePainter(_live)),
              ),
              Positioned.fill(
                child: CustomPaint(
                    painter: SelectionPainter(_selectionBounds(), _lasso)),
              ),
              for (final f in pg.items.whereType<FormulaItem>())
                Positioned(
                  key: ObjectKey(f),
                  left: f.pos.dx,
                  top: f.pos.dy,
                  child: _formulaWidget(f),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pageBar(ColorScheme scheme) {
    return Material(
      elevation: 3,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: pageIdx > 0 ? () => _goto(pageIdx - 1) : null,
          ),
          Text('${pageIdx + 1} / ${pages.length}'),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed:
                pageIdx < pages.length - 1 ? () => _goto(pageIdx + 1) : null,
          ),
          IconButton(
            tooltip: 'Nueva página',
            icon: const Icon(Icons.note_add_outlined),
            onPressed: _addPage,
          ),
          IconButton(
            tooltip: 'Borrar página',
            icon: const Icon(Icons.delete_outline),
            onPressed: _deletePage,
          ),
        ],
      ),
    );
  }

  Widget _toolButton(ToolType t, ColorScheme scheme) {
    final sel = t == tool;
    return IconButton(
      tooltip: _toolNames[t],
      icon: Icon(_toolIcons[t]),
      style: IconButton.styleFrom(
          backgroundColor: sel ? scheme.primaryContainer : null),
      onPressed: () => setState(() {
        tool = t;
        if (t != ToolType.lazo) selection.clear();
      }),
    );
  }

  Widget _toggle(String tip, IconData icon, bool value, VoidCallback onTap,
      ColorScheme scheme) {
    return IconButton(
      tooltip: tip,
      icon: Icon(icon),
      style: IconButton.styleFrom(
          backgroundColor: value ? scheme.secondaryContainer : null),
      onPressed: onTap,
    );
  }

  Widget _toolbar(ColorScheme scheme) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final t in ToolType.values) _toolButton(t, scheme),
                  const SizedBox(height: 24, child: VerticalDivider()),
                  _toggle('Línea punteada', Icons.line_style, dashed,
                      () => setState(() => dashed = !dashed), scheme),
                  _toggle('Imán a la cuadrícula', Icons.grid_4x4, snap,
                      () => setState(() => snap = !snap), scheme),
                  _toggle(
                    'Convertir a LaTeX al hacer una pausa',
                    Icons.auto_fix_high,
                    autoConvert,
                    () => setState(() {
                      autoConvert = !autoConvert;
                      if (!autoConvert) _autoTimer?.cancel();
                    }),
                    scheme,
                  ),
                ],
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final c in _palette)
                          GestureDetector(
                            onTap: () => setState(() => color = c),
                            child: Container(
                              width: 30,
                              height: 30,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color:
                                      c == color ? Colors.black : Colors.white,
                                  width: c == color ? 3 : 1.5,
                                ),
                              ),
                            ),
                          ),
                        GestureDetector(
                          onTap: () async {
                            final c = await pickColor(context, color,
                                title: 'Color del trazo');
                            if (c != null) setState(() => color = c);
                          },
                          child: Container(
                            width: 30,
                            height: 30,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.black38),
                              gradient: const SweepGradient(colors: [
                                Colors.red,
                                Colors.yellow,
                                Colors.green,
                                Colors.cyan,
                                Colors.blue,
                                Colors.purple,
                                Colors.red,
                              ]),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: 130,
                  child: Slider(
                    min: 1,
                    max: 10,
                    value: width,
                    onChanged: (v) => setState(() => width = v),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<PopupMenuEntry<String>> _hojaItems() => [
        const PopupMenuItem<String>(
          enabled: false,
          height: 32,
          child:
              Text('Tipo de hoja', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final t in PaperType.values)
          CheckedPopupMenuItem<String>(
            value: 'paper:${t.name}',
            checked: t == page.paper,
            child: Text(_paperNames[t]!),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          enabled: false,
          height: 32,
          child: Text('Fondo', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final e in _boards.entries)
          CheckedPopupMenuItem<String>(
            value: 'bg:${e.key}',
            checked: page.bg == e.value,
            child: Text(e.key),
          ),
        const PopupMenuItem<String>(value: 'bg:custom', child: Text('Otro color…')),
        const PopupMenuItem<String>(
            value: 'all', child: Text('Aplicar este fondo a todas las páginas')),
      ];

  Widget _selectionBar(ColorScheme scheme) {
    return Material(
      elevation: 3,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: _converting ? null : () => _recognize(selection.toList()),
            icon: const Icon(Icons.functions),
            label: const Text('Convertir a LaTeX'),
          ),
          IconButton(
            tooltip: 'Eliminar selección',
            icon: const Icon(Icons.delete_outline),
            onPressed: _deleteSelection,
          ),
          IconButton(
            tooltip: 'Quitar selección',
            icon: const Icon(Icons.close),
            onPressed: () => setState(selection.clear),
          ),
        ],
      ),
    );
  }

  Widget _suggestionCard(ColorScheme scheme) {
    final s = _suggestion;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(16),
      color: scheme.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: s == null
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Text('Reconociendo escritura…'),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Math.tex(
                          s.latex,
                          textStyle:
                              TextStyle(fontSize: 22, color: scheme.onSurface),
                          onErrorFallback: (_) => Text(s.latex,
                              style: const TextStyle(color: Colors.red)),
                        ),
                      ),
                    ),
                    TextButton(
                        onPressed: _editSuggestion, child: const Text('Editar')),
                    IconButton(
                      tooltip: 'Descartar',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _suggestion = null;
                        _recent.clear();
                      }),
                    ),
                    FilledButton(
                        onPressed: _acceptSuggestion,
                        child: const Text('Aceptar')),
                  ],
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final penVisible = tool.isInk && pointerStyle != PointerStyle.ninguno;
    final hasSelection = _selectionBounds() != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cuaderno'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: page.undo.isEmpty ? null : _undo,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            onPressed: page.redo.isEmpty ? null : _redo,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.grid_on),
            tooltip: 'Hoja y fondo',
            onSelected: _onHojaMenu,
            itemBuilder: (_) => _hojaItems(),
          ),
          PopupMenuButton<PointerStyle>(
            icon: const Icon(Icons.near_me),
            tooltip: 'Puntero',
            onSelected: (v) => setState(() => pointerStyle = v),
            itemBuilder: (_) => [
              for (final s in PointerStyle.values)
                CheckedPopupMenuItem<PointerStyle>(
                  value: s,
                  checked: s == pointerStyle,
                  child: Text(_pointerNames[s]!),
                ),
            ],
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'finger') {
                setState(() => fingerDraws = !fingerDraws);
              } else if (v == 'fit') {
                _fit();
              }
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem<String>(
                value: 'finger',
                checked: fingerDraws,
                child: const Text('El dedo dibuja'),
              ),
              const PopupMenuItem<String>(
                value: 'fit',
                child: Text('Ajustar hoja a la pantalla'),
              ),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final size = Size(c.maxWidth, c.maxHeight);
          if (viewport != size) {
            final first = viewport == Size.zero;
            viewport = size;
            if (first) {
              WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
            }
          }
          final m = Matrix4(scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, 1, 0,
              offset.dx, offset.dy, 0, 1);
          return Stack(
            children: [
              MouseRegion(
                cursor: (penVisible || tool == ToolType.borrador)
                    ? SystemMouseCursors.none
                    : SystemMouseCursors.basic,
                onExit: (_) => _cursor.value = null,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerHover: _onHover,
                  onPointerDown: _onDown,
                  onPointerMove: _onMove,
                  onPointerUp: _onUp,
                  onPointerCancel: _onUp,
                  onPointerSignal: _onSignal,
                  child: ClipRect(
                    child: ColoredBox(
                      color: Colors.grey.shade400,
                      child: SizedBox.expand(
                        child: Transform(
                          transform: m,
                          child: OverflowBox(
                            alignment: Alignment.topLeft,
                            minWidth: 0,
                            minHeight: 0,
                            maxWidth: kPageW,
                            maxHeight: kPageH,
                            child: _pageView(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: PenCursorPainter(
                      position: _cursor,
                      style: tool.isInk ? pointerStyle : PointerStyle.ninguno,
                      color: color,
                      radius: math.max(width * scale / 2, 1.5),
                      eraser: tool == ToolType.borrador,
                      eraserRadius: 12 * scale,
                    ),
                  ),
                ),
              ),
              if (_converting || _suggestion != null)
                Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: Center(child: _suggestionCard(scheme)),
                ),
              Positioned(
                bottom: 10,
                left: 0,
                right: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasSelection) ...[
                      _selectionBar(scheme),
                      const SizedBox(height: 8),
                    ],
                    _pageBar(scheme),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: _toolbar(scheme),
    );
  }
}