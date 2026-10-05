#!/usr/bin/env python3
"""
feeder.py - Optional local background feeder for IstanbulBizim Live.
Polls İETT fleet GPS directly from this machine (respecting the 100/hr limit)
and pushes updates directly to the Cloudflare Worker KV.
"""

import os
import time
import json
import subprocess
import urllib.request

WORKER_URL = os.environ.get("WORKER_URL", "https://istanbulbizim-live.workers.dev")
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
        import ssl
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
        print(f"Error fetching from IETT: {e}")
        return None

def sync_mapping(days=3):
    import datetime, ssl
    print(f"[{time.strftime('%X')}] Syncing door-to-line assignments from IETT ibb360 (last {days} days)...")
    ctx = ssl._create_unverified_context()
    headers = {
        "Content-Type": "text/xml; charset=utf-8",
        "SOAPAction": '"http://tempuri.org/GetIettArsivGorev_json"',
        "User-Agent": "Mozilla/5.0"
    }
    base = datetime.date.today() - datetime.timedelta(days=1)
    line_to_doors = {}

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
            with urllib.request.urlopen(req, context=ctx, timeout=30) as res:
                txt = res.read().decode("utf-8")
                s = txt.find("<GetIettArsivGorev_jsonResult>")
                e = txt.find("</GetIettArsivGorev_jsonResult>")
                if s != -1 and e != -1:
                    day_data = json.loads(txt[s+len("<GetIettArsivGorev_jsonResult>"):e])
                    for r in day_data:
                        k = r.get("SKAPINUMARA")
                        h = r.get("SHATKODU")
                        if k and h:
                            line_to_doors.setdefault(h, set()).add(k)
                    print(f"   -> {dt}: {len(day_data)} tasks loaded")
        except Exception as err:
            print(f"   -> {dt} error: {err}")

    dict_map = {k: sorted(list(v)) for k, v in line_to_doors.items()}
    total_doors = sum(len(v) for v in dict_map.values())
    print(f"[{time.strftime('%X')}] Compiled {len(dict_map)} lines with {total_doors} door number mappings.")

    # Push to worker KV
    try:
        payload = json.dumps(dict_map).encode("utf-8")
        req = urllib.request.Request(WORKER_MAP_URL, data=payload, headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, context=ctx, timeout=20) as res:
            res_data = json.loads(res.read().decode("utf-8"))
            print(f"[{time.strftime('%X')}] Successfully pushed mapping to Worker KV: {res_data}")
    except Exception as e:
        print(f"Error pushing mapping to Worker: {e}")

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

    payload = json.dumps({"buses": cleaned}).encode("utf-8")
    req = urllib.request.Request(WORKER_FEED_URL, data=payload, headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
    try:
        import ssl
        ctx = ssl._create_unverified_context()
        with urllib.request.urlopen(req, context=ctx, timeout=15) as res:
            result = json.loads(res.read().decode("utf-8"))
            print(f"[{time.strftime('%X')}] Successfully pushed {result.get('count')} buses to Cloudflare Worker.", flush=True)
    except Exception as e:
        print(f"Error pushing to Worker: {e}", flush=True)

def main():
    import sys
    if "--sync-map" in sys.argv:
        sync_mapping(days=5)
        return

    print("Starting IstanbulBizim Fleet Feeder (polling every 40s to respect 90 req/hr)...", flush=True)
    while True:
        try:
            buses = fetch_iett_fleet()
            if buses:
                push_to_worker(buses)
        except Exception as err:
            print(f"[{time.strftime('%X')}] Error in feeder: {err}", flush=True)
        time.sleep(40.0)

if __name__ == "__main__":
    main()
