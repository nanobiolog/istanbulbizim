#!/usr/bin/env python3
"""
feeder.py - Background GPS feeder & daily duty sync for IstanbulBizim Live.
Polls İETT fleet GPS directly (respecting the 100/hr limit) and synchronizes
daily bus duty assignments from İETT Archive API at 00:00 local time.
"""

import os
import sys
import time
import json
import re
import datetime
import threading
import subprocess
import urllib.request
import ssl

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
WORKER_URL = os.environ.get("WORKER_URL", "https://istanbulbizim.nano-carbay.workers.dev")
WORKER_FEED_URL = os.environ.get("WORKER_FEED_URL", f"{WORKER_URL}/feed/buses")
WORKER_MAP_URL = os.environ.get("WORKER_MAP_URL", f"{WORKER_URL}/feed/mapping")
IETT_URL = "https://api.ibb.gov.tr/iett/FiloDurum/SeferGerceklesme.asmx"
IBB360_URL = "https://api.ibb.gov.tr/iett/ibb/ibb360.asmx"

SOAP_PAYLOAD = """<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <GetFiloAracKonum_json xmlns="http://tempuri.org/" />
  </soap:Body>
</soap:Envelope>"""

def fetch_iett_fleet():
    headers = {
        "Content-Type": "text/xml; charset=utf-8",
        "SOAPAction": '"http://tempuri.org/GetFiloAracKonum_json"',
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    }
    req = urllib.request.Request(IETT_URL, data=SOAP_PAYLOAD.encode("utf-8"), headers=headers)
    try:
        ctx = ssl._create_unverified_context()
        with urllib.request.urlopen(req, context=ctx, timeout=15) as res:
            xml = res.read().decode("utf-8")
            start = xml.find("<GetFiloAracKonum_jsonResult>")
            end = xml.find("</GetFiloAracKonum_jsonResult>")
            if start == -1 or end == -1:
                return None
            raw_json = xml[start + len("<GetFiloAracKonum_jsonResult>"):end]
            return json.loads(raw_json)
    except Exception as e:
        print(f"[{time.strftime('%X')}] Error fetching from IETT: {e}", flush=True)
        return None

def sync_mapping(days=3):
    """
    Syncs door-to-line assignments from IETT ibb360.
    Identifies each vehicle's primary/latest assigned line to handle duty changes cleanly.
    """
    print(f"[{time.strftime('%X')}] Syncing door-to-line assignments from IETT ibb360 (last {days} days)...", flush=True)
    ctx = ssl._create_unverified_context()
    headers = {
        "Content-Type": "text/xml; charset=utf-8",
        "SOAPAction": '"http://tempuri.org/GetIettArsivGorev_json"',
        "User-Agent": "Mozilla/5.0"
    }

    # Istanbul local date (UTC+3)
    tz_istanbul = datetime.timezone(datetime.timedelta(hours=3))
    now_istanbul = datetime.datetime.now(tz_istanbul)
    base = now_istanbul.date() - datetime.timedelta(days=1)

    door_tasks = {} # door -> list of {line, day, ts}

    for i in range(days):
        d = base - datetime.timedelta(days=i)
        dt = d.strftime("%Y%m%d")
        payload = f"""<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <GetIettArsivGorev_json xmlns="http://tempuri.org/">
      <Tarih>{dt}</Tarih>
    </GetIettArsivGorev_json>
  </soap:Body>
</soap:Envelope>"""
        try:
            req = urllib.request.Request(IBB360_URL, data=payload.encode("utf-8"), headers=headers)
            with urllib.request.urlopen(req, context=ctx, timeout=35) as res:
                txt = res.read().decode("utf-8")
                s = txt.find("<GetIettArsivGorev_jsonResult>")
                e = txt.find("</GetIettArsivGorev_jsonResult>")
                if s != -1 and e != -1:
                    day_data = json.loads(txt[s+len("<GetIettArsivGorev_jsonResult>"):e])
                    for r in day_data:
                        k = r.get("SKAPINUMARA")
                        h = r.get("SHATKODU")
                        day_val = int(r.get("NKAYITGUNU") or dt)
                        raw_date = r.get("DTBASLAMAZAMANI", "")
                        m = re.search(r"\d+", str(raw_date))
                        start_ts = int(m.group(0)) if m else 0
                        if k and h:
                            door_tasks.setdefault(k, []).append({
                                "line": h,
                                "day": day_val,
                                "ts": start_ts
                            })
                    print(f"   -> {dt}: {len(day_data)} tasks loaded", flush=True)
                else:
                    print(f"   -> {dt}: archive duties not yet published or empty", flush=True)
        except Exception as err:
            print(f"   -> {dt} error: {err}", flush=True)

    if not door_tasks:
        print(f"[{time.strftime('%X')}] Warning: No duty records retrieved from IETT.", flush=True)
        return False

    door_to_line = {}
    line_to_doors = {}

    for door, tasks in door_tasks.items():
        # Find latest active day for this vehicle
        latest_day = max(t["day"] for t in tasks)
        latest_day_tasks = [t for t in tasks if t["day"] == latest_day]
        # Sort chronologically by duty start timestamp
        latest_day_tasks.sort(key=lambda x: x["ts"])
        # The primary line is the vehicle's latest active duty
        primary_line = latest_day_tasks[-1]["line"]
        door_to_line[door] = primary_line

        # Also assign to lines served on that latest day
        for t in latest_day_tasks:
            line_to_doors.setdefault(t["line"], set()).add(door)

    dict_lines = {k: sorted(list(v)) for k, v in line_to_doors.items()}
    total_doors = len(door_to_line)
    total_assignments = sum(len(v) for v in dict_lines.values())
    print(f"[{time.strftime('%X')}] Compiled {len(dict_lines)} lines with {total_assignments} assignments ({total_doors} unique buses).", flush=True)
    if "O1013" in door_to_line:
        print(f"   -> O1013 primary line resolved to: {door_to_line['O1013']}", flush=True)

    # Also add Metrobüs & Turkish character aliases
    metrobus_doors = dict_lines.get("34G", [])
    if "34T" not in dict_lines and metrobus_doors:
        dict_lines["34T"] = metrobus_doors
    if "34U" not in dict_lines and metrobus_doors:
        dict_lines["34U"] = metrobus_doors
    for tr, asc in [
        ("130Ş", "130S"), ("130ŞT", "130ST"), ("133Ş", "133S"),
        ("14ŞB", "14SB"), ("15ŞN", "15SN"), ("29Ş", "29S"),
        ("54HŞ", "54HS"), ("78Ş", "78S"), ("79Ş", "79S"),
        ("92Ş", "92S"), ("AND1Ş", "AND1S")
    ]:
        if asc in dict_lines and tr not in dict_lines:
            dict_lines[tr] = dict_lines[asc]
        elif tr in dict_lines and asc not in dict_lines:
            dict_lines[asc] = dict_lines[tr]

    # Save to local files in workspace & ~/.istanbulbizim
    destinations = [
        (os.path.join(BASE_DIR, "src", "bus_lines_map.json"), dict_lines),
        (os.path.join(BASE_DIR, "src", "door_lines_map.json"), door_to_line),
        (os.path.join(BASE_DIR, "mobile_app", "assets", "data", "bus_lines_map.json"), dict_lines),
        (os.path.expanduser("~/.istanbulbizim/bus_lines_map.json"), dict_lines),
        (os.path.expanduser("~/.istanbulbizim/door_lines_map.json"), door_to_line)
    ]
    for path, data_obj in destinations:
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data_obj, f, ensure_ascii=False, indent=2)
            print(f"   -> Saved mapping to {path}", flush=True)
        except Exception as e:
            pass

    # Rebuild bundle.js if build.py exists in project
    build_script = os.path.join(BASE_DIR, "build.py")
    if os.path.exists(build_script):
        try:
            subprocess.run([sys.executable, build_script], check=False, stdout=subprocess.DEVNULL)
            print(f"   -> Re-bundled src/bundle.js with updated line mappings.", flush=True)
        except Exception:
            pass

    # Push { lines, doors } to Cloudflare Worker KV
    try:
        payload = json.dumps({"lines": dict_lines, "doors": door_to_line}).encode("utf-8")
        req = urllib.request.Request(WORKER_MAP_URL, data=payload, headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, context=ctx, timeout=25) as res:
            res_data = json.loads(res.read().decode("utf-8"))
            print(f"[{time.strftime('%X')}] Successfully pushed mappings to Worker KV: {res_data}", flush=True)
            return True
    except Exception as e:
        print(f"[{time.strftime('%X')}] Error pushing mapping to Worker: {e}", flush=True)
        return False

def run_midnight_sync_scheduler():
    """
    Background worker that runs continuously and triggers sync_mapping()
    every day at 00:00 local Istanbul time (UTC+3) to ingest duty updates.
    """
    tz_istanbul = datetime.timezone(datetime.timedelta(hours=3))
    state_file = os.path.expanduser("~/.istanbulbizim/last_sync.json")
    last_synced_date = None

    if os.path.exists(state_file):
        try:
            with open(state_file, "r") as f:
                data = json.load(f)
                last_synced_date = data.get("date")
        except Exception:
            pass

    print(f"[{time.strftime('%X')}] Midnight sync scheduler initialized (last synced: {last_synced_date}).", flush=True)

    while True:
        try:
            now = datetime.datetime.now(tz_istanbul)
            today_str = now.strftime("%Y%m%d")

            # Trigger sync if today hasn't been synced yet and time is past 00:01
            # (Waiting 1 minute past midnight gives IETT time to archive yesterday's completed tasks)
            if today_str != last_synced_date and (now.hour > 0 or now.minute >= 1):
                print(f"[{time.strftime('%X')}] Daily midnight duty sync starting for {today_str}...", flush=True)
                success = sync_mapping(days=3)
                if success:
                    last_synced_date = today_str
                    try:
                        os.makedirs(os.path.dirname(state_file), exist_ok=True)
                        with open(state_file, "w") as f:
                            json.dump({"date": today_str, "synced_at": time.time()}, f)
                    except Exception:
                        pass
                    print(f"[{time.strftime('%X')}] Midnight duty sync completed successfully for {today_str}.", flush=True)
                else:
                    print(f"[{time.strftime('%X')}] Midnight duty sync incomplete, will retry in 5 minutes...", flush=True)
                    time.sleep(300)
                    continue
        except Exception as e:
            print(f"[{time.strftime('%X')}] Error in midnight sync scheduler: {e}", flush=True)

        time.sleep(30)

def push_to_worker(buses):
    cleaned = []
    for b in buses:
        try:
            lat = float(str(b.get("Enlem", "")).replace(",", "."))
            lon = float(str(b.get("Boylam", "")).replace(",", "."))
            if lat < 40.5 or lat > 41.6 or lon < 27.8 or lon > 29.8:
                continue
            speed = float(str(b.get("Hiz", "0")).replace(",", "."))
            cleaned.append({
                "id": b.get("KapiNo", ""),
                "lat": round(lat, 5),
                "lon": round(lon, 5),
                "s": round(speed),
                "t": b.get("Saat", ""),
                "op": b.get("Operator", ""),
                "p": b.get("Plaka", "")
            })
        except Exception:
            continue

    now_ms = int(time.time() * 1000)
    payload = json.dumps({"buses": cleaned, "pushed_at": now_ms}).encode("utf-8")
    req = urllib.request.Request(WORKER_FEED_URL, data=payload, headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
    try:
        ctx = ssl._create_unverified_context()
        with urllib.request.urlopen(req, context=ctx, timeout=15) as res:
            result = json.loads(res.read().decode("utf-8"))
            print(f"[{time.strftime('%X')}] Successfully pushed {result.get('count')} buses to Cloudflare Worker.", flush=True)
    except Exception as e:
        print(f"Error pushing to Worker: {e}", flush=True)

def main():
    if "--sync-map" in sys.argv:
        sync_mapping(days=5)
        return

    # Start background scheduler for daily 00:00 midnight duty sync
    scheduler_thread = threading.Thread(target=run_midnight_sync_scheduler, daemon=True)
    scheduler_thread.start()

    TARGET_INTERVAL = 36.5  # 3600 / 36.5 = ~98.6 req/hr, strictly within 100/hr limit
    print(f"Starting IstanbulBizim Fleet Feeder (polling every {TARGET_INTERVAL}s cycle to respect 100 req/hr)...", flush=True)
    while True:
        cycle_start = time.time()
        try:
            buses = fetch_iett_fleet()
            if buses:
                push_to_worker(buses)
        except Exception as err:
            print(f"[{time.strftime('%X')}] Error in feeder: {err}", flush=True)

        elapsed = time.time() - cycle_start
        sleep_time = max(1.0, TARGET_INTERVAL - elapsed)
        time.sleep(sleep_time)

if __name__ == "__main__":
    main()
