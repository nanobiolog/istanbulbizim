/// Clock for everything driven by timetables (trains, ferries, countdowns).
/// `?saat=08:30` on the website pins the schedule clock to that time of day (demos, planning).
class AppClock {
  static Duration offset = Duration.zero;

  static DateTime now() => DateTime.now().add(offset);

  /// Parses "HH:MM" and shifts the schedule clock so that it is that time now.
  static void pinTimeOfDay(String? hhmm) {
    if (hhmm == null) return;
    final m = RegExp(r'^(\d{1,2})[:.](\d{2})$').firstMatch(hhmm.trim());
    if (m == null) return;
    final n = DateTime.now();
    final target = DateTime(n.year, n.month, n.day, int.parse(m.group(1)!) % 24, int.parse(m.group(2)!));
    offset = target.difference(n);
  }
}
