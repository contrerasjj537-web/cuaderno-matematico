import 'package:flutter/material.dart';

const _presets = [
  Color(0xFFFFFEF8),
  Color(0xFFFFF9C4),
  Color(0xFFE8F5E9),
  Color(0xFFE3F2FD),
  Color(0xFF2B4D3E),
  Color(0xFF1C1C1E),
  Color(0xFF1F2F4A),
  Color(0xFF4E342E),
];

/// Diálogo sencillo para elegir cualquier color (sliders R, G, B).
Future<Color?> pickColor(
  BuildContext context,
  Color initial, {
  String title = 'Elige un color',
}) {
  final v = initial.toARGB32();
  int r = (v >> 16) & 0xFF;
  int g = (v >> 8) & 0xFF;
  int b = v & 0xFF;

  return showDialog<Color>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        final current = Color.fromARGB(255, r, g, b);

        Widget slider(
            String label, int value, Color active, ValueChanged<int> onChanged) {
          return Row(
            children: [
              SizedBox(width: 18, child: Text(label)),
              Expanded(
                child: Slider(
                  min: 0,
                  max: 255,
                  value: value.toDouble(),
                  activeColor: active,
                  onChanged: (x) => setD(() => onChanged(x.round())),
                ),
              ),
              SizedBox(width: 32, child: Text('$value')),
            ],
          );
        }

        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in _presets)
                      GestureDetector(
                        onTap: () => setD(() {
                          final pv = p.toARGB32();
                          r = (pv >> 16) & 0xFF;
                          g = (pv >> 8) & 0xFF;
                          b = pv & 0xFF;
                        }),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: p,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.black26),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: current,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.black26),
                  ),
                ),
                slider('R', r, Colors.red, (x) => r = x),
                slider('G', g, Colors.green, (x) => g = x),
                slider('B', b, Colors.blue, (x) => b = x),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, current),
                child: const Text('Aceptar')),
          ],
        );
      },
    ),
  );
}
