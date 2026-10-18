import 'package:web/web.dart' as web;

bool webGlAvailable() {
  try {
    final canvas = web.document.createElement('canvas') as web.HTMLCanvasElement;
    return canvas.getContext('webgl2') != null || canvas.getContext('webgl') != null;
  } catch (_) {
    return true;
  }
}
