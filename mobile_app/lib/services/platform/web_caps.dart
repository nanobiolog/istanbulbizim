import 'web_caps_stub.dart' if (dart.library.js_interop) 'web_caps_web.dart' as impl;

/// False in browsers without WebGL (hardware acceleration off / blocklisted GPU). Flutter then
/// renders on the CPU, so the app switches to a lighter mode. Always true on mobile.
bool get gpuRenderingAvailable => impl.webGlAvailable();
