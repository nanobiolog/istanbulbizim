#!/usr/bin/env python3
"""
verify_apis.py — checks that every upstream API İstanbul Bizim depends on returns REAL, FRESH data.

Run it in your own terminal (needs internet; stdlib only):

    python3 tools/verify_apis.py                 # upstream IBB/IETT/Metro checks + deployed Worker checks
    python3 tools/verify_apis.py --no-live-fleet # skip the one IETT fleet call (quota: 100 req/h, the feeder uses ~99)
    python3 tools/verify_apis.py --worker https://istanbulbizim.nano-carbay.workers.dev

For every check it prints PASS/FAIL, latency, what it saw, and writes tools/api_report.json
(with one raw sample record per API) so you can eyeball the real payloads.
Exit code is 0 only if every check passes.
"""
import argparse
import json
import re
import ssl
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from html import unescape

TZ = timezone(timedelta(hours=3))
NS = "http://tempuri.org/"
IETT = "https://api.ibb.gov.tr/iett/FiloDurum/SeferGerceklesme.asmx"
IBB = "https://api.ibb.gov.tr/iett/ibb/ibb.asmx"
TIMETABLE = "https://api.ibb.gov.tr/iett/UlasimAnaVeri/PlanlananSeferSaati.asmx"
DUYURU = "https://api.ibb.gov.tr/iett/UlasimDinamikVeri/Duyurular.asmx"
METRO = "https://api.ibb.gov.tr/MetroIstanbul/api/MetroMobile/V2"
CKAN = "https://data.ibb.gov.tr/api/3/action"
UA = {"User-Agent": "Mozilla/5.0 (IstanbulBizim verify_apis)"}
CTX = ssl.create_default_context()

results = []


def http(url, data=None, headers=None, method=None, timeout=25):
    h = dict(UA)
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, context=CTX, timeout=timeout) as r:
        return r.status, r.read().decode("utf-8", "replace")


def soap(url, method, args=None):
    inner = "".join(f"<{k}>{v}</{k}>" for k, v in (args or {}).items())
    body = (
        '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        f'<soap:Body><{method} xmlns="{NS}">{inner}</{method}></soap:Body></soap:Envelope>'
    )
    status, xml = http(
        url, body.encode("utf-8"),
        {"Content-Type": "text/xml; charset=utf-8", "SOAPAction": f'"{NS}{method}"'},
    )
    a, b = xml.find(f"<{method}Result>"), xml.find(f"</{method}Result>")
    if a < 0 or b < 0:
        raise RuntimeError(f"no <{method}Result> (HTTP {status}): {xml[:200]}")
    return xml[a + len(method) + 8:b]


def soap_json(url, method, args=None):
    return json.loads(unescape(soap(url, method, args)))


def check(name, fn):
    t0 = time.time()
    try:
        ok, detail, sample = fn()
    except Exception as e:  # noqa: BLE001
        ok, detail, sample = False, f"{type(e).__name__}: {e}"[:300], None
    ms = int((time.time() - t0) * 1000)
    results.append({"name": name, "ok": bool(ok), "ms": ms, "detail": detail, "sample": sample})
    print(f"{'PASS' if ok else 'FAIL'}  {name:<52} {ms:>5} ms  {detail}")


def secs(hms):
    p = str(hms).split(":")
    return int(p[0]) * 3600 + int(p[1]) * 60 + int(p[2]) if len(p) >= 3 else None


# ── upstream checks ──────────────────────────────────────────────────────────
def fleet():
    rows = soap_json(IETT, "GetFiloAracKonum_json")
    need = ["KapiNo", "Enlem", "Boylam", "Hiz", "Saat"]
    if not rows or not all(k in rows[0] for k in need):
        return False, f"unexpected schema: {list(rows[0].keys()) if rows else 'empty'}", rows[:1]
    now = datetime.now(TZ)
    now_s = now.hour * 3600 + now.minute * 60 + now.second
    ages, inb = [], 0
    for r in rows:
        try:
            lat, lon = float(str(r["Enlem"]).replace(",", ".")), float(str(r["Boylam"]).replace(",", "."))
            if 40.5 < lat < 41.6 and 27.8 < lon < 29.8:
                inb += 1
            s = secs(r["Saat"])
            if s is not None:
                ages.append((now_s - s) % 86400)
        except Exception:  # noqa: BLE001
            pass
    ages.sort()
    med = ages[len(ages) // 2] if ages else 99999
    fresh = sum(1 for a in ages if a <= 180) / max(1, len(ages))
    ok = len(rows) > 1000 and inb / len(rows) > 0.95 and med < 300
    return ok, f"vehicles={len(rows)}, in_bounds={inb}, median_fix_age={med}s, fix<=180s={fresh:.0%}", rows[:1]


def hat_oto():
    rows = soap_json(IETT, "GetHatOtoKonum_json", {"HatKodu": "15B"})
    if not isinstance(rows, list):
        return False, "not a list", None
    low = [{k.lower(): v for k, v in r.items()} for r in rows[:1]]
    ok = (not rows) or all(k in low[0] for k in ("kapino", "enlem", "boylam"))
    return ok, f"rows={len(rows)} (0 is legal at night)", rows[:1]


def route():
    xml = unescape(soap(IBB, "DurakDetay_GYY", {"hat_kodu": "15B"}))
    tables = re.findall(r"<Table>([\s\S]*?)</Table>", xml)
    if not tables:
        # some deployments return the XML as the full SOAP result; look in raw
        return False, "no <Table> rows", xml[:200]
    tag = lambda row, t: (re.search(f"<{t}>([^<]*)</{t}>", row, re.I) or [None, ""])[1]
    dirs = {tag(r, "YON") for r in tables}
    lat = [float(tag(r, "YKOORDINATI").replace(",", ".")) for r in tables if tag(r, "YKOORDINATI")]
    ok = len(tables) > 20 and all(40 < x < 42 for x in lat) and {"D", "G"} <= dirs
    return ok, f"stops={len(tables)}, directions={sorted(dirs)}", tables[0][:300]


def hat_servisi():
    xml = unescape(soap(IBB, "HatServisi_GYY", {"hat_kodu": "15B"}))
    m = re.search(r"<HAT_ADI>([^<]*)</HAT_ADI>", xml, re.I)
    return bool(m), f"HAT_ADI={m.group(1) if m else None}", None


def timetable():
    rows = soap_json(TIMETABLE, "GetPlanlananSeferSaati_json", {"HatKodu": "15B"})
    need = ["DT", "SYON", "SGUNTIPI"]
    if not rows or not all(k in rows[0] for k in need):
        return False, f"schema: {list(rows[0].keys()) if rows else 'empty'}", rows[:1]
    days = sorted({r["SGUNTIPI"] for r in rows})
    dirs = sorted({r["SYON"] for r in rows})
    return len(rows) > 20 and set(days) <= {"I", "C", "P"}, f"rows={len(rows)}, day_types={days}, dirs={dirs}", rows[:1]


def duyuru():
    rows = soap_json(DUYURU, "GetDuyurular_json")
    return isinstance(rows, list), f"rows={len(rows)}", rows[:1]


def metro_call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    _, txt = http(f"{METRO}/{path}", data, {"Content-Type": "application/json", "Accept": "application/json"}, "POST" if body is not None else "GET")
    j = json.loads(txt)
    if isinstance(j, dict) and j.get("Success") is False:
        raise RuntimeError(str(j.get("Error") or j)[:200])
    return j.get("Data", j) if isinstance(j, dict) else j


def metro():
    lines = metro_call("GetLines")
    names = [str(next((v for k, v in l.items() if k.lower() in ("name", "shortname", "code", "linename")), "")) for l in lines]
    return len(lines) > 5, f"lines={len(lines)}: {', '.join(names[:12])}", lines[:1]


def metro_tt():
    lines = metro_call("GetLines")
    line = next(l for l in lines if any(str(v).upper().replace(" ", "") == "M2" for v in l.values()))
    lid = next(v for k, v in line.items() if k.lower() in ("id", "lineid"))
    stations = metro_call(f"GetStationById/{lid}")
    dirs = metro_call(f"GetDirectionById/{lid}")
    st = stations[0]
    sid = next(v for k, v in st.items() if k.lower() in ("id", "stationid"))
    did = next(v for k, v in dirs[0].items() if k.lower() in ("directionid", "id"))
    tt = metro_call("GetTimeTable", {"boardingStationId": sid, "directionId": did})
    times = re.findall(r'"(\d{1,2}:\d{2})', json.dumps(tt))
    return len(times) > 20, f"M2 lineId={lid}, stations={len(stations)}, directions={len(dirs)}, times={len(times)}", {"directions": dirs[:2], "timetable_head": json.dumps(tt)[:400]}


def ckan():
    _, txt = http(f"{CKAN}/package_show?id=hourly-traffic-density-data-set")
    res = json.loads(txt)["result"]["resources"]
    last = res[-1]
    return len(res) > 10, f"resources={len(res)}, newest={last.get('name')} ({last.get('last_modified') or last.get('created')})", {"url": last.get("url")}


# ── deployed Worker checks ───────────────────────────────────────────────────
def worker_get(base, path):
    _, txt = http(base + path)
    return json.loads(txt)


def w_buses(base):
    d = worker_get(base, "/buses")
    age = (time.time() * 1000 - d["updated_at"]) / 1000
    b = d["buses"]
    with_a = sum(1 for x in b if "a" in x)
    return d["count"] > 1000 and age < 180 and with_a / len(b) > 0.9, f"count={d['count']}, snapshot_age={age:.0f}s, buses_with_age_field={with_a}/{len(b)}, with_heading={sum(1 for x in b if 'h' in x)}", b[:1]


def w_traffic(base):
    d = worker_get(base, "/traffic")
    return len(d["cells"]) > 100, f"cells={len(d['cells'])}, city={d['city']}", d["cells"][:2]


def w_line(base):
    d = worker_get(base, "/line?code=15B")
    withe = [b for b in d["buses"] if "next_stop_eta_sec" in b]
    ok = len(d["directions"]) > 0 and (len(d["buses"]) == 0 or len(withe) > 0)
    return ok, f"buses={len(d['buses'])}, with_route_eta={len(withe)}, traffic={d.get('traffic')}", withe[:1]


def w_timetable_bus(base):
    d = worker_get(base, "/timetable?line=15B")
    return d.get("official") is True and len(d["entries"]) > 20, f"entries={len(d['entries'])}, official={d.get('official')}", d["entries"][:1]


def w_timetable_metro(base):
    d = worker_get(base, "/timetable?line=M2")
    est = sum(1 for e in d["entries"] if e.get("estimated"))
    return d.get("official") is True, f"official={d.get('official')}, entries={len(d['entries'])}, estimated_entries={est}, note={d.get('note')}", d["entries"][:1]


def w_stop(base):
    d = worker_get(base, "/stop/arrivals?code=100022")
    return "arrivals" in d, f"arrivals={len(d['arrivals'])}, candidate_lines={d['candidate_lines']}, skipped={d['skipped_lines']}", d["arrivals"][:1]


def w_boot(base):
    d = worker_get(base, "/bootstrap")
    return d.get("has_key") is True, f"has_key={d.get('has_key')}, fleet={d.get('fleet')}", {k: d[k] for k in ("tile_proxy", "min_poll_ms")}


def w_diag(base):
    d = worker_get(base, "/diag")
    bad = [r["name"] for r in d["results"] if not r["ok"]]
    return not bad, f"{d['passed']}/{d['total']} passed; failing={bad}", None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--worker", default="https://istanbulbizim.nano-carbay.workers.dev")
    ap.add_argument("--no-live-fleet", action="store_true", help="skip the IETT fleet call (quota 100/h)")
    ap.add_argument("--no-worker", action="store_true")
    a = ap.parse_args()

    print(f"== Upstream APIs ({datetime.now(TZ):%Y-%m-%d %H:%M:%S} Istanbul) ==")
    if not a.no_live_fleet:
        check("IETT GetFiloAracKonum_json (fleet GPS)", fleet)
    check("IETT GetHatOtoKonum_json (line vehicles)", hat_oto)
    check("IBB DurakDetay_GYY (route + stops)", route)
    check("IBB HatServisi_GYY (line name)", hat_servisi)
    check("IBB GetPlanlananSeferSaati_json (bus timetable)", timetable)
    check("IBB GetDuyurular_json (announcements)", duyuru)
    check("Metro İstanbul GetLines", metro)
    check("Metro İstanbul GetTimeTable (M2)", metro_tt)
    check("data.ibb.gov.tr CKAN hourly traffic density", ckan)

    if not a.no_worker:
        print(f"\n== Deployed Worker: {a.worker} ==")
        for name, fn in [
            ("Worker /bootstrap", w_boot), ("Worker /buses", w_buses), ("Worker /traffic", w_traffic),
            ("Worker /line?code=15B (ETA fields)", w_line), ("Worker /timetable bus", w_timetable_bus),
            ("Worker /timetable M2 (official)", w_timetable_metro), ("Worker /stop/arrivals", w_stop),
            ("Worker /diag (edge self-check)", w_diag),
        ]:
            check(name, lambda fn=fn: fn(a.worker))

    passed = sum(r["ok"] for r in results)
    print(f"\n{passed}/{len(results)} checks passed")
    out = "tools/api_report.json" if __file__.endswith("tools/verify_apis.py") else "api_report.json"
    try:
        with open(out, "w", encoding="utf-8") as f:
            json.dump({"generated_at": datetime.now(TZ).isoformat(), "results": results}, f, ensure_ascii=False, indent=2)
        print(f"report written to {out}")
    except OSError:
        pass
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
