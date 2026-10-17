import 'dart:math' as math;

/// Magnetic declination for Istanbul (≈ +6° E, WMM 2025); true north = magnetic + declination.
const double istanbulDeclinationDeg = 6.0;

/// Tilt-compensated heading of the *back camera* (device −Z axis) from accelerometer + magnetometer,
/// using Android's sensor frame (x right, y top, z out of the screen; gravity reads +9.81 on z when
/// the phone lies face up — sensors_plus normalises iOS to the same convention).
///
/// Works with the phone held upright (AR) or flat (compass): when the camera looks steeply up or
/// down its horizontal direction is undefined, so the top edge of the device is used instead.
/// iOS reports the raw magnetometer (with the phone's own hard-iron bias), so [calibrateHardIron]
/// learns that bias from the field's min/max while the user moves the phone, and [applyCourse]
/// slowly aligns the result with the GPS course while walking.
class HeadingEstimator {
  final bool calibrateHardIron;
  final double declination;
  final double smoothing; // 0..1, weight of each new sample

  HeadingEstimator({this.calibrateHardIron = false, this.declination = istanbulDeclinationDeg, this.smoothing = 0.18});

  List<double>? _g;
  List<double>? _m;
  final List<double> _min = [double.infinity, double.infinity, double.infinity];
  final List<double> _max = [double.negativeInfinity, double.negativeInfinity, double.negativeInfinity];
  double? _heading;
  double _pitch = 0;
  double _courseBias = 0;
  double _jitter = 0;

  /// True heading of the camera direction, degrees clockwise from north (null until both sensors report).
  double? get heading => _heading == null ? null : _wrap(_heading! + _courseBias);

  /// Elevation of the camera axis above the horizon in degrees (0 = level, +90 = straight up).
  double get pitch => _pitch;

  /// Rough per-sample heading noise (deg); large values mean magnetic interference / no calibration.
  double get jitter => _jitter;

  bool get hardIronReady {
    if (!calibrateHardIron) return true;
    for (var i = 0; i < 3; i++) {
      // ≳ ±20 µT swing on every axis (Istanbul's horizontal field is only ~25 µT).
      if (!(_max[i] - _min[i] > 40)) return false;
    }
    return true;
  }

  void addAccelerometer(double x, double y, double z) {
    _g = _lowPass(_g, [x, y, z]);
    _recompute();
  }

  void addMagnetometer(double x, double y, double z) {
    if (calibrateHardIron) {
      final v = [x, y, z];
      for (var i = 0; i < 3; i++) {
        _min[i] = math.min(_min[i], v[i]);
        _max[i] = math.max(_max[i], v[i]);
      }
      if (hardIronReady) {
        x -= (_min[0] + _max[0]) / 2;
        y -= (_min[1] + _max[1]) / 2;
        z -= (_min[2] + _max[2]) / 2;
      }
    }
    _m = _lowPass(_m, [x, y, z]);
    _recompute();
  }

  /// Nudges the heading toward the GPS course when the user is clearly walking forward.
  void applyCourse(double courseDeg, double speedMs) {
    final h = heading;
    if (h == null || speedMs < 0.9 || _pitch.abs() > 40) return;
    final err = _signedDiff(courseDeg, h);
    if (err.abs() > 60) return; // probably looking sideways, not walking direction
    _courseBias = _signedDiff(_wrap(_courseBias + err * 0.05), 0);
  }

  List<double> _lowPass(List<double>? prev, List<double> v) {
    if (prev == null) return v;
    const a = 0.25;
    return [prev[0] + a * (v[0] - prev[0]), prev[1] + a * (v[1] - prev[1]), prev[2] + a * (v[2] - prev[2])];
  }

  void _recompute() {
    final g = _g, m = _m;
    if (g == null || m == null) return;
    final r = cameraHeadingPitch(g, m);
    if (r == null) return;
    _pitch = r.pitch;
    final raw = _wrap(r.heading + declination);
    if (_heading == null) {
      _heading = raw;
      return;
    }
    final d = _signedDiff(raw, _heading!);
    _jitter = _jitter * 0.9 + d.abs() * 0.1;
    _heading = _wrap(_heading! + d * smoothing);
  }

  /// Magnetic heading (deg) of the camera axis and its pitch, or null for degenerate input.
  static ({double heading, double pitch})? cameraHeadingPitch(List<double> g, List<double> m) {
    // East = m × g, North = g × East (SensorManager.getRotationMatrix).
    var hx = m[1] * g[2] - m[2] * g[1];
    var hy = m[2] * g[0] - m[0] * g[2];
    var hz = m[0] * g[1] - m[1] * g[0];
    final hn = math.sqrt(hx * hx + hy * hy + hz * hz);
    final gn = math.sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
    if (hn < 0.1 || gn < 0.1) return null; // free fall or field parallel to gravity
    hx /= hn;
    hy /= hn;
    hz /= hn;
    final ax = g[0] / gn, ay = g[1] / gn, az = g[2] / gn;
    final my = az * hx - ax * hz;
    final mz = ax * hy - ay * hx;
    final pitch = math.asin((-az).clamp(-1.0, 1.0)) * 180 / math.pi;
    double heading;
    if (pitch.abs() < 60) {
      heading = math.atan2(-hz, -mz) * 180 / math.pi; // camera (−Z) direction
    } else {
      heading = math.atan2(hy, my) * 180 / math.pi; // flat: top of the device
    }
    return (heading: _wrap(heading), pitch: pitch);
  }

  static double _wrap(double d) => (d % 360 + 360) % 360;
  static double _signedDiff(double a, double b) => ((a - b + 540) % 360) - 180;
}

/// Screen placement for a world bearing in a portrait camera view.
class ArProjection {
  final double hFovDeg;
  final double vFovDeg;

  const ArProjection({this.hFovDeg = 54, this.vFovDeg = 70});

  /// Horizontal screen x (px) of [bearing] seen with camera [heading]; null when behind/outside.
  double? x(double bearing, double heading, double width) {
    final rel = ((bearing - heading + 540) % 360) - 180;
    if (rel.abs() > hFovDeg / 2 + 8) return null;
    final t = math.tan(rel * math.pi / 180) / math.tan(hFovDeg / 2 * math.pi / 180);
    return width / 2 + t * width / 2;
  }

  /// Screen y of the horizon for camera [pitch] (camera tilted up moves the horizon down).
  double horizonY(double pitch, double height) {
    final p = pitch.clamp(-80.0, 80.0);
    final t = math.tan(p * math.pi / 180) / math.tan(vFovDeg / 2 * math.pi / 180);
    return height / 2 + t * height / 2;
  }

  /// Signed angle (deg) from the camera heading to [bearing]: negative = turn left.
  static double relative(double bearing, double heading) => ((bearing - heading + 540) % 360) - 180;
}
