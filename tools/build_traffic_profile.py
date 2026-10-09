#!/usr/bin/env python3
"""
build_traffic_profile.py — turns the IBB "Saatlik Trafik Yoğunluk Veri Seti" (monthly CSVs) into a
compact typical-speed profile (src/traffic_profile.json) that the ETA engine uses as its historical prior.

    python3 tools/build_traffic_profile.py                       # newest 3 monthly files from data.ibb.gov.tr
    python3 tools/build_traffic_profile.py --months 6
    python3 tools/build_traffic_profile.py --csv traffic_density_202501.csv [--csv other.csv ...]

CSV columns (per IBB): DATE_TIME, LATITUDE, LONGITUDE, GEOHASH, MINIMUM_SPEED, MAXIMUM_SPEED,
AVERAGE_SPEED, NUMBER_OF_VEHICLES. Files are ~110 MB each and are STREAMED (no full load).

Output: {"v":1,"source":...,"factor":0.8,"cells":{geohash5:[[24 weekday],[24 saturday],[24 sunday]]},"city":[[24],[24],[24]]}
Speeds are vehicle-weighted averages of AVERAGE_SPEED converted to a bus-equivalent km/h (x factor).
0 means "not enough samples" and the engine falls back to the city-wide value for that hour.
Then rebuild the Worker:  python3 build.py && npx wrangler deploy
"""
import argparse
import csv
import io
import json
import os
import ssl
import sys
import urllib.request
from datetime import datetime

CKAN = "https://data.ibb.gov.tr/api/3/action/package_show?id=hourly-traffic-density-data-set"
BUS_FACTOR = 0.8      # buses are slower than the mixed traffic these files describe (dwell, lane changes)
MIN_SAMPLES = 40      # per (cell, daytype, hour) before we trust it
GH_PREC = 5


def parse_dt(s):
    s = s.strip().replace("T", " ")[:19]
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%d.%m.%Y %H:%M:%S", "%d/%m/%Y %H:%M:%S"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    return None


def num(v):
    try:
        return float(str(v).replace(",", "."))
    except ValueError:
        return None


def open_stream(src):
    if os.path.exists(src):
        return open(src, "r", encoding="utf-8", errors="replace", newline="")
    req = urllib.request.Request(src, headers={"User-Agent": "Mozilla/5.0"})
    res = urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=120)
    return io.TextIOWrapper(res, encoding="utf-8", errors="replace", newline="")


def latest_urls(n):
    req = urllib.request.Request(CKAN, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=60) as r:
        res = json.load(r)["result"]["resources"]
    csvs = [x for x in res if str(x.get("format", "")).lower() == "csv" and x.get("url")]
    csvs.sort(key=lambda x: x["url"])  # traffic_density_YYYYMM.csv sorts chronologically
    return [x["url"] for x in csvs[-n:]]


def accumulate(stream, cells, city):
    rd = csv.reader(stream)
    header = [h.strip().upper() for h in next(rd)]
    ix = {h: i for i, h in enumerate(header)}
    for need in ("DATE_TIME", "GEOHASH", "AVERAGE_SPEED", "NUMBER_OF_VEHICLES"):
        if need not in ix:
            sys.exit(f"missing column {need}; got {header}")
    rows = 0
    for row in rd:
        try:
            dt = parse_dt(row[ix["DATE_TIME"]])
            sp = num(row[ix["AVERAGE_SPEED"]])
            nv = num(row[ix["NUMBER_OF_VEHICLES"]])
            gh = row[ix["GEOHASH"]].strip().lower()[:GH_PREC]
        except IndexError:
            continue
        if dt is None or sp is None or nv is None or nv <= 0 or sp <= 0 or sp > 140 or len(gh) < GH_PREC:
            continue
        di = 2 if dt.weekday() == 6 else 1 if dt.weekday() == 5 else 0
        for tbl, key in ((cells, gh), (city, "*")):
            slot = tbl.setdefault(key, [[[0.0, 0.0, 0] for _ in range(24)] for _ in range(3)])[di][dt.hour]
            slot[0] += sp * nv
            slot[1] += nv
            slot[2] += 1
        rows += 1
    return rows


def finish(tbl, floor):
    out = {}
    for key, days in tbl.items():
        o = []
        for d in days:
            o.append([int(round(s / w * BUS_FACTOR)) if n >= floor and w > 0 else 0 for s, w, n in d])
        if any(any(x) for x in o):
            out[key] = o
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", action="append", help="local CSV path or URL (repeatable)")
    ap.add_argument("--months", type=int, default=3)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "traffic_profile.json"))
    a = ap.parse_args()

    sources = a.csv or latest_urls(a.months)
    print("sources:", *sources, sep="\n  ")
    cells, city = {}, {}
    total = 0
    for src in sources:
        with open_stream(src) as f:
            n = accumulate(f, cells, city)
        print(f"  {n:,} rows from {src}")
        total += n
    if not total:
        sys.exit("no usable rows")

    city_tbl = finish(city, 20)
    if "*" not in city_tbl:
        sys.exit("not enough samples to build a city-wide profile")
    city_out = city_tbl["*"]
    # a day type / hour with too few samples inherits the weekday value, then a neutral 25 km/h
    for di in (1, 2):
        for h in range(24):
            if city_out[di][h] == 0:
                city_out[di][h] = city_out[0][h]
    for di in range(3):
        for h in range(24):
            if city_out[di][h] == 0:
                city_out[di][h] = 25
    cells_out = finish(cells, MIN_SAMPLES)
    # fill 0s in each cell with the city value so lookups never return "unknown" mid-profile
    for key, days in cells_out.items():
        for di in range(3):
            for h in range(24):
                if days[di][h] == 0:
                    days[di][h] = city_out[di][h]
    doc = {"v": 1, "source": "IBB Saatlik Trafik Yoğunluk Veri Seti", "factor": BUS_FACTOR,
           "geohash_precision": GH_PREC, "rows": total, "sources": [os.path.basename(s) for s in sources],
           "cells": cells_out, "city": city_out}
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
    print(f"wrote {os.path.abspath(a.out)}: {len(cells_out)} cells, {os.path.getsize(a.out)/1024:.0f} KB")
    print("city weekday km/h by hour:", city_out[0])


if __name__ == "__main__":
    main()
