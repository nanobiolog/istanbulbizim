/// Timetable-derived rail schedules (Metro İstanbul official timetables, Marmaray plan).
///
/// Wire format matches the Worker's `/rail/schedule` response: per direction a list of
/// cumulative running [offsets] (seconds, indexed by travel position) and [trips] as
/// `[departureSec, fromPos, toPos]`, where seconds count from the service day's midnight
/// (values above 86400 are after midnight, before the 03:00 rollover).
class RailStation {
  final String name;
  final double lat;
  final double lon;

  const RailStation({required this.name, required this.lat, required this.lon});

  factory RailStation.fromJson(Map<String, dynamic> j) => RailStation(
        name: j['name']?.toString() ?? '',
        lat: (j['lat'] as num?)?.toDouble() ?? 0,
        lon: (j['lon'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {'name': name, 'lat': lat, 'lon': lon};
}

class RailTrip {
  final int dep;
  final int from;
  final int to;

  const RailTrip(this.dep, this.from, this.to);

  List<int> toJson() => [dep, from, to];
}

class RailDirection {
  final String dir; // 'G' (station index increasing) | 'D' (decreasing)
  final bool forward;
  final String name;
  final String headsign;
  final List<int> offsets;
  final int timetablePoints;
  final List<RailTrip> trips;

  const RailDirection({
    required this.dir,
    required this.forward,
    required this.name,
    required this.headsign,
    required this.offsets,
    required this.trips,
    this.timetablePoints = 0,
  });

  factory RailDirection.fromJson(Map<String, dynamic> j) {
    final trips = <RailTrip>[];
    for (final t in (j['trips'] as List? ?? const [])) {
      if (t is List && t.length >= 3) {
        trips.add(RailTrip((t[0] as num).toInt(), (t[1] as num).toInt(), (t[2] as num).toInt()));
      } else if (t is List && t.isNotEmpty) {
        final n = (j['offsets'] as List?)?.length ?? 0;
        trips.add(RailTrip((t[0] as num).toInt(), 0, n - 1));
      }
    }
    return RailDirection(
      dir: j['dir']?.toString() ?? 'G',
      forward: (j['sense']?.toString() ?? 'fwd') == 'fwd',
      name: j['name']?.toString() ?? '',
      headsign: j['headsign']?.toString() ?? '',
      offsets: (j['offsets'] as List? ?? const []).map((e) => (e as num).toInt()).toList(),
      timetablePoints: (j['timetable_points'] as num?)?.toInt() ?? 0,
      trips: trips,
    );
  }

  Map<String, dynamic> toJson() => {
        'dir': dir,
        'sense': forward ? 'fwd' : 'rev',
        'name': name,
        'headsign': headsign,
        'offsets': offsets,
        'timetable_points': timetablePoints,
        'trips': trips.map((t) => t.toJson()).toList(),
      };

  /// Travel position of station index [i] in this direction.
  int posOf(int i, int n) => forward ? i : n - 1 - i;

  /// Station index of travel position [p].
  int indexOf(int p, int n) => forward ? p : n - 1 - p;
}

class RailStatusItem {
  final String line;
  final String message;
  final String updated;

  const RailStatusItem({required this.line, required this.message, this.updated = ''});

  factory RailStatusItem.fromJson(Map<String, dynamic> j) => RailStatusItem(
        line: j['line']?.toString() ?? '',
        message: j['message']?.toString() ?? '',
        updated: j['updated']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {'line': line, 'message': message, 'updated': updated};
}

class RailSchedule {
  final String line;
  final String serviceDate;
  final String dayType;
  final bool official;
  final String source;
  final String note;
  final int dwellSec;
  final List<RailStation> stations;
  final List<RailDirection> directions;
  final List<RailStatusItem> status;

  const RailSchedule({
    required this.line,
    required this.serviceDate,
    required this.dayType,
    required this.official,
    required this.source,
    required this.stations,
    required this.directions,
    this.note = '',
    this.dwellSec = 25,
    this.status = const [],
  });

  /// Estimated schedules (frequency model / Marmaray plan) are never labelled official.
  bool get isEstimated => !official;

  factory RailSchedule.fromJson(Map<String, dynamic> j) => RailSchedule(
        line: j['line']?.toString() ?? '',
        serviceDate: j['service_date']?.toString() ?? '',
        dayType: j['day_type']?.toString() ?? 'I',
        official: j['official'] == true,
        source: j['source']?.toString() ?? '',
        note: j['note']?.toString() ?? '',
        dwellSec: (j['dwell_s'] as num?)?.toInt() ?? 25,
        stations: (j['stations'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => RailStation.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        directions: (j['directions'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => RailDirection.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        status: (j['status'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => RailStatusItem.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'v': 1,
        'line': line,
        'service_date': serviceDate,
        'day_type': dayType,
        'official': official,
        'source': source,
        'note': note,
        'dwell_s': dwellSec,
        'stations': stations.map((s) => s.toJson()).toList(),
        'directions': directions.map((d) => d.toJson()).toList(),
        'status': status.map((s) => s.toJson()).toList(),
      };

  RailSchedule withStatus(List<RailStatusItem> s) => RailSchedule(
        line: line,
        serviceDate: serviceDate,
        dayType: dayType,
        official: official,
        source: source,
        note: note,
        dwellSec: dwellSec,
        stations: stations,
        directions: directions,
        status: s,
      );
}

/// One upcoming call of a train at a station.
class RailStopCall {
  final int stationIndex;
  final String name;
  final DateTime at;

  const RailStopCall(this.stationIndex, this.name, this.at);
}

/// One scheduled departure from a station (station view / AR boards).
class RailDeparture {
  final String line;
  final String dir;
  final String headsign;
  final DateTime at;
  final bool official;

  const RailDeparture({
    required this.line,
    required this.dir,
    required this.headsign,
    required this.at,
    required this.official,
  });
}
