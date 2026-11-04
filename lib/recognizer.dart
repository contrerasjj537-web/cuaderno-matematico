import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Convierte una imagen PNG (escritura a mano) en código LaTeX.
abstract class MathRecognizer {
  Future<String> recognize(Uint8List png);
}

/// Simulado: sirve para probar toda la interfaz sin conexión ni claves.
class MockRecognizer implements MathRecognizer {
  @override
  Future<String> recognize(Uint8List png) async {
    await Future.delayed(const Duration(milliseconds: 700));
    return r'x^{2} + y^{2} = r^{2}';
  }
}

/// Mathpix directo. SOLO PARA PRUEBAS: la clave queda dentro de la app.
/// En producción usa [EndpointRecognizer] con tu propio servidor.
class MathpixRecognizer implements MathRecognizer {
  final String appId;
  final String appKey;
  MathpixRecognizer(this.appId, this.appKey);

  @override
  Future<String> recognize(Uint8List png) async {
    final res = await http.post(
      Uri.parse('https://api.mathpix.com/v3/text'),
      headers: {
        'app_id': appId,
        'app_key': appKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'src': 'data:image/png;base64,${base64Encode(png)}',
        'formats': ['latex_simplified'],
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Mathpix respondió ${res.statusCode}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final latex = _clean((j['latex_simplified'] ?? j['text'] ?? '') as String);
    if (latex.isEmpty) throw Exception('No se reconoció ninguna fórmula');
    return latex;
  }
}

/// Tu propio servidor (por ejemplo una Cloud Function de Firebase).
/// Recibe  POST {"image": "<png en base64>"}  y responde  {"latex": "..."}.
/// Ahí puedes llamar a Mathpix o a un modelo multimodal sin exponer claves.
class EndpointRecognizer implements MathRecognizer {
  final Uri url;
  final Future<String?> Function()? authToken;
  EndpointRecognizer(this.url, {this.authToken});

  @override
  Future<String> recognize(Uint8List png) async {
    final token = await authToken?.call();
    final res = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'image': base64Encode(png)}),
    );
    if (res.statusCode != 200) {
      throw Exception('El servidor respondió ${res.statusCode}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final latex = _clean((j['latex'] ?? '') as String);
    if (latex.isEmpty) throw Exception('No se reconoció ninguna fórmula');
    return latex;
  }
}

/// Quita delimitadores como \( \), \[ \], $ $ y $$ $$.
String _clean(String s) {
  var t = s.trim();
  const pairs = [
    [r'\(', r'\)'],
    [r'\[', r'\]'],
    [r'$$', r'$$'],
    [r'$', r'$'],
  ];
  for (final p in pairs) {
    if (t.length >= p[0].length + p[1].length &&
        t.startsWith(p[0]) &&
        t.endsWith(p[1])) {
      t = t.substring(p[0].length, t.length - p[1].length).trim();
      break;
    }
  }
  return t;
}
