import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Tiny software 3D renderer (pure Dart, works the same on mobile and on the WASM website).
///
/// Right-handed, metres, +y up. Meshes are unindexed triangle soups with a colour per triangle;
/// rendering is painter's-algorithm (depth-sorted), flat shaded with a key light, with fog.
class Mesh {
  final List<double> p = []; // 9 doubles per triangle
  final List<int> c = []; // ARGB per triangle
  final List<int> f = []; // flags per triangle (1 = emissive / unlit)

  int get triangles => c.length;

  void tri(double ax, double ay, double az, double bx, double by, double bz, double cx, double cy, double cz,
      Color color,
      {bool emissive = false}) {
    p..add(ax)..add(ay)..add(az)..add(bx)..add(by)..add(bz)..add(cx)..add(cy)..add(cz);
    c.add(color.toARGB32());
    f.add(emissive ? 1 : 0);
  }

  /// Quad p0-p1-p2-p3 (in order around the edge).
  void quad(List<double> a, List<double> b, List<double> cc, List<double> d, Color color, {bool emissive = false}) {
    tri(a[0], a[1], a[2], b[0], b[1], b[2], cc[0], cc[1], cc[2], color, emissive: emissive);
    tri(a[0], a[1], a[2], cc[0], cc[1], cc[2], d[0], d[1], d[2], color, emissive: emissive);
  }

  /// Axis-aligned box from min corner (x0,y0,z0) to max corner (x1,y1,z1).
  /// [faces] bit mask: 1 top, 2 bottom, 4 -x, 8 +x, 16 -z, 32 +z.
  void box(double x0, double y0, double z0, double x1, double y1, double z1, Color color,
      {int faces = 63, Color? top, Color? side, bool emissive = false}) {
    final t = top ?? color, s = side ?? color;
    if (faces & 1 != 0) quad([x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1], t, emissive: emissive);
    if (faces & 2 != 0) quad([x0, y0, z0], [x0, y0, z1], [x1, y0, z1], [x1, y0, z0], color, emissive: emissive);
    if (faces & 4 != 0) quad([x0, y0, z0], [x0, y1, z0], [x0, y1, z1], [x0, y0, z1], s, emissive: emissive);
    if (faces & 8 != 0) quad([x1, y0, z0], [x1, y0, z1], [x1, y1, z1], [x1, y1, z0], s, emissive: emissive);
    if (faces & 16 != 0) quad([x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0], color, emissive: emissive);
    if (faces & 32 != 0) quad([x0, y0, z1], [x0, y1, z1], [x1, y1, z1], [x1, y0, z1], color, emissive: emissive);
  }

  /// Horizontal tiled floor (checker of two shades) — gives the floor its grid look and keeps
  /// triangles small so depth sorting stays stable.
  void tiledFloor(double x0, double z0, double x1, double z1, double y, double tile, Color a, Color b) {
    final nx = math.max(1, ((x1 - x0) / tile).round()), nz = math.max(1, ((z1 - z0) / tile).round());
    final dx = (x1 - x0) / nx, dz = (z1 - z0) / nz;
    for (var i = 0; i < nx; i++) {
      for (var k = 0; k < nz; k++) {
        final xa = x0 + i * dx, za = z0 + k * dz;
        quad([xa, y, za], [xa + dx, y, za], [xa + dx, y, za + dz], [xa, y, za + dz], (i + k).isEven ? a : b);
      }
    }
  }

  /// Vertical wall in the x-y plane at z, subdivided into panels.
  void wallX(double x0, double x1, double y0, double y1, double z, double panel, Color a, Color b) {
    final n = math.max(1, ((x1 - x0) / panel).round());
    final m = math.max(1, ((y1 - y0) / panel).round());
    final dx = (x1 - x0) / n, dy = (y1 - y0) / m;
    for (var i = 0; i < n; i++) {
      for (var k = 0; k < m; k++) {
        final xa = x0 + i * dx, ya = y0 + k * dy;
        quad([xa, ya, z], [xa + dx, ya, z], [xa + dx, ya + dy, z], [xa, ya + dy, z], (i + k).isEven ? a : b);
      }
    }
  }

  /// Vertical wall in the z-y plane at x.
  void wallZ(double z0, double z1, double y0, double y1, double x, double panel, Color a, Color b) {
    final n = math.max(1, ((z1 - z0) / panel).round());
    final m = math.max(1, ((y1 - y0) / panel).round());
    final dz = (z1 - z0) / n, dy = (y1 - y0) / m;
    for (var i = 0; i < n; i++) {
      for (var k = 0; k < m; k++) {
        final za = z0 + i * dz, ya = y0 + k * dy;
        quad([x, ya, za], [x, ya, za + dz], [x, ya + dy, za + dz], [x, ya + dy, za], (i + k).isEven ? a : b);
      }
    }
  }

  /// Vertical cylinder (pole / column / funnel).
  void cylinder(double x, double z, double y0, double y1, double r, Color color, {int seg = 10, bool cap = true}) {
    for (var i = 0; i < seg; i++) {
      final a0 = i / seg * math.pi * 2, a1 = (i + 1) / seg * math.pi * 2;
      final x0 = x + math.cos(a0) * r, z0 = z + math.sin(a0) * r;
      final x1 = x + math.cos(a1) * r, z1 = z + math.sin(a1) * r;
      quad([x0, y0, z0], [x1, y0, z1], [x1, y1, z1], [x0, y1, z0], color);
      if (cap) tri(x, y1, z, x1, y1, z1, x0, y1, z0, color);
    }
  }

  /// Inclined strip between two points (escalator steps, handrails, ramps). Width along z.
  void ramp(double xa, double ya, double xb, double yb, double z0, double z1, Color color, {int steps = 0, Color? alt}) {
    if (steps <= 0) {
      quad([xa, ya, z0], [xb, yb, z0], [xb, yb, z1], [xa, ya, z1], color);
      return;
    }
    for (var i = 0; i < steps; i++) {
      final t0 = i / steps, t1 = (i + 1) / steps;
      final x0 = xa + (xb - xa) * t0, x1 = xa + (xb - xa) * t1;
      final y0 = ya + (yb - ya) * t0, y1 = ya + (yb - ya) * t1;
      // tread + riser
      final cc = i.isEven ? color : (alt ?? color);
      quad([x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1], cc);
      quad([x1, y0, z0], [x1, y1, z0], [x1, y1, z1], [x1, y0, z1], alt ?? color);
    }
  }

  /// Appends [other] transformed by rotation around y ([yaw] rad), then translation.
  void addTransformed(Mesh other, double tx, double ty, double tz, {double yaw = 0, double scale = 1}) {
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final op = other.p;
    for (var i = 0; i < op.length; i += 3) {
      final x = op[i] * scale, y = op[i + 1] * scale, z = op[i + 2] * scale;
      p..add(x * cy + z * sy + tx)..add(y + ty)..add(-x * sy + z * cy + tz);
    }
    c.addAll(other.c);
    f.addAll(other.f);
  }

  void addMesh(Mesh other) {
    p.addAll(other.p);
    c.addAll(other.c);
    f.addAll(other.f);
  }

  /// Bounding radius around origin (for auto-framing vehicle models).
  double get radius {
    var r = 0.0;
    for (var i = 0; i < p.length; i += 3) {
      r = math.max(r, math.sqrt(p[i] * p[i] + p[i + 1] * p[i + 1] + p[i + 2] * p[i + 2]));
    }
    return r;
  }
}

/// Frame-rate budget shared by the 3D views (set to lite when the browser renders on the CPU).
class Render3DQuality {
  static bool lite = false;

  /// Frames per second to render at: smooth while something moves, near-idle otherwise.
  static double fps({required bool active}) => lite ? (active ? 15 : 4) : (active ? 40 : 6);
}

/// A floating screen label anchored to a 3D point.
class Label3D {
  final double x, y, z;
  final String text;
  final String? sub;
  final Color color;
  final IconData? icon;
  final bool dark;
  const Label3D(this.x, this.y, this.z, this.text, {this.sub, this.color = const Color(0xFF1D4ED8), this.icon, this.dark = false});
}

class Camera3D {
  double ex, ey, ez; // eye
  double yaw; // radians, 0 = looking toward +x
  double pitch; // radians, + looks up
  double fovDeg;

  /// Vertical position of the projection centre (0 = top, 0.5 = middle). Lets a view frame its
  /// subject above a bottom sheet without moving the camera.
  double centerY;

  Camera3D({this.ex = 0, this.ey = 1.7, this.ez = 0, this.yaw = 0, this.pitch = 0, this.fovDeg = 62, this.centerY = 0.5});

  /// Orbit helper: places the eye around a target.
  void orbit(double tx, double ty, double tz, double distance, double yawRad, double pitchRad) {
    final cp = math.cos(pitchRad);
    ex = tx - math.cos(yawRad) * cp * distance;
    ez = tz - math.sin(yawRad) * cp * distance;
    ey = ty + math.sin(pitchRad) * distance;
    yaw = yawRad;
    pitch = -pitchRad;
  }

  void lookAt(double tx, double ty, double tz) {
    final dx = tx - ex, dy = ty - ey, dz = tz - ez;
    yaw = math.atan2(dz, dx);
    pitch = math.atan2(dy, math.sqrt(dx * dx + dz * dz));
  }
}

class RenderStyle {
  final Color sky;
  final Color skyBottom;
  final Color fog;
  final double fogStart, fogEnd;
  final double ambient;
  final List<double> light; // normalised direction toward light
  const RenderStyle({
    this.sky = const Color(0xFFBFD6EA),
    this.skyBottom = const Color(0xFFE8EEF3),
    this.fog = const Color(0xFFD9E3EC),
    this.fogStart = 60,
    this.fogEnd = 420,
    this.ambient = 0.62,
    this.light = const [0.35, 0.85, 0.40],
  });

  static const indoor = RenderStyle(
    sky: Color(0xFF8E959C),
    skyBottom: Color(0xFFB9BEC3),
    fog: Color(0xFFC7CCD1),
    fogStart: 35,
    fogEnd: 260,
    ambient: 0.72,
    light: [0.2, 0.95, 0.25],
  );

  static const night = RenderStyle(
    sky: Color(0xFF0B1220),
    skyBottom: Color(0xFF1B2433),
    fog: Color(0xFF111827),
    fogStart: 80,
    fogEnd: 520,
    ambient: 0.55,
    light: [0.3, 0.9, 0.3],
  );
}

/// Paints [meshes] from [camera]. Reusable buffers keep allocation per frame low.
class Renderer3D {
  static const _batch = 900;
  Float64List _keys = Float64List(0);
  Float32List _scr = Float32List(0); // per output triangle: 6 floats
  Int32List _tc = Int32List(0);
  List<int> _order = [];
  int lastTriangles = 0;

  // Native-backed objects are reused / released explicitly: on the web (skwasm) they live in WASM
  // memory that the Dart GC does not track, so per-frame garbage would pile up.
  final Map<String, TextPainter> _labelCache = {};
  ui.Shader? _sky;
  String _skyKey = '';

  void dispose() {
    for (final tp in _labelCache.values) {
      tp.dispose();
    }
    _labelCache.clear();
    _sky = null;
  }

  void paint(Canvas canvas, Size size, Camera3D cam, List<Mesh> meshes, RenderStyle style,
      {List<Label3D> labels = const [], bool drawSky = true, double labelScale = 1}) {
    final w = size.width, h = size.height;
    if (drawSky) {
      final key = '$h|${style.sky.toARGB32()}|${style.skyBottom.toARGB32()}';
      if (key != _skyKey || _sky == null) {
        _skyKey = key;
        _sky = ui.Gradient.linear(Offset.zero, Offset(0, h), [style.sky, style.skyBottom]);
      }
      canvas.drawRect(Offset.zero & size, Paint()..shader = _sky);
    }
    final cyaw = math.cos(cam.yaw), syaw = math.sin(cam.yaw);
    final cp = math.cos(cam.pitch), sp = math.sin(cam.pitch);
    // forward, right, up
    final fx = cyaw * cp, fy = sp, fz = syaw * cp;
    final rx = -syaw, ry = 0.0, rz = cyaw;
    final ux = -cyaw * sp, uy = cp, uz = -syaw * sp;
    final focal = (h / 2) / math.tan(cam.fovDeg * math.pi / 360);
    final hx = w / 2, hy = h * cam.centerY;
    const near = 0.15;
    final lx = style.light[0], ly = style.light[1], lz = style.light[2];
    final fogR = (style.fog.r * 255).round(), fogG = (style.fog.g * 255).round(), fogB = (style.fog.b * 255).round();

    var total = 0;
    for (final m in meshes) {
      total += m.triangles;
    }
    final cap = total * 2 + 8;
    if (_keys.length < cap) {
      _keys = Float64List(cap);
      _scr = Float32List(cap * 6);
      _tc = Int32List(cap);
    }
    var n = 0;
    final vx = Float64List(3), vy = Float64List(3), vz = Float64List(3);
    final clipX = Float64List(4), clipY = Float64List(4), clipZ = Float64List(4);

    for (final m in meshes) {
      final mp = m.p, mc = m.c, mf = m.f;
      for (var t = 0; t < mc.length; t++) {
        final o = t * 9;
        var behind = 0;
        for (var k = 0; k < 3; k++) {
          final px = mp[o + k * 3] - cam.ex, py = mp[o + k * 3 + 1] - cam.ey, pz = mp[o + k * 3 + 2] - cam.ez;
          vx[k] = px * rx + py * ry + pz * rz;
          vy[k] = px * ux + py * uy + pz * uz;
          vz[k] = px * fx + py * fy + pz * fz;
          if (vz[k] < near) behind++;
        }
        if (behind == 3) continue;
        // shading (world-space normal facing the camera)
        var color = mc[t];
        final a = (color >> 24) & 0xFF;
        var r = (color >> 16) & 0xFF, g = (color >> 8) & 0xFF, b = color & 0xFF;
        final avgZ = (vz[0] + vz[1] + vz[2]) / 3;
        if (mf[t] & 1 == 0) {
          final e1x = mp[o + 3] - mp[o], e1y = mp[o + 4] - mp[o + 1], e1z = mp[o + 5] - mp[o + 2];
          final e2x = mp[o + 6] - mp[o], e2y = mp[o + 7] - mp[o + 1], e2z = mp[o + 8] - mp[o + 2];
          var nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x;
          final len = math.sqrt(nx * nx + ny * ny + nz * nz);
          if (len > 0) {
            nx /= len;
            ny /= len;
            nz /= len;
          }
          // flip toward camera
          final tox = cam.ex - mp[o], toy = cam.ey - mp[o + 1], toz = cam.ez - mp[o + 2];
          if (nx * tox + ny * toy + nz * toz < 0) {
            nx = -nx;
            ny = -ny;
            nz = -nz;
          }
          final diff = math.max(0.0, nx * lx + ny * ly + nz * lz);
          final shade = style.ambient + (1 - style.ambient) * diff;
          r = (r * shade).round().clamp(0, 255);
          g = (g * shade).round().clamp(0, 255);
          b = (b * shade).round().clamp(0, 255);
        }
        if (avgZ > style.fogStart) {
          final k = ((avgZ - style.fogStart) / (style.fogEnd - style.fogStart)).clamp(0.0, 1.0);
          r = (r + (fogR - r) * k).round();
          g = (g + (fogG - g) * k).round();
          b = (b + (fogB - b) * k).round();
        }
        color = (a << 24) | (r << 16) | (g << 8) | b;

        var cnt = 3;
        var px = vx, py = vy, pz = vz;
        if (behind > 0) {
          // Sutherland–Hodgman against z = near
          cnt = 0;
          for (var k = 0; k < 3; k++) {
            final j = (k + 1) % 3;
            final inK = vz[k] >= near, inJ = vz[j] >= near;
            if (inK) {
              clipX[cnt] = vx[k];
              clipY[cnt] = vy[k];
              clipZ[cnt] = vz[k];
              cnt++;
            }
            if (inK != inJ) {
              final s = (near - vz[k]) / (vz[j] - vz[k]);
              clipX[cnt] = vx[k] + (vx[j] - vx[k]) * s;
              clipY[cnt] = vy[k] + (vy[j] - vy[k]) * s;
              clipZ[cnt] = near;
              cnt++;
            }
          }
          px = clipX;
          py = clipY;
          pz = clipZ;
        }
        // project polygon & emit fan triangles
        double sx(int k) => hx + px[k] / pz[k] * focal;
        double sy(int k) => hy - py[k] / pz[k] * focal;
        final s0x = sx(0), s0y = sy(0);
        for (var k = 1; k < cnt - 1; k++) {
          final s1x = sx(k), s1y = sy(k), s2x = sx(k + 1), s2y = sy(k + 1);
          final minX = math.min(s0x, math.min(s1x, s2x)), maxX = math.max(s0x, math.max(s1x, s2x));
          final minY = math.min(s0y, math.min(s1y, s2y)), maxY = math.max(s0y, math.max(s1y, s2y));
          if (maxX < 0 || minX > w || maxY < 0 || minY > h) continue;
          if (n >= _keys.length) break;
          final q = n * 6;
          _scr[q] = s0x;
          _scr[q + 1] = s0y;
          _scr[q + 2] = s1x;
          _scr[q + 3] = s1y;
          _scr[q + 4] = s2x;
          _scr[q + 5] = s2y;
          _tc[n] = color;
          // farthest vertex dominates: big floor quads draw before things standing on them
          _keys[n] = math.max(avgZ, (pz[0] + pz[k] + pz[k + 1]) / 3) * 0.7 +
              math.max(pz[0], math.max(pz[k], pz[k + 1])) * 0.3;
          n++;
        }
      }
    }
    lastTriangles = n;
    if (_order.length != n) _order = List<int>.generate(n, (i) => i);
    for (var i = 0; i < n; i++) {
      _order[i] = i;
    }
    final keys = _keys;
    _order.sort((a, b) => keys[b].compareTo(keys[a]));
    // Back-to-front batches of at most [_batch] triangles: skwasm (Flutter web/WASM) corrupts its heap
    // on a single drawVertices call with a few thousand triangles; batches keep painter's order.
    for (var b0 = 0; b0 < n; b0 += _batch) {
      final b1 = math.min(n, b0 + _batch);
      final cnt = b1 - b0;
      final pos = Float32List(cnt * 6);
      final col = Int32List(cnt * 3);
      for (var i = 0; i < cnt; i++) {
        final src = _order[b0 + i] * 6, dst = i * 6;
        for (var k = 0; k < 6; k++) {
          pos[dst + k] = _scr[src + k];
        }
        final c = _tc[_order[b0 + i]];
        col[i * 3] = c;
        col[i * 3 + 1] = c;
        col[i * 3 + 2] = c;
      }
      final verts = ui.Vertices.raw(ui.VertexMode.triangles, pos, colors: col);
      canvas.drawVertices(verts, BlendMode.dst, Paint());
      verts.dispose();
    }

    // labels
    for (final l in labels) {
      final px0 = l.x - cam.ex, py0 = l.y - cam.ey, pz0 = l.z - cam.ez;
      final zz = px0 * fx + py0 * fy + pz0 * fz;
      if (zz < 1) continue;
      final xx = px0 * rx + py0 * ry + pz0 * rz, yy = px0 * ux + py0 * uy + pz0 * uz;
      final sx = hx + xx / zz * focal, sy = hy - yy / zz * focal;
      if (sx < -80 || sx > w + 80 || sy < -40 || sy > h + 40) continue;
      _drawLabel(canvas, Offset(sx, sy), l, labelScale);
    }
  }

  void _drawLabel(Canvas canvas, Offset at, Label3D l, double scale) {
    final bg = l.dark ? const Color(0xF01E293B) : const Color(0xF7FFFFFF);
    final fg = l.dark ? Colors.white : l.color;
    final key = '${l.text}|${l.sub}|${l.dark}|$scale|${l.color.toARGB32()}|${l.icon?.codePoint}';
    if (_labelCache.length > 96 && !_labelCache.containsKey(key)) dispose();
    final tp = _labelCache.putIfAbsent(key, () => TextPainter(
      text: TextSpan(children: [
        if (l.icon != null)
          TextSpan(
              text: String.fromCharCode(l.icon!.codePoint),
              style: TextStyle(fontFamily: l.icon!.fontFamily, package: l.icon!.fontPackage, fontSize: 13 * scale, color: fg)),
        TextSpan(text: l.icon != null ? ' ${l.text}' : l.text, style: TextStyle(color: fg, fontSize: 12.5 * scale, fontWeight: FontWeight.w800)),
        if (l.sub != null)
          TextSpan(
              text: '  ${l.sub}',
              style: TextStyle(color: l.dark ? Colors.white70 : const Color(0xFF475569), fontSize: 11 * scale, fontWeight: FontWeight.w600)),
      ]),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 260));
    final pad = EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 5 * scale);
    final rect = Rect.fromCenter(center: at, width: tp.width + pad.horizontal, height: tp.height + pad.vertical);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));
    canvas.drawRRect(rr.shift(const Offset(0, 1.5)), Paint()..color = const Color(0x33000000));
    canvas.drawRRect(rr, Paint()..color = bg);
    if (!l.dark) {
      canvas.drawRRect(rr, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = l.color.withValues(alpha: 0.55));
    }
    tp.paint(canvas, Offset(rect.left + pad.left, rect.top + pad.top));
  }
}

/// CustomPainter wrapper.
class ScenePainter extends CustomPainter {
  final Renderer3D renderer;
  final Camera3D camera;
  final List<Mesh> meshes;
  final RenderStyle style;
  final List<Label3D> labels;
  final int frame;
  final bool drawSky;

  ScenePainter({
    required this.renderer,
    required this.camera,
    required this.meshes,
    required this.style,
    this.labels = const [],
    required this.frame,
    this.drawSky = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    renderer.paint(canvas, size, camera, meshes, style, labels: labels, drawSky: drawSky);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ScenePainter old) => old.frame != frame || old.meshes != meshes;
}
