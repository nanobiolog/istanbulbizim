/// Clock for everything driven by timetables (trains, ferries, countdowns).
///
/// Always Istanbul wall-clock time (UTC+3, no DST since 2016) regardless of the device's timezone,
/// returned as a plain DateTime whose fields are Istanbul's date and time.
/// `?saat=08:30` on the website pins the schedule clock to that time of day (demos, planning).
class AppClock {
  static Duration offset = Duration.zero;
  static const istanbul = Duration(hours: 3);

  static DateTime istanbulNow() {
    final u = DateTime.now().toUtc().add(istanbul);
    return DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second, u.millisecond);
  }

  static DateTime now() => istanbulNow().add(offset);

  /// Parses "HH:MM" and shifts the schedule clock so that it is that time in Istanbul now.
  static void pinTimeOfDay(String? hhmm) {
    if (hhmm == null) return;
    final m = RegExp(r'^(\d{1,2})[:.](\d{2})$').firstMatch(hhmm.trim());
    if (m == null) return;
    final n = istanbulNow();
    final target = DateTime(n.year, n.month, n.day, int.parse(m.group(1)!) % 24, int.parse(m.group(2)!));
    offset = target.difference(n);
  }
}
