#!/usr/bin/env python3
"""
build_transit_data.py - Builds the offline transit network bundled with the app (and the WASM website).

  rail     Rail lines with real track geometry + stations, from OpenStreetMap route relations
           (OSM main API, /relation/<id>/full). Headways from the İBB GTFS feed.
  plans    Station "plans": entrances, elevators, escalators, platforms and level/depth hints
           (Overpass API), merged into the rail stations. Also under-construction rail projects.
  ferries  İBB Şehir Hatları + private operators (Turyol, Dentur Avrasya, İDO ...):
           piers + sea-following routes (İBB open data GeoJSON), current Şehir Hatları timetables
           (sehirhatlari.istanbul tables), private operator timetables (İBB GTFS).
  media    Vehicle photos (Wikimedia Commons, with author + licence for attribution).

Usage:
  python3 -I tools/build_transit_data.py all [--cache tools/.cache] [--offline]

Outputs (both copies are identical):
  mobile_app/assets/data/rail_network.json
  mobile_app/assets/data/ferry_network.json
  mobile_app/assets/data/vehicle_media.json

Everything fetched is treated as data: parsed as JSON/CSV/HTML text only.
"""

import argparse
import collections
import csv
import datetime as dt
import html
import io
import json
import math
import os
import re
import ssl
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(BASE_DIR, "mobile_app", "assets", "data")
UA = "IstanbulBizim/2.0 (+https://github.com/nanobiolog/istanbulbizim; transit data build)"
BBOX = (40.75, 28.40, 41.30, 29.50)  # s, w, n, e  (Istanbul; excludes Kocaeli trams)

try:  # python.org builds on macOS ship without a CA bundle
    import certifi
    SSL_CTX = ssl.create_default_context(cafile=certifi.where())
except ImportError:
    SSL_CTX = ssl.create_default_context()

OVERPASS = [
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]

# ───────────────────────── rail line catalogue ─────────────────────────
# code: (mode, colour, display name, [relation ids...])  first relation = main drawing direction.
RAIL_LINES = {
    "B1":  ("suburban", "#2E5AAC", "Marmaray", [9987139, 9468040, 4289742, 4511012]),
    "B2":  ("suburban", "#77787C", "Halkalı – Bahçeşehir", [14039181, 16822093]),
    "M1A": ("metro", "#EE3124", "Yenikapı – Atatürk Havalimanı", [305496, 7719077]),
    "M1B": ("metro", "#EE3124", "Yenikapı – Kirazlı", [4289712, 7719075]),
    "M2":  ("metro", "#009944", "Yenikapı – Hacıosman", [11341406, 7719074, 7719795, 7719796]),
    "M3":  ("metro", "#00A8E1", "Bakırköy Sahil – Kayaşehir Merkez", [4289797, 7719073]),
    "M4":  ("metro", "#E91E76", "Kadıköy – Sabiha Gökçen Havalimanı", [2396287, 11341395]),
    "M5":  ("metro", "#683064", "Üsküdar – Sultanbeyli", [11344904, 11344905]),
    "M6":  ("metro", "#CAA977", "Levent – Boğaziçi Ü./Hisarüstü", [7719781, 7719780]),
    "M7":  ("metro", "#F89ABA", "Yıldız – Mahmutbey", [11799409, 11799410, 15085833, 15085834]),
    "M8":  ("metro", "#447ABE", "Bostancı – Parseller", [14900216, 14900217]),
    "M9":  ("metro", "#F0E514", "Ataköy – Olimpiyat", [4289800, 7719072]),
    "M11": ("metro", "#A1609B", "Gayrettepe – İstanbul Havalimanı – Halkalı", [15083964, 15083963]),
    "T1":  ("tram", "#004F7D", "Kabataş – Bağcılar", [151819, 2962729]),
    "T2":  ("tram", "#92AAA0", "Taksim – Tünel (Nostaljik)", [301617, 4488483]),
    "T3":  ("tram", "#A86528", "Kadıköy – Moda (Nostaljik)", [2409338]),
    "T4":  ("tram", "#F47E46", "Topkapı – Mescid-i Selam", [7420265, 7420264, 11344897, 11344896]),
    "T5":  ("tram", "#7C72B3", "Eminönü – Alibeyköy Cep Otogarı", [12174616, 12174615]),
    "T6":  ("tram", "#E47A7B", "Kazlıçeşme – Sirkeci", [16400029, 19587363]),
    "F1":  ("funicular", "#7C7358", "Taksim – Kabataş Füniküler", [300961, 13313678]),
    "F2":  ("funicular", "#7C7358", "Karaköy – Beyoğlu (Tünel)", [301616, 13313679]),
    "F3":  ("funicular", "#7C7358", "Seyrantepe – Vadistanbul", [9476599, 9488735]),
    "F4":  ("funicular", "#7C7358", "Boğaziçi Ü./Hisarüstü – Aşiyan", [14738978, 14738977]),
    "TF1": ("cable", "#68BCB0", "Maçka – Taşkışla Teleferik", [9696513]),
    "TF2": ("cable", "#68BCB0", "Eyüp – Piyer Loti Teleferik", [20170893]),
}

# Planned speeds (km/h, cruise) and dwell (s) per mode used by the schedule engine.
MODE_DEFAULTS = {
    "suburban": (80, 45), "metro": (70, 30), "tram": (30, 25), "funicular": (25, 40), "cable": (18, 60),
}

# GTFS route_short_name per line (İBB feed) for headways; missing -> fallback headways.
GTFS_LINE = {
    "B1": "Marmaray", "M1A": "M1A", "M1B": "M1B", "M2": "M2", "M3": "M3", "M4": "M4", "M5": "M5",
    "M6": "M6", "M7": "M7", "M8": "M8", "M9": "M9", "T1": "T1", "T3": "T3", "T4": "T4",
    "F1": "F1", "F2": "F2", "F3": "F3", "TF1": "TF1", "TF2": "TF2", "B2": "Marmaray2",
}
FALLBACK_HEADWAY = {
    "suburban": [(360, 1440, 900)], "metro": [(360, 1440, 420)], "tram": [(360, 1440, 360)],
    "funicular": [(420, 1440, 300)], "cable": [(480, 1380, 300)],
}

# Station depths (platform level below street, m). Only well-documented values; others are estimated.
KNOWN_DEPTH = {
    ("B1", "sirkeci"): 60, ("B1", "uskudar"): 30, ("B1", "yenikapi"): 24, ("B1", "ayrilik cesmesi"): 28,
    ("M2", "sishane"): 60, ("M2", "taksim"): 30, ("M5", "uskudar"): 40, ("M4", "kadikoy"): 30,
}

# Under-construction / planned lines (Wikipedia: Istanbul Metro) used to label OSM construction ways.
PROJECTS = {
    "M10": ("#4CAA3C", "Pendik – Sabiha Gökçen Havalimanı"),
    "M12": ("#CAD300", "60. Yıl Parkı – Kazım Karabekir"),
    "M13": ("#FF4B58", "Emek – Yenidoğan"),
    "M14": ("#B16400", "Altunizade – Bosna Bulvarı"),
}


# ───────────────────────── helpers ─────────────────────────

def http_get(url, cache_path=None, data=None, timeout=120, retries=3, accept_status=(200,)):
    if cache_path and os.path.exists(cache_path) and os.path.getsize(cache_path) > 0:
        with open(cache_path, "rb") as f:
            return f.read()
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, data=data, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as r:
                body = r.read()
                if r.status in accept_status:
                    if cache_path:
                        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
                        with open(cache_path, "wb") as f:
                            f.write(body)
                    return body
                last = "HTTP %s" % r.status
        except Exception as e:  # noqa: BLE001 - network flakiness is expected
            last = str(e)
        time.sleep(2 + attempt * 3)
    raise RuntimeError("GET failed %s: %s" % (url, last))


def overpass(query, cache_path, attempts=10, optional=False):
    if os.path.exists(cache_path) and os.path.getsize(cache_path) > 0:
        with open(cache_path, "r", encoding="utf-8") as f:
            return json.load(f)
    body = urllib.parse.urlencode({"data": query}).encode()
    for attempt in range(attempts):
        for ep in OVERPASS:
            try:
                req = urllib.request.Request(ep, data=body, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=180, context=SSL_CTX) as r:
                    raw = r.read()
                parsed = json.loads(raw)
                if "elements" in parsed:
                    os.makedirs(os.path.dirname(cache_path), exist_ok=True)
                    with open(cache_path, "wb") as f:
                        f.write(raw)
                    return parsed
            except Exception as e:  # noqa: BLE001
                print("   overpass %s: %s" % (ep.split("/")[2], str(e)[:80]))
        time.sleep(10 + attempt * 5)
    if optional:
        print("   (skipped: Overpass unavailable for %s)" % os.path.basename(cache_path))
        return {"elements": []}
    raise RuntimeError("Overpass failed for %s" % cache_path)


def fold(s):
    """Lowercase ASCII fold for Turkish names (Yenikapı -> yenikapi)."""
    s = (s or "").replace("İ", "i").replace("I", "ı").lower()
    s = s.replace("ı", "i").replace("ğ", "g").replace("ü", "u").replace("ş", "s").replace("ö", "o").replace("ç", "c")
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"\(.*?\)", " ", s)
    s = re.sub(r"\b(metro|istasyonu|istasyon|marmaray|tramvay|station|peron|duragi|sh|ido|turyol|dentur|iskelesi|iskele)\b", " ", s)
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def hav(a, b):
    R = 6371000.0
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    d = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(d))


def to_xy(p, lat0):
    return (math.radians(p[1]) * 6371000.0 * math.cos(math.radians(lat0)), math.radians(p[0]) * 6371000.0)


def simplify(points, tol_m=3.0):
    """Douglas-Peucker in local metres."""
    if len(points) < 3:
        return points
    lat0 = points[0][0]
    xy = [to_xy(p, lat0) for p in points]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        ax, ay = xy[i]
        bx, by = xy[j]
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        best, bi = -1.0, -1
        for k in range(i + 1, j):
            px, py = xy[k]
            if L2 == 0:
                d = math.hypot(px - ax, py - ay)
            else:
                t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L2))
                d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if d > best:
                best, bi = d, k
        if best > tol_m:
            keep[bi] = True
            stack.append((i, bi))
            stack.append((bi, j))
    return [p for p, k in zip(points, keep) if k]


def encode_polyline(points):
    """Google encoded polyline, precision 5."""
    out = []
    plat = plon = 0
    for lat, lon in points:
        ilat, ilon = int(round(lat * 1e5)), int(round(lon * 1e5))
        for v in (ilat - plat, ilon - plon):
            v = ~(v << 1) if v < 0 else (v << 1)
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        plat, plon = ilat, ilon
    return "".join(out)


def _decode(enc):
    out, i, lat, lon = [], 0, 0, 0
    while i < len(enc):
        vals = []
        for _ in range(2):
            shift = result = 0
            while True:
                b = ord(enc[i]) - 63
                i += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            vals.append(~(result >> 1) if result & 1 else result >> 1)
        lat += vals[0]
        lon += vals[1]
        out.append((lat / 1e5, lon / 1e5))
    return out


def cumulative(points):
    acc = [0.0]
    for i in range(1, len(points)):
        acc.append(acc[-1] + hav(points[i - 1], points[i]))
    return acc


def project_on_path(path, cum, p, lo=0):
    """Distance along path (m) of the closest point to p, searching forward from index lo."""
    best, best_s, best_i = 1e18, 0.0, lo
    lat0 = p[0]
    px, py = to_xy(p, lat0)
    for i in range(lo, len(path) - 1):
        ax, ay = to_xy(path[i], lat0)
        bx, by = to_xy(path[i + 1], lat0)
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        t = 0 if L2 == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L2))
        d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
        if d < best:
            best, best_i = d, i
            best_s = cum[i] + t * (cum[i + 1] - cum[i])
    return best_s, best, best_i


def clean_station_name(n):
    n = re.sub(r"\s*(Teleferik İstasyonu|İstasyonu|Teleferik Station|Station)\s*$", "", n.strip())
    return n.replace("Pierre Loti", "Piyer Loti")


def chain_ways(ways):
    """Joins ordered member ways into one continuous polyline, flipping ways as needed."""
    path = []
    for w in ways:
        if not w:
            continue
        if not path:
            path = list(w)
            continue
        end = path[-1]
        d_fwd, d_rev = hav(end, w[0]), hav(end, w[-1])
        if len(path) == len(ways[0]) and len(path) > 1:
            # first way might itself be reversed: pick the orientation that connects best
            d_first_rev = min(hav(path[0], w[0]), hav(path[0], w[-1]))
            if d_first_rev < min(d_fwd, d_rev):
                path.reverse()
                end = path[-1]
                d_fwd, d_rev = hav(end, w[0]), hav(end, w[-1])
        seg = w if d_fwd <= d_rev else list(reversed(w))
        if hav(path[-1], seg[0]) < 1.0:
            seg = seg[1:]
        path.extend(seg)
    return path


# ───────────────────────── GTFS ─────────────────────────

def read_gtfs(gtfs_dir, name):
    with open(os.path.join(gtfs_dir, name), encoding="cp1254", newline="") as f:
        return list(csv.DictReader(f))


def hms_to_min(s):
    h, m, *_ = (s or "0:0").split(":")
    return int(h) * 60 + int(m)


def gtfs_headways(gtfs_dir):
    """route_short_name -> [(start_min, end_min, headway_s)] for a weekday."""
    routes = {r["route_id"]: r for r in read_gtfs(gtfs_dir, "routes.txt")}
    trips = read_gtfs(gtfs_dir, "trips.txt")
    cal = {c["service_id"]: c for c in read_gtfs(gtfs_dir, "calendar.txt")}
    rail_trip = {}
    for t in trips:
        r = routes.get(t["route_id"])
        if r and r["agency_id"] in ("4", "11"):
            rail_trip[t["trip_id"]] = (r["route_short_name"], t["service_id"], t.get("direction_id", "0"))
    # frequency-based lines
    freq = collections.defaultdict(list)
    for f in read_gtfs(gtfs_dir, "frequencies.txt"):
        info = rail_trip.get(f["trip_id"])
        if not info:
            continue
        c = cal.get(info[1], {})
        if c.get("wednesday") != "1":
            continue
        freq[info[0]].append((hms_to_min(f["start_time"]), hms_to_min(f["end_time"]), int(f["headway_secs"]), info[2]))
    # timetable-based lines: departures at first stop per direction
    first_dep = collections.defaultdict(list)
    wanted = {tid for tid, (ln, sid, d) in rail_trip.items() if cal.get(sid, {}).get("wednesday") == "1"}
    best = {}
    with open(os.path.join(gtfs_dir, "stop_times.txt"), encoding="cp1254", newline="") as f:
        for r in csv.DictReader(f):
            tid = r["trip_id"]
            if tid not in wanted:
                continue
            seq = int(r["stop_sequence"])
            if tid not in best or seq < best[tid][0]:
                best[tid] = (seq, hms_to_min(r["departure_time"]))
    for tid, (seq, m) in best.items():
        ln, sid, d = rail_trip[tid]
        first_dep[(ln, d)].append(m)
    out = {}
    for ln in set(k[0] for k in first_dep) | set(freq):
        if ln in freq and not first_dep.get((ln, "0")):
            rows = sorted({(a, b, h) for a, b, h, d in freq[ln] if d == "0"} or {(a, b, h) for a, b, h, d in freq[ln]})
            out[ln] = [list(r) for r in rows]
            continue
        deps = sorted(first_dep.get((ln, "0")) or first_dep.get((ln, "1")) or [])
        if len(deps) < 4:
            if ln in freq:
                out[ln] = [list(r) for r in sorted({(a, b, h) for a, b, h, d in freq[ln]})]
            continue
        # compress into hourly headway bands
        bands = []
        for hour in range(5, 25):
            hs = [b - a for a, b in zip(deps, deps[1:]) if hour * 60 <= a < (hour + 1) * 60 and 0 < b - a < 60]
            if hs:
                hs.sort()
                med = hs[len(hs) // 2]
                bands.append([hour * 60, (hour + 1) * 60, med * 60])
        if bands:
            bands[0][0] = deps[0]
            bands[-1][1] = max(bands[-1][1], deps[-1] + 1)
            merged = [bands[0]]
            for b in bands[1:]:
                if b[2] == merged[-1][2] and b[0] == merged[-1][1]:
                    merged[-1][1] = b[1]
                else:
                    merged.append(b)
            out[ln] = merged
    return out


# ───────────────────────── rail ─────────────────────────

def build_rail(cache, gtfs_dir):
    print("[rail] fetching %d lines from OSM" % len(RAIL_LINES))
    headways = gtfs_headways(gtfs_dir) if gtfs_dir else {}
    lines_out = []
    stations = {}  # sid -> dict
    by_fold = collections.defaultdict(list)  # folded name -> [sid]

    def station_for(name, lat, lon, code):
        key = fold(name)
        for sid in by_fold.get(key, []):
            s = stations[sid]
            if hav((s["lat"], s["lon"]), (lat, lon)) < 650:
                if code not in s["lines"]:
                    s["lines"].append(code)
                s["_pts"].append((lat, lon))
                return sid
        sid = "s%d" % (len(stations) + 1)
        stations[sid] = {"name": name, "lat": lat, "lon": lon, "lines": [code], "_pts": [(lat, lon)], "_osm": []}
        by_fold[key].append(sid)
        return sid

    for code, (mode, colour, long_name, rel_ids) in RAIL_LINES.items():
        variants = []
        for rid in rel_ids:
            raw = http_get("https://api.openstreetmap.org/api/0.6/relation/%d/full.json" % rid,
                           os.path.join(cache, "osm_rel", "%d.json" % rid))
            data = json.loads(raw)
            nodes = {e["id"]: e for e in data["elements"] if e["type"] == "node"}
            ways = {e["id"]: e for e in data["elements"] if e["type"] == "way"}
            rel = next(e for e in data["elements"] if e["type"] == "relation" and e["id"] == rid)
            tags = rel.get("tags", {})
            member_ways = []
            stops = []
            node_way_tags = {}
            for m in rel["members"]:
                if m["type"] == "way" and m["role"] in ("", "forward", "backward") and m["ref"] in ways:
                    w = ways[m["ref"]]
                    for nid in w["nodes"]:
                        node_way_tags.setdefault(nid, w.get("tags", {}))
                    pts = [(nodes[n]["lat"], nodes[n]["lon"]) for n in w["nodes"] if n in nodes]
                    if m["role"] == "backward":
                        pts.reverse()
                    member_ways.append(pts)
                elif m["type"] == "node" and m["role"].startswith("stop") and m["ref"] in nodes:
                    n = nodes[m["ref"]]
                    nm = n.get("tags", {}).get("name") or n.get("tags", {}).get("name:tr")
                    if nm:
                        stops.append((nm, n["lat"], n["lon"], n.get("tags", {}), m["ref"]))
            path = chain_ways(member_ways)
            if len(stops) < 2:
                # some relations only tag stations/platforms, or nothing: use from/to on the path ends
                for m in rel["members"]:
                    if m["type"] == "node" and m["ref"] in nodes and m["role"] in ("station", "platform", "stop_area", ""):
                        n = nodes[m["ref"]]
                        nm = n.get("tags", {}).get("name")
                        if nm and n.get("tags", {}).get("railway") in ("station", "halt", "stop", "platform") or \
                                n.get("tags", {}).get("aerialway") == "station":
                            stops.append((nm, n["lat"], n["lon"], n.get("tags", {}), m["ref"]))
            if len(stops) < 2 and len(path) >= 2:
                ends = [tags.get("from"), tags.get("to")]
                if not all(ends):
                    parts = re.split(r"\s*(?:→|–|-)\s*", re.sub(r"^[^:]*:\s*|\(.*?\)|^\S+\s", "", tags.get("name", "")))
                    parts = [x.replace("Teleferik Hattı", "").replace("Teleferik", "").strip() for x in parts if x.strip()]
                    if len(parts) >= 2:
                        ends = [parts[0], parts[-1]]
                if all(ends):
                    stops = [(ends[0], path[0][0], path[0][1], {}, 0), (ends[1], path[-1][0], path[-1][1], {}, 0)]
            if len(path) < 2 or len(stops) < 2:
                print("   skip relation %d (%s): path %d stops %d" % (rid, tags.get("name"), len(path), len(stops)))
                continue
            # orient path from first stop to last stop
            if hav(path[0], stops[0][1:3]) > hav(path[-1], stops[0][1:3]):
                path.reverse()
            path = simplify(path, 2.5)
            cum = cumulative(path)
            st_list = []
            projected = []
            for nm, la, lo_, t, oid in stops:
                s_m, err, _ = project_on_path(path, cum, (la, lo_), 0)
                projected.append((s_m, nm, la, lo_, t, oid))
            projected.sort(key=lambda x: x[0])  # some relations list their stops out of order
            for s_m, nm, la, lo_, t, oid in projected:
                sid = station_for(clean_station_name(nm), la, lo_, code)
                stations[sid]["_osm"].append(oid)
                wt = node_way_tags.get(oid, {})
                k = "u" if (wt.get("tunnel") in ("yes", "building_passage") or wt.get("layer", "0").startswith("-") or
                            t.get("location") == "underground") else ("e" if wt.get("bridge") in ("yes", "viaduct") else "")
                if k:
                    stations[sid].setdefault("_kind", {}).setdefault(code, []).append(k)
                elif wt:
                    stations[sid].setdefault("_kind", {}).setdefault(code, []).append("s")
                if t.get("wikidata"):
                    stations[sid]["wikidata"] = t["wikidata"]
                if st_list and st_list[-1][0] == sid:
                    continue
                st_list.append([sid, round(s_m, 1), round(la, 6), round(lo_, 6)])
            # enforce monotonic distances
            for i in range(1, len(st_list)):
                if st_list[i][1] < st_list[i - 1][1]:
                    st_list[i][1] = st_list[i - 1][1] + 1
            variants.append({
                "id": rid,
                "from": stations[st_list[0][0]]["name"],
                "to": stations[st_list[-1][0]]["name"],
                "length_m": round(cum[-1]),
                "path": encode_polyline(path),
                "stops": st_list,
            })
            print("   %-4s %-42s %5d pts %3d stops %6.1f km" % (code, tags.get("name", "")[:42], len(path), len(st_list), cum[-1] / 1000))
        if not variants:
            continue
        # A chaining glitch (unsorted / doubled ways) shows up as a much longer path than its twin
        # running the other way: reuse the twin's geometry reversed.
        for va in variants:
            for vb in variants:
                if va is vb or va["from"] != vb["to"] or va["to"] != vb["from"]:
                    continue
                if va["length_m"] > vb["length_m"] * 1.12:
                    pts = list(reversed(_decode(vb["path"])))
                    cum = cumulative(pts)
                    lo = 0
                    for st_ in va["stops"]:
                        st_[1], _, lo = project_on_path(pts, cum, (st_[2], st_[3]), lo)
                        st_[1] = round(st_[1], 1)
                    for i in range(1, len(va["stops"])):
                        if va["stops"][i][1] < va["stops"][i - 1][1]:
                            va["stops"][i][1] = va["stops"][i - 1][1] + 1
                    print("   %-4s fixed geometry %s → %s: %.1f km -> %.1f km" % (code, va["from"], va["to"], va["length_m"] / 1000, cum[-1] / 1000))
                    va["path"], va["length_m"] = encode_polyline(pts), round(cum[-1])
        spd, dwell = MODE_DEFAULTS[mode]
        hw = headways.get(GTFS_LINE.get(code, ""), None)
        lines_out.append({
            "code": code, "name": "Marmaray" if code == "B1" else code, "long": long_name, "mode": mode,
            "color": colour, "operator": "TCDD Taşımacılık" if code in ("B1", "B2", "M11") else ("İETT" if code == "F2" else "Metro İstanbul"),
            "speed_kmh": spd, "dwell_s": dwell,
            "headways": hw or FALLBACK_HEADWAY[mode], "headway_src": "İBB GTFS" if hw else "tahmini",
            "variants": variants,
        })

    for sid, s in stations.items():
        pts = s.pop("_pts")
        s["lat"] = round(sum(p[0] for p in pts) / len(pts), 6)
        s["lon"] = round(sum(p[1] for p in pts) / len(pts), 6)
        s["_osm"] = sorted(set(s["_osm"]))
    return {"lines": lines_out, "stations": stations}


# ───────────────────────── station plans (Overpass) ─────────────────────────

def build_plans(net, cache):
    s, w, n, e = BBOX
    bb = "%s,%s,%s,%s" % (s, w, n, e)
    print("[plans] overpass: entrances / platforms / vertical circulation / station tags")
    entr = overpass('[out:json][timeout:120];(node["railway"~"^(subway_entrance|train_station_entrance)$"](%s);node["entrance"]["railway"](%s););out;' % (bb, bb),
                    os.path.join(cache, "ovp", "entrances.json"))
    vert = overpass('[out:json][timeout:120];(node["highway"="elevator"](%s);way["highway"="steps"]["conveying"](%s););out center tags;' % (bb, bb),
                    os.path.join(cache, "ovp", "vertical.json"))
    plat = overpass('[out:json][timeout:150];(way["railway"="platform"](%s);relation["railway"="platform"](%s);node["railway"="platform"](%s););out center tags;' % (bb, bb, bb),
                    os.path.join(cache, "ovp", "platforms.json"))
    stat = overpass('[out:json][timeout:90];node["railway"~"^(station|halt)$"](%s);out tags;' % bb,
                    os.path.join(cache, "ovp", "stations.json"), attempts=3, optional=True)

    def center(el):
        if "lat" in el:
            return (el["lat"], el["lon"])
        c = el.get("center")
        return (c["lat"], c["lon"]) if c else None

    stations = net["stations"]
    # grid index of stations
    grid = collections.defaultdict(list)
    for sid, st in stations.items():
        grid[(int(st["lat"] * 200), int(st["lon"] * 200))].append(sid)

    def near(p, radius):
        gx, gy = int(p[0] * 200), int(p[1] * 200)
        best, bd = None, radius
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for sid in grid.get((gx + dx, gy + dy), []):
                    st = stations[sid]
                    d = hav(p, (st["lat"], st["lon"]))
                    if d < bd:
                        best, bd = sid, d
        return best, bd

    for st in stations.values():
        st.update({"entrances": [], "elevators": 0, "escalators": 0, "platforms": 0, "levels": [], "kind": "", "tags": {}})

    for el in stat["elements"]:
        p = center(el)
        if not p:
            continue
        sid, d = near(p, 400)
        if not sid:
            continue
        t = el.get("tags", {})
        st = stations[sid]
        for k in ("location", "station", "layer", "level", "wheelchair", "operator", "wikidata", "ele", "name:en", "building"):
            if k in t and k not in st["tags"]:
                st["tags"][k] = t[k]

    for el in entr["elements"]:
        p = center(el)
        sid, d = near(p, 350) if p else (None, 0)
        if not sid:
            continue
        t = el.get("tags", {})
        stations[sid]["entrances"].append({
            "ref": t.get("ref", ""), "name": t.get("name", "") or t.get("description", ""),
            "lat": round(p[0], 6), "lon": round(p[1], 6),
            "wc": t.get("wheelchair") == "yes", "level": t.get("level", ""),
        })
    for el in vert["elements"]:
        p = center(el)
        sid, d = near(p, 250) if p else (None, 0)
        if not sid:
            continue
        t = el.get("tags", {})
        if t.get("highway") == "elevator":
            stations[sid]["elevators"] += 1
        else:
            stations[sid]["escalators"] += 1
        for lv in re.split(r"[;,]", t.get("level", "")):
            try:
                stations[sid]["levels"].append(float(lv))
            except ValueError:
                pass
    for el in plat["elements"]:
        p = center(el)
        sid, d = near(p, 300) if p else (None, 0)
        if not sid:
            continue
        t = el.get("tags", {})
        stations[sid]["platforms"] += 1
        for k in ("level", "layer"):
            for lv in re.split(r"[;,]", t.get(k, "")):
                try:
                    stations[sid]["levels"].append(float(lv))
                except ValueError:
                    pass

    line_mode = {l["code"]: l["mode"] for l in net["lines"]}
    MODE_KIND = {"metro": "u", "suburban": "s", "tram": "s", "funicular": "u", "cable": "e"}
    MODE_DEPTH = {"metro": 22.0, "suburban": 24.0, "funicular": 16.0}
    for sid, st in stations.items():
        st.pop("tags", None)
        lv = sorted(set(st.pop("levels")))
        votes = st.pop("_kind", {})
        kinds, depths, srcs = {}, {}, {}
        for code in st["lines"]:
            mode = line_mode[code]
            vs = votes.get(code, [])
            k = max(set(vs), key=vs.count) if vs else MODE_KIND[mode]
            if code == "F3":
                k = "s"
            if (code, fold(st["name"])) in KNOWN_DEPTH:
                k = "u"
            kinds[code] = k
            if k == "u":
                kd = KNOWN_DEPTH.get((code, fold(st["name"])))
                if kd:
                    depths[code], srcs[code] = kd, "kaynak"
                elif lv and min(lv) < 0:
                    depths[code], srcs[code] = round(max(12.0, min(45.0, 7.5 * abs(min(lv)) + 2))), "osm"
                else:
                    depths[code], srcs[code] = MODE_DEPTH.get(mode, 18.0), "tahmini"
            elif k == "e":
                depths[code], srcs[code] = -8, "tahmini"
            else:
                depths[code], srcs[code] = 0, "osm" if votes.get(code) else "tahmini"
        st["kinds"] = kinds
        st["depths"] = depths
        st["depth_srcs"] = srcs
        prim = max(st["lines"], key=lambda c: (abs(depths[c]) if kinds[c] == "u" else -1, c))
        st["kind"] = {"u": "underground", "e": "elevated", "s": "surface"}[kinds[prim]]
        st["depth"] = depths[prim]
        st["depth_src"] = srcs[prim]
        st["platform"] = "side" if st["platforms"] >= 2 * max(1, len(st["lines"])) else "island"
        st["entrances"].sort(key=lambda x: (x["ref"] == "", x["ref"], x["name"]))
        st["entrances"] = st["entrances"][:12]
        st.pop("_osm", None)

    # ── projects: rail under construction ──
    print("[plans] overpass: rail projects under construction")
    cons = overpass('[out:json][timeout:150];(way["railway"="construction"]["construction"~"^(subway|light_rail|tram|rail|monorail)$"](%s);'
                    'way["railway"="construction"]["construction:railway"~"^(subway|light_rail|tram|rail)$"](%s);'
                    'node["construction:railway"~"^(station|halt)$"](%s);node["railway"="construction"]["construction"~"^(station|halt)$"](%s);'
                    'node["railway"~"^(station|halt)$"]["construction"](%s););out geom tags;' % (bb, bb, bb, bb, bb),
                    os.path.join(cache, "ovp", "construction.json"), attempts=4, optional=True)
    projects = collections.defaultdict(lambda: {"segments": [], "stations": []})
    for el in cons["elements"]:
        t = el.get("tags", {})
        label = " ".join([t.get("name", ""), t.get("ref", ""), t.get("construction:ref", ""), t.get("description", "")])
        m = re.search(r"\b(M\d{1,2}[A-Z]?|T\d|B\d|F\d)\b", label)
        code = m.group(1) if m else ("Raylı Sistem" if el["type"] == "way" else "")
        if el["type"] == "way" and el.get("geometry"):
            pts = simplify([(g["lat"], g["lon"]) for g in el["geometry"]], 4)
            if len(pts) >= 2:
                projects[code]["segments"].append(encode_polyline(pts))
        elif el["type"] == "node" and t.get("name"):
            projects[code]["stations"].append({"name": t["name"], "lat": round(el["lat"], 6), "lon": round(el["lon"], 6)})
    proj_out = []
    for code, p in projects.items():
        if not p["segments"] and not p["stations"]:
            continue
        col, long_name = PROJECTS.get(code, ("#9CA3AF", "İnşaat halindeki raylı sistem"))
        proj_out.append({"code": code or "Proje", "long": long_name, "color": col, "status": "construction",
                         "segments": p["segments"], "stations": p["stations"]})
    net["projects"] = sorted(proj_out, key=lambda x: x["code"])
    print("   projects:", [(p["code"], len(p["segments"]), len(p["stations"])) for p in net["projects"]])
    return net


# ───────────────────────── ferries ─────────────────────────

OPERATORS = {
    "sh": {"name": "Şehir Hatları", "short": "ŞH", "color": "#0B5CAD", "kind": "İBB", "url": "https://sehirhatlari.istanbul"},
    "turyol": {"name": "Turyol", "short": "TY", "color": "#E3A008", "kind": "Özel", "url": "https://www.turyol.com"},
    "dentur": {"name": "Dentur Avrasya", "short": "DA", "color": "#0E9F6E", "kind": "Özel", "url": "https://www.denturavrasya.com"},
    "ido": {"name": "İDO", "short": "İDO", "color": "#D61F69", "kind": "Özel", "url": "https://www.ido.com.tr"},
    "mavi": {"name": "Mavi Marmara", "short": "MM", "color": "#3F83F8", "kind": "Özel", "url": ""},
    "prenstur": {"name": "Prenstur", "short": "PT", "color": "#7E3AF2", "kind": "Özel", "url": ""},
    "budo": {"name": "BUDO", "short": "BUDO", "color": "#FF5A1F", "kind": "Özel", "url": "https://budo.burulas.com.tr"},
    "beyden": {"name": "Beyden", "short": "BY", "color": "#9061F9", "kind": "Özel", "url": ""},
    "motor": {"name": "Özel Motor", "short": "ÖM", "color": "#6B7280", "kind": "Özel", "url": ""},
    "seyrusefa": {"name": "Seyr-ü Sefa", "short": "SS", "color": "#8DA2FB", "kind": "Özel", "url": ""},
}
GTFS_AGENCY = {"6": "sh", "48": "turyol", "33": "dentur", "20": "ido"}

SH_BASE = "https://sehirhatlari.istanbul"


def pier_operator(name):
    n = name
    for key, op in (("Turyol", "turyol"), ("Dentur", "dentur"), ("İDO", "ido"), ("Mavi Marmara", "mavi"), ("Prenstur", "prenstur"),
                    ("BUDO", "budo"), ("Beyden", "beyden"), ("Seyrüsefa", "seyrusefa")):
        if key in n:
            return op
    return "sh"


def clean_pier_name(name):
    n = re.sub(r"\s*(ŞH|İDO|Turyol|Dentur|Mavi Marmara|Prenstur|BUDO|Beyden|Seyrüsefa)\.?(?=\s|$|\(|\))", "", name)
    n = re.sub(r"\(\s*\)", "", n)
    return re.sub(r"\s+", " ", n).strip(" .-")


def tr_title(s):
    """Turkish-aware title case: 'EMİNÖNÜ - KADIKÖY' -> 'Eminönü – Kadıköy'."""
    def low(w):
        return w.replace("I", "ı").replace("İ", "i").lower()

    def up(c):
        return {"i": "İ", "ı": "I"}.get(c, c.upper())
    words = re.split(r"(\s+|-|/|\()", s.strip())
    out = []
    for w in words:
        if w and w[0].isalpha():
            lw = low(w)
            out.append(up(lw[0]) + lw[1:])
        else:
            out.append(w)
    return re.sub(r"\s*-\s*", " – ", "".join(out)).replace("( ", "(")


def parse_sh_tables(page_html):
    """Returns [{"piers":[...], "kinds":[...], "rows":[[time|None,...]], "notes":{marker:text}, "days":label}]"""
    tables = []
    for tm in re.finditer(r"<table.*?</table>", page_html, re.S | re.I):
        t = tm.group(0)
        rows = re.findall(r"<tr[^>]*>(.*?)</tr>", t, re.S | re.I)
        cells = [[re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", c))).strip()
                  for c in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", r, re.S | re.I)] for r in rows]
        if len(cells) < 3:
            continue
        head = " ".join(cells[0])
        notes = {}
        for mm in re.finditer(r"(\*+)\s*([^*]+)", head):
            notes[mm.group(1)] = mm.group(2).strip()
        days = re.sub(r"\*.*", "", head).strip()
        piers = cells[1]
        kinds = cells[2] if len(cells) > 2 and any(k in " ".join(cells[2]) for k in ("Kalkış", "Varış")) else []
        body = cells[3:] if kinds else cells[2:]
        out_rows = []
        for r in body:
            if len(r) != len(piers):
                continue
            vals = []
            for c in r:
                m = re.match(r"(\d{1,2})[:.](\d{2})\s*(\**)", c)
                vals.append((int(m.group(1)) * 60 + int(m.group(2)), m.group(3)) if m else None)
            if any(vals):
                out_rows.append(vals)
        if out_rows:
            tables.append({"piers": piers, "kinds": kinds, "rows": out_rows, "notes": notes, "days": days})
    return tables


def days_mask(day_label, note):
    """Bit mask Mon..Sun (bit0 = Monday) from Şehir Hatları table headings and footnotes."""
    lab = fold(day_label)
    WEEK, SAT, SUN, ALL = 0b0011111, 0b0100000, 0b1000000, 0b1111111

    def mentioned(t):
        m = 0
        if "hafta ici" in t or "haftaici" in t:
            m |= WEEK
        if "cumartesi" in t or "c tesi" in t or "ctesi" in t:
            m |= SAT
        if "pazar" in t:
            m |= SUN
        if "hafta sonu" in t:
            m |= SAT | SUN
        return m
    if "baglayan" in lab:  # night services Fri->Sat and Sat->Sun
        mask = 0b0110000
    elif "her gun" in lab or "hergun" in lab:
        mask = ALL
    elif "yapilmaz" in lab:
        head, _, tail = lab.partition("yapilmaz")
        base = WEEK if ("hafta ici" in lab or "haftaici" in lab) else ALL
        excl = mentioned(head.replace("hafta ici", "").replace("haftaici", ""))
        mask = base & ~excl if base == ALL else base
    else:
        mask = mentioned(lab) or ALL
    if note:
        nf = fold(note)
        if "yapilmaz" in nf:
            mask &= ~mentioned(nf.partition("yapilmaz")[0])
        elif "sadece" in nf or "yapilir" in nf:
            m2 = mentioned(nf)
            if m2:
                mask &= m2
    return mask or ALL


def order_by_time(stops):
    """Travel order is time order (tables list piers geographically); handles runs past midnight."""
    st = [list(x) for x in stops]
    mins = [m for _, m in st]
    if max(mins) - min(mins) > 12 * 60:
        for x in st:
            if x[1] < 6 * 60:
                x[1] += 1440
    st.sort(key=lambda x: x[1])
    return st


def merge_duplicate_trips(patterns):
    """The same voyage listed twice (copied tables, overlapping GTFS calendars) -> one trip, days OR-ed."""
    seen = {}
    out = []
    for pat in patterns:
        kept = []
        for t in pat["trips"]:
            key = tuple((p, m) for p, m in t["s"])
            if key in seen:
                seen[key]["d"] |= t["d"]
                continue
            seen[key] = t
            kept.append(t)
        if kept:
            out.append(dict(pat, trips=sorted(kept, key=lambda x: x["s"][0][1])))
    return out


def build_ferries(cache, gtfs_dir, geo_dir, offline=False):
    print("[ferries] piers + routes from İBB GeoJSON")
    with open(os.path.join(geo_dir, "deniz_iskele.geojson"), encoding="utf-8") as f:
        iskele = json.load(f)
    with open(os.path.join(geo_dir, "deniz_hat.geojson"), encoding="utf-8") as f:
        hatlar = json.load(f)

    piers = {}
    pier_by_fold = collections.defaultdict(list)
    for i, ft in enumerate(iskele["features"]):
        name = ft["properties"].get("ISKELE_AD", "").strip()
        lon, lat = ft["geometry"]["coordinates"][:2]
        pid = "p%d" % (i + 1)
        op = pier_operator(name)
        piers[pid] = {"name": clean_pier_name(name), "full": name, "lat": round(lat, 6), "lon": round(lon, 6), "ops": [op]}
        pier_by_fold[fold(clean_pier_name(name))].append(pid)

    for pid, p in piers.items():  # aliases ("Kadıköy Balon" -> also "kadikoy")
        base = fold(p["name"]).split(" ")[0]
        if pid not in pier_by_fold.get(base, []):
            pier_by_fold[base].append(pid)

    ALIAS = {"yeni kadikoy": "kadikoy yeni", "eminonu camli": "eminonu", "kadikoy2 cayirbasi": "kadikoy",
             "eyupsultan": "eyup", "besiktas barbaros": "besiktas barbaros", "besiktas": "besiktas tarihi"}

    def find_pier(name, op=None, near_pt=None):
        if near_pt and near_pt[0]:
            cands = [pid for pid in piers if hav(near_pt, (piers[pid]["lat"], piers[pid]["lon"])) < 700]
            if cands:
                cands.sort(key=lambda pid: (0 if op in piers[pid]["ops"] else 1,
                                            hav(near_pt, (piers[pid]["lat"], piers[pid]["lon"]))))
                return cands[0]
        key = fold(clean_pier_name(name))
        key = ALIAS.get(key, key)
        cands = list(pier_by_fold.get(key, []))
        if not cands:
            cands = [pid for k, v in pier_by_fold.items() for pid in v if k.startswith(key + " ") or key.startswith(k + " ")]
        if not cands:
            return None
        if op:
            same = [c for c in cands if op in piers[c]["ops"]]
            if same:
                cands = same
        return cands[0]

    # sea paths (lon,lat -> lat,lon)
    sea_paths = []
    for ft in hatlar["features"]:
        g = ft["geometry"]
        parts = g["coordinates"] if g["type"] == "MultiLineString" else [g["coordinates"]]
        for part in parts:
            pts = [(c[1], c[0]) for c in part]
            if len(pts) >= 2:
                sea_paths.append({"name": ft["properties"].get("ISIM_HAT", ""), "rota": ft["properties"].get("HAT_ROTA", ""),
                                  "type": ft["properties"].get("TUR_HAT", ""), "pts": pts, "cum": cumulative(pts)})

    def leg_path(a, b):
        """Best sea-following path between two piers (lat,lon tuples)."""
        best, best_cost = None, 1e18
        direct = hav(a, b)
        for sp in sea_paths:
            sa, da, ia = project_on_path(sp["pts"], sp["cum"], a)
            sb, db, ib = project_on_path(sp["pts"], sp["cum"], b)
            if da > 450 or db > 450 or abs(sb - sa) < 50:
                continue
            length = abs(sb - sa)
            if length > direct * 2.2 + 1500:
                continue
            cost = da + db + 0.15 * length
            if cost < best_cost:
                if sa <= sb:
                    seg = [a] + sp["pts"][ia + 1: ib + 1] + [b]
                else:
                    seg = [a] + list(reversed(sp["pts"][ib + 1: ia + 1])) + [b]
                best, best_cost = seg, cost
        return best or [a, b]

    lines = []

    # ── Şehir Hatları: current timetables from sehirhatlari.istanbul ──
    sh_pages = []
    try:
        idx = http_get(SH_BASE + "/tr/seferler/ic-hatlar", os.path.join(cache, "sh", "index.html")).decode("utf-8", "replace")
        sh_pages = sorted(set(re.findall(r'href="(/tr/seferler/ic-hatlar/[a-z-]+/[a-z0-9-]+-\d+)"', idx)))
    except Exception as e:  # noqa: BLE001
        print("   Şehir Hatları index unavailable:", e)
    print("   Şehir Hatları line pages:", len(sh_pages))
    sh_ok = 0
    for href in sh_pages:
        slug = href.rsplit("/", 1)[-1]
        try:
            page = http_get(SH_BASE + href, os.path.join(cache, "sh", slug + ".html")).decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001
            print("   skip", slug, e)
            continue
        title_m = re.search(r"<h1[^>]*>(.*?)</h1>", page, re.S) or re.search(r"<title>(.*?)</title>", page, re.S)
        title = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", title_m.group(1)))).strip() if title_m else slug
        title = re.sub(r"\s*[-|]\s*Şehir Hatları.*$", "", title).strip()
        tables = parse_sh_tables(page)
        if not tables:
            continue
        line = {"id": "sh-" + slug, "op": "sh", "name": tr_title(title), "src": "Şehir Hatları Kış 2026 tarifesi", "official": True,
                "url": SH_BASE + href, "patterns": []}
        terminals = [t.strip() for t in re.split(r"\s+-\s*|\s*-\s+", re.sub(r"(?i)hatt?ı?\s*$", "", title)) if t.strip()]
        for tb in tables:
            pids = []
            for pname in tb["piers"]:
                pid = find_pier(pname, "sh")
                pids.append(pid)
            if len(pids) == 1 and pids[0] and len(terminals) >= 2:
                # one column = departures only; the other end of the line is the arrival pier
                other = [t for t in terminals if fold(t) not in fold(tb["piers"][0]) and fold(tb["piers"][0]) not in fold(t)]
                dest = find_pier(other[-1] if other else terminals[-1], "sh")
                if dest and dest != pids[0]:
                    pa = (piers[pids[0]]["lat"], piers[pids[0]]["lon"])
                    pb = (piers[dest]["lat"], piers[dest]["lon"])
                    mins = int(round(sum(hav(x, y) for x, y in zip(leg_path(pa, pb), leg_path(pa, pb)[1:])) / 1000 / 20 * 60 + 1))
                    tb = dict(tb, rows=[[r[0], (r[0][0] + mins, "") if r[0] else None] for r in tb["rows"]])
                    pids = [pids[0], dest]
            if sum(1 for p in pids if p) < 2:
                continue
            trips = []
            for row in tb["rows"]:
                stops = []
                marker = ""
                for pid, cell in zip(pids, row):
                    if pid and cell:
                        stops.append([pid, cell[0]])
                        if cell[1] and len(cell[1]) > len(marker):
                            marker = cell[1]
                if len(stops) >= 2:
                    stops = order_by_time(stops)
                    trips.append({"d": days_mask(tb["days"], tb["notes"].get(marker)), "s": stops,
                                  **({"n": tb["notes"][marker]} if marker in tb["notes"] else {})})
            if trips:
                line["patterns"].append({"label": " → ".join(piers[p]["name"] for p in pids if p), "days": tb["days"], "trips": trips})
        line["patterns"] = merge_duplicate_trips(line["patterns"])
        if line["patterns"]:
            lines.append(line)
            sh_ok += 1
    print("   Şehir Hatları lines parsed:", sh_ok)

    # ── Private operators (and Şehir Hatları fallback) from İBB GTFS ──
    print("[ferries] İBB GTFS timetables for private operators")
    routes = {r["route_id"]: r for r in read_gtfs(gtfs_dir, "routes.txt")}
    stops_g = {s["stop_id"]: s for s in read_gtfs(gtfs_dir, "stops.txt")}
    cal = {c["service_id"]: c for c in read_gtfs(gtfs_dir, "calendar.txt")}
    trips = [t for t in read_gtfs(gtfs_dir, "trips.txt") if routes.get(t["route_id"], {}).get("agency_id") in GTFS_AGENCY]
    use_agencies = {"48", "33", "20"} | ({"6"} if sh_ok == 0 else set())
    trips = [t for t in trips if routes[t["route_id"]]["agency_id"] in use_agencies]
    tids = {t["trip_id"]: t for t in trips}
    st = collections.defaultdict(list)
    with open(os.path.join(gtfs_dir, "stop_times.txt"), encoding="cp1254", newline="") as f:
        for r in csv.DictReader(f):
            if r["trip_id"] in tids:
                st[r["trip_id"]].append((int(r["stop_sequence"]), hms_to_min(r["departure_time"]), r["stop_id"]))
    by_route = collections.defaultdict(list)
    for tid, t in tids.items():
        by_route[t["route_id"]].append(t)
    for rid, rtrips in by_route.items():
        r = routes[rid]
        op = GTFS_AGENCY[r["agency_id"]]
        patterns = collections.OrderedDict()
        for t in rtrips:
            seq = sorted(st.get(t["trip_id"], []))
            if len(seq) < 2:
                continue
            c = cal.get(t["service_id"], {})
            if c.get("end_date", "20991231") < "20240101":
                continue
            d = sum(1 << i for i, k in enumerate(("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")) if c.get(k) == "1")
            if not d:
                continue
            pids = []
            for _, _, sid in seq:
                g = stops_g.get(sid, {})
                pt = (float(g.get("stop_lat") or 0), float(g.get("stop_lon") or 0))
                pids.append(find_pier(g.get("stop_name", ""), op, pt))
            if sum(1 for p in pids if p) < 2:
                continue
            key = tuple(pids)
            stops_t = [[p, m] for p, (_, m, _) in zip(pids, seq) if p]
            patterns.setdefault(key, []).append({"d": d, "s": stops_t})
        if not patterns:
            continue
        pats = []
        for key, tr in patterns.items():
            pats.append({"label": " → ".join(piers[p]["name"] for p in key if p), "days": "",
                         "trips": [dict(x, s=order_by_time(x["s"])) for x in tr]})
        pats = merge_duplicate_trips(pats)
        # GTFS arrival times of private operators are padded (block times): keep each departure,
        # recompute implausible legs from the sea-path length at a typical motor-boat speed.
        for pat in pats:
            for t in pat["trips"]:
                st_ = t["s"]
                for k in range(1, len(st_)):
                    a, b = st_[k - 1][0], st_[k][0]
                    pa, pb = (piers[a]["lat"], piers[a]["lon"]), (piers[b]["lat"], piers[b]["lon"])
                    path = leg_path(pa, pb)
                    est = max(4, round(sum(hav(x, y) for x, y in zip(path, path[1:])) / 1000 / 18 * 60 + 2))
                    dur = st_[k][1] - st_[k - 1][1]
                    if dur > est * 1.6 + 4 or dur < est * 0.5:
                        shift = (st_[k - 1][1] + est) - st_[k][1]
                        for j in range(k, len(st_)):
                            st_[j][1] += shift
        lines.append({"id": "%s-%s" % (op, rid), "op": op, "name": tr_title(r["route_long_name"]),
                      "code": r["route_short_name"], "src": "İBB GTFS (planlanan tarife)", "official": False,
                      "url": OPERATORS[op]["url"], "patterns": pats})

    # ── piers serving each line, legs geometry ──
    leg_cache = {}
    for ln in lines:
        used = []
        for pat in ln["patterns"]:
            seqs = collections.Counter(tuple(s[0] for s in t["s"]) for t in pat["trips"])
            for seq, _ in seqs.most_common(3):
                for a, b in zip(seq, seq[1:]):
                    if a == b:
                        continue
                    k = (a, b)
                    if k not in leg_cache and (b, a) not in leg_cache:
                        pa = (piers[a]["lat"], piers[a]["lon"])
                        pb = (piers[b]["lat"], piers[b]["lon"])
                        leg_cache[k] = encode_polyline(simplify(leg_path(pa, pb), 6))
            for t in pat["trips"]:
                for pid, _ in t["s"]:
                    if pid not in used:
                        used.append(pid)
        ln["piers"] = used
        for pid in used:
            if ln["op"] not in piers[pid]["ops"]:
                piers[pid]["ops"].append(ln["op"])
    legs = {"%s|%s" % k: v for k, v in leg_cache.items()}

    # decorative / reference routes for operators without timetables
    ref_routes = []
    for sp in sea_paths:
        if sp["type"] in ("Özel Motor", "Arabalı Vapur"):
            ref_routes.append({"name": sp["name"], "type": sp["type"], "path": encode_polyline(simplify(sp["pts"], 8))})

    print("   lines: %d  piers: %d  legs: %d" % (len(lines), len(piers), len(legs)))
    return {"operators": OPERATORS, "piers": piers, "lines": lines, "legs": legs, "ref_routes": ref_routes}


# ───────────────────────── media (Wikimedia Commons) ─────────────────────────

MEDIA_QUERIES = {
    "marmaray": ["Marmaray E32000", "Marmaray train Istanbul"],
    "metro": ["Rolling stock of Istanbul M2 line", "Istanbul Metro train"],
    "metro_driverless": ["M5 Kısıklı Metro İstasyonu", "Istanbul M5 metro train", "İstanbul M5 and M8 Metro Trains"],
    "tram": ["Istanbul T1 tram Alstom Citadis", "Istanbul tram T1"],
    "nostalgic_tram": ["Istanbul nostalgic tram Istiklal", "Moda nostalgic tram"],
    "funicular": ["Funicular Taksim-Kabataş", "Istanbul Taksim-Kabatas Funikuleri"],
    "cable": ["Eyüp Piyer Loti teleferik", "Maçka Taşkışla teleferik", "Eyüp cable car Istanbul", "Pierre Loti cable car"],
    "bus": ["Mercedes-Benz O530 Citaro Istanbul IETT", "IstanbulBus", "İETT otobüs"],
    "metrobus": ["Mercedes-Benz CapaCity Istanbul metrobus", "Incirli Metrobus station", "Metrobüs Istanbul bus"],
    "ferry_sh": ["Şehir Hatları ferry", "Istanbul ferry vapur Bosphorus"],
    "ferry_turyol": ["Bir Turyol gemisi", "Turyol ferry Istanbul", "Turyol"],
    "ferry_dentur": ["Dentur Avrasya", "Dentur Avrasya boat"],
    "ferry_ido": ["İDO deniz otobüsü", "IDO seabus Istanbul", "Istanbul Deniz Otobüsleri", "Deniz otobüsü İstanbul"],
    "car_ferry": ["Istanbul car ferrie", "Sirkeci Harem car ferry", "Istanbul car ferry"],
}
# Visually verified photos (Commons file titles). These win over search results.
MEDIA_PICK = {
    "marmaray": ["Marmaray-TCDD E32000 @ Sirkeci, Istanbul Turkey 2024 (%d).jpg" % i for i in (2, 1, 3, 4)],
    "metro": ["Rolling stock of Istanbul M2 line (2).jpg", "Rolling stock of Istanbul M2 line (1).jpg",
              "Inside of Istanbul M1 metro train in May 2008.jpg"],
    "metro_driverless": ["M5 Kısıklı Metro İstasyonu.jpg", "İstanbul M5 and M8 Metro Trains.jpg"],
    "tram": ["Istanbul T1 line Alstom Citadis tram.jpg", "Alstom Citadis X-04 on Galata Bridge.jpg",
             "Istanbul Metro tram, Güngören T1 2.jpg"],
    "nostalgic_tram": ["Nostalgic tram on Istiklal Avenue in Istanbul.jpg", "Istanbul nostalgic tram 5.jpg",
                       "Istanbul nostalgic tram 4.jpg", "NostalgicTramİstiklalAvenue.jpg"],
    "funicular": ["Istanbul Taksim-Kabatas Funikuleri 4.jpg", "Funicular Taksim-Kabataş 1.JPG",
                  "Funiculier Taksim- Kabatas, Istanbul - panoramio.jpg"],
    "cable": ["Eyüp Gondola 2.jpg", "Eyüp Gondola 4.jpg", "Eyüp Gondola in April 2023 (1).jpg"],
    "bus": ["Mercedes-Benz O530 Citaro.jpg", "IstanbulBus03.JPG", "15a-1.jpg"],
    "metrobus": ["MercedesCapaCityC1Istanbul.jpg", "Metrobus Istanbul 2010.jpg", "Incirli Metrobus station Mars 2013.jpg"],
    "ferry_sh": ["A Şehir Hatları Ferry.jpg", "Istanbul ferry at sunset on the Bosphorus - Tarik Kaan Muslu.jpg",
                 "Istanbul ferry seagull.jpg"],
    "ferry_turyol": ["Bir Turyol gemisi.jpg", '"Istanbul-gemi".jpg'],
    "ferry_dentur": ["Besiktas, Dentur Avrasya, Istanbul (P1100269) (cropped).jpg", "Dentur Avrasya, Istanbul (P1100269).jpg"],
    "ferry_ido": ["Cruise ship and Seabus in Istanbul.jpg", "İstanbul waterfront.jpg"],
    "car_ferry": ["Istanbul car ferrie ŞH-Erguvan.jpg", "Sultanahmet, Istanbul (P1100255).jpg",
                  "Sultanahmet, Istanbul (P1100256).jpg"],
}

# Search hits that are not a photo of the vehicle (screens, maps, people, other cities …).
MEDIA_EXCLUDE = ("screen", "counter", "çarşı metro platform", "setüstü", "map of", "busy istanbul", "ömer öztürk",
                 "mumbai", "saadetdere", "durağı", "logo", "sign", "diagram", "schema", "plan of", "ticket", "interior")


def _commons_item(ii, title):
    md = ii.get("extmetadata", {})
    lic = md.get("LicenseShortName", {}).get("value", "")
    artist = re.sub(r"<[^>]+>", "", html.unescape(md.get("Artist", {}).get("value", ""))).strip()[:80]
    return {
        "url": ii.get("thumburl") or ii.get("url"), "page": ii.get("descriptionurl"),
        "title": title.replace("File:", "").rsplit(".", 1)[0][:90],
        "author": artist or "Wikimedia Commons", "license": lic,
    }


def build_media(cache):
    print("[media] Wikimedia Commons photos")
    out = {}
    for key, queries in MEDIA_QUERIES.items():
        items = []
        pick = MEDIA_PICK.get(key)
        if pick:
            titles = "|".join("File:" + t for t in pick)
            url = ("https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo"
                   "&iiprop=url|extmetadata|size|mime&iiurlwidth=960&titles=%s" % urllib.parse.quote(titles))
            try:
                data = json.loads(http_get(url, os.path.join(cache, "commons", "pick_" + key + ".json")))
                pages = {p.get("title"): p for p in (data.get("query", {}).get("pages", {}) or {}).values()}
                norm = {n["from"]: n["to"] for n in data.get("query", {}).get("normalized", [])}
                for t in pick:
                    pg = pages.get(norm.get("File:" + t, "File:" + t))
                    if pg and pg.get("imageinfo"):
                        items.append(_commons_item(pg["imageinfo"][0], pg["title"]))
            except Exception as e:  # noqa: BLE001
                print("   ", key, e)
        for q in ([] if len(items) >= 2 else queries):
            url = ("https://commons.wikimedia.org/w/api.php?action=query&format=json&generator=search&gsrnamespace=6"
                   "&gsrlimit=12&gsrsearch=%s&prop=imageinfo&iiprop=url|extmetadata|size|mime&iiurlwidth=960" % urllib.parse.quote(q))
            try:
                data = json.loads(http_get(url, os.path.join(cache, "commons", re.sub(r"[^a-z0-9]+", "_", q.lower()) + ".json")))
            except Exception as e:  # noqa: BLE001
                print("   ", q, e)
                continue
            pages = sorted((data.get("query", {}).get("pages", {}) or {}).values(), key=lambda p: p.get("index", 99))
            for p in pages:
                ii = (p.get("imageinfo") or [{}])[0]
                if ii.get("mime") not in ("image/jpeg", "image/png", "image/webp"):
                    continue
                if (ii.get("width") or 0) < 800 or (ii.get("width") or 0) < (ii.get("height") or 0):
                    continue
                lic = ii.get("extmetadata", {}).get("LicenseShortName", {}).get("value", "")
                if not any(x in lic for x in ("CC", "Public domain", "PD")):
                    continue
                if any(x in p.get("title", "").lower() for x in MEDIA_EXCLUDE):
                    continue
                items.append(_commons_item(ii, p.get("title", "")))
            if len(items) >= 3:
                break
        seen, uniq = set(), []
        for it in items:
            if it["url"] and it["url"] not in seen:
                seen.add(it["url"])
                uniq.append(it)
        out[key] = uniq[:4]
        print("   %-16s %d photo(s)" % (key, len(out[key])))
    return out


# ───────────────────────── main ─────────────────────────

def write_json(name, obj):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    print("wrote %s (%.0f KB)" % (os.path.relpath(path, BASE_DIR), os.path.getsize(path) / 1024))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=["all", "rail", "ferries", "media"])
    ap.add_argument("--cache", default=os.path.join(BASE_DIR, "tools", ".cache"))
    ap.add_argument("--gtfs", help="Directory with the İBB GTFS csv files (agency.txt, routes.txt, ...)")
    ap.add_argument("--geo", help="Directory with deniz_hat.geojson + deniz_iskele.geojson (İBB open data)")
    ap.add_argument("--offline", action="store_true")
    a = ap.parse_args()
    gtfs = a.gtfs or os.path.join(a.cache, "gtfs")
    geo = a.geo or os.path.join(a.cache, "geo")
    stamp = dt.date.today().isoformat()
    if a.what in ("all", "rail"):
        net = build_rail(a.cache, gtfs)
        net = build_plans(net, a.cache)
        net.update({"v": 2, "generated": stamp, "attribution": "© OpenStreetMap katkıcıları (ODbL) · İBB Açık Veri (GTFS)"})
        write_json("rail_network.json", net)
    if a.what in ("all", "ferries"):
        fer = build_ferries(a.cache, gtfs, geo, a.offline)
        fer.update({"v": 1, "generated": stamp, "attribution": "İBB Açık Veri · Şehir Hatları · İBB GTFS"})
        write_json("ferry_network.json", fer)
    if a.what in ("all", "media"):
        write_json("vehicle_media.json", {"v": 1, "generated": stamp, "items": build_media(a.cache)})


if __name__ == "__main__":
    sys.exit(main())
