// ── Rail: timetable-derived live train schedules (Metro İstanbul + Marmaray) ─────
// Neither Metro İstanbul nor TCDD publish train GPS. The most accurate public signal is the
// official per-station departure timetable (Metro İstanbul GetTimeTable). For each line we read
// the origin timetable of every service pattern plus a sample of intermediate stations, recover
// the station-to-station running offsets from them, and ship a compact trip list. Clients place
// every train on the map from (trip departure + offset) against the clock, so positions match the
// official timetable to the minute without any per-second polling. Marmaray is not in the Metro
// İstanbul API, so it is modelled from TCDD's published plan and flagged as an estimate.

const RAIL_SCHEMA = 1;
const RAIL_SERVICE_DAY_START_H = 3; // timetables roll over at 03:00, after the last night train
const RAIL_MAX_SAMPLES_PER_DIR = 14; // keeps a cold build under the 50-subrequest Worker limit
const RAIL_EXTRA_PATTERNS = 3;      // short-turn service patterns read per line

const railMemo = new Map();      // `${code}:${dateKey}` -> schedule
const railFailedAt = new Map();  // code -> last failed cold build (cron backs off 15 min)
const railInflight = new Map();  // dedupes concurrent cold builds inside one isolate
let railStatusMemo = { at: 0, data: null };

function railProfile(code) {
  const c = String(code || "").toUpperCase();
  if (c === "B1" || c === "MARMARAY") return { dwell: 45, loss: 30, cruiseKmh: 80, type: "marmaray" };
  if (c.startsWith("TF")) return { dwell: 40, loss: 0, cruiseKmh: 18, type: "cable" };
  if (c.startsWith("F")) return { dwell: 40, loss: 0, cruiseKmh: 25, type: "funicular" };
  if (c.startsWith("T")) return { dwell: 20, loss: 15, cruiseKmh: 30, type: "tram" };
  if (c === "M5" || c === "M8" || c === "M11") return { dwell: 25, loss: 25, cruiseKmh: 62, type: "driverless" };
  if (c.startsWith("M1")) return { dwell: 25, loss: 22, cruiseKmh: 50, type: "light_metro" };
  return { dwell: 25, loss: 25, cruiseKmh: 58, type: "metro" };
}

function railHaversine(a, b) {
  const R = 6371000;
  const p1 = a.lat * Math.PI / 180, p2 = b.lat * Math.PI / 180;
  const dp = p2 - p1, dl = (b.lon - a.lon) * Math.PI / 180;
  const h = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

/** Prior cumulative departure offsets (s) along `stations` in travel order. */
function railPriorOffsets(stations, prof) {
  const out = [0];
  for (let i = 1; i < stations.length; i++) {
    const d = railHaversine(stations[i - 1], stations[i]);
    out.push(out[i - 1] + prof.dwell + prof.loss + d / (prof.cruiseKmh / 3.6));
  }
  return out;
}

/** Istanbul service day: before 03:00 still belongs to the previous day's timetable. */
function railServiceDay(ms) {
  const local = new Date((ms || Date.now()) + 3 * 3600 * 1000);
  const secOfDay = local.getUTCHours() * 3600 + local.getUTCMinutes() * 60 + local.getUTCSeconds();
  const rolled = local.getUTCHours() < RAIL_SERVICE_DAY_START_H;
  const svc = rolled ? new Date(local.getTime() - 86400 * 1000) : local;
  const dow = svc.getUTCDay();
  return {
    dateKey: svc.toISOString().slice(0, 10),
    dow,
    dayType: dow === 0 ? "P" : dow === 6 ? "C" : "I",
    nowSec: rolled ? secOfDay + 86400 : secOfDay
  };
}

/** "HH:MM" -> seconds of the service day (00:00-02:59 belong to the end of the day). */
function railTimeToSec(hhmm) {
  const m = /^(\d{1,2}):(\d{2})/.exec(String(hhmm || "").trim());
  if (!m) return null;
  let s = (+m[1]) * 3600 + (+m[2]) * 60;
  if (+m[1] < RAIL_SERVICE_DAY_START_H) s += 86400;
  return s;
}

function railTimesFrom(data) {
  const set = new Set();
  for (const info of extractTimeInfos(data)) {
    for (const t of info.times) {
      const s = railTimeToSec(t);
      if (s !== null) set.add(s);
    }
  }
  return Array.from(set).sort((a, b) => a - b);
}

/**
 * Running offset from the origin to a station, recovered from the two departure lists.
 * Every origin departure votes for (nearest station departure − origin departure) near `guess`;
 * the true offset is shared by almost all trips while mismatches spread over the headway,
 * so the densest 60 s window wins. Returns null when there is not enough agreement.
 */
function railMatchOffset(origin, station, guess, win) {
  if (!origin.length || !station.length) return null;
  const votes = [];
  let j = 0;
  for (const o of origin) {
    const lo = o + guess - win, hi = o + guess + win;
    while (j < station.length && station[j] < lo) j++;
    for (let k = j; k < station.length && station[k] <= hi; k++) votes.push(station[k] - o);
  }
  if (votes.length < 3) return null;
  votes.sort((a, b) => a - b);
  let best = 0, bestLo = 0, hiIdx = 0;
  for (let lo = 0; lo < votes.length; lo++) {
    while (hiIdx < votes.length && votes[hiIdx] - votes[lo] <= 60) hiIdx++;
    if (hiIdx - lo > best) { best = hiIdx - lo; bestLo = lo; }
  }
  const support = best / Math.min(origin.length, station.length);
  if (support < 0.35) return null;
  return medianOf(votes.slice(bestLo, bestLo + best));
}

/**
 * Offsets for every travel position given timetable samples (pos -> sorted secs).
 * Anchors are chained so each guess only has to bridge a few stations of prior error,
 * then non-sampled stations are interpolated on the prior time scale.
 */
function railDeriveOffsets(prior, originPos, samples) {
  const n = prior.length;
  const anchors = [[originPos, 0]];
  const positions = Array.from(samples.keys()).filter(p => p > originPos).sort((a, b) => a - b);
  let matched = 0;
  for (const p of positions) {
    const [ap, ao] = anchors[anchors.length - 1];
    const guess = ao + (prior[p] - prior[ap]);
    const win = Math.max(150, Math.min(420, (prior[p] - prior[ap]) * 0.35 + 120));
    const off = railMatchOffset(samples.get(originPos), samples.get(p), guess, win);
    if (off !== null && off > ao) { anchors.push([p, off]); matched++; }
  }
  const offsets = new Array(n).fill(0);
  for (let p = 0; p < n; p++) {
    let a = null, b = null;
    for (const an of anchors) {
      if (an[0] <= p) a = an;
      if (an[0] >= p && b === null) b = an;
    }
    if (a && b && b[0] !== a[0]) {
      const span = prior[b[0]] - prior[a[0]];
      const f = span > 0 ? (prior[p] - prior[a[0]]) / span : 0;
      offsets[p] = a[1] + (b[1] - a[1]) * f;
    } else if (a) {
      offsets[p] = a[1] + (prior[p] - prior[a[0]]);
    } else {
      offsets[p] = b[1] - (prior[b[0]] - prior[p]);
    }
  }
  for (let p = 1; p < n; p++) if (offsets[p] <= offsets[p - 1]) offsets[p] = offsets[p - 1] + 30;
  return { offsets: offsets.map(x => Math.round(x)), matched };
}

function railSplitEnds(name) {
  const s = String(name || "");
  let parts = s.split(/\s*(?:->|→|=>|➔|>)\s*/).filter(Boolean);
  if (parts.length !== 2) parts = s.split(/\s+[-–—]\s+/).filter(Boolean);
  if (parts.length !== 2) parts = s.split(/\s*[-–—]\s*/).filter(Boolean);
  return parts.length >= 2 ? [parts[0], parts[parts.length - 1]] : null;
}

function railFindStation(stations, name) {
  const want = plainName(name);
  if (!want) return -1;
  let idx = stations.findIndex(s => plainName(s.name) === want);
  if (idx >= 0) return idx;
  idx = stations.findIndex(s => { const p = plainName(s.name); return p && (p.includes(want) || want.includes(p)); });
  if (idx >= 0) return idx;
  const head = want.slice(0, 5);
  return head.length >= 4 ? stations.findIndex(s => plainName(s.name).startsWith(head)) : -1;
}

async function railTimed(promise, ms) {
  let t;
  try {
    return await Promise.race([promise, new Promise((_, rej) => { t = setTimeout(() => rej(new Error("timeout")), ms); })]);
  } finally { clearTimeout(t); }
}

async function railTimetable(stationId, directionId) {
  const data = await railTimed(metroFetch("GetTimeTable", "POST", { boardingStationId: stationId, directionId }), 9000);
  return railTimesFrom(data);
}

async function railPool(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const i = next++;
      try { out[i] = await fn(items[i]); } catch (e) { out[i] = null; }
    }
  });
  await Promise.all(workers);
  return out;
}

function railStationsFor(code) {
  const list = (typeof METRO_STATIONS !== "undefined" && METRO_STATIONS[code]) || [];
  return list.map(s => ({ name: s.name, lat: s.lat, lon: s.lon }));
}

/** Builds one line's schedule from the official Metro İstanbul timetables. */
async function buildMetroRailSchedule(code, env, day) {
  const stations = railStationsFor(code);
  if (stations.length < 2) throw new Error(`No stations for ${code}`);
  const prof = railProfile(code);
  const meta = await getMetroLineMeta(code, env);
  if (!meta.directions.length || !meta.stations.length) throw new Error("Metro meta incomplete");

  const apiIdAt = new Array(stations.length).fill(undefined);
  meta.stations.forEach((s, i) => {
    let idx = railFindStation(stations, s.name);
    if (idx < 0 && meta.stations.length === stations.length) idx = i;
    if (idx >= 0 && apiIdAt[idx] === undefined) apiIdAt[idx] = s.id;
  });

  // Classify service patterns by travel sense and span on our station order.
  const patterns = [];
  meta.directions.forEach((d, i) => {
    const ends = railSplitEnds(d.name);
    let a = ends ? railFindStation(stations, ends[0]) : -1;
    let b = ends ? railFindStation(stations, ends[1]) : -1;
    if (a < 0 || b < 0 || a === b) {
      if (i > 1) return;
      a = i === 0 ? 0 : stations.length - 1;
      b = i === 0 ? stations.length - 1 : 0;
    }
    patterns.push({ id: d.id, name: d.name, a, b, fwd: a < b, span: Math.abs(b - a) });
  });

  const directions = [];
  let calls = 0;
  for (const fwd of [true, false]) {
    const same = patterns.filter(p => p.fwd === fwd).sort((x, y) => y.span - x.span);
    if (!same.length) continue;
    const main = same[0];
    const n = stations.length;
    const order = fwd ? stations : stations.slice().reverse();
    const pos = idx => (fwd ? idx : n - 1 - idx);
    const prior = railPriorOffsets(order, prof);
    const originPos = pos(main.a), endPos = pos(main.b);

    // Origin + evenly spaced intermediate stations (the terminus has no departures).
    const want = [];
    for (let p = originPos + 1; p < endPos; p++) want.push(p);
    const step = Math.max(1, Math.ceil(want.length / RAIL_MAX_SAMPLES_PER_DIR));
    const picked = [originPos].concat(want.filter((_, k) => k % step === step - 1 || k === want.length - 1));
    const jobs = picked
      .map(p => ({ p, sid: apiIdAt[fwd ? p : n - 1 - p] }))
      .filter(j => j.sid !== undefined);
    calls += jobs.length;
    const results = await railPool(jobs, 6, j => railTimetable(j.sid, main.id));
    const samples = new Map();
    jobs.forEach((j, k) => { if (results[k] && results[k].length) samples.set(j.p, results[k]); });
    const originTimes = samples.get(originPos);
    if (!originTimes || !originTimes.length) continue;

    const { offsets, matched } = railDeriveOffsets(prior, originPos, samples);
    const trips = originTimes.map(t => [t, originPos, endPos]);

    // Short-turn patterns in the same sense: their own origin timetable, same running offsets.
    for (const sp of same.slice(1, 1 + RAIL_EXTRA_PATTERNS)) {
      const sid = apiIdAt[sp.a];
      if (sid === undefined) continue;
      calls++;
      let times = null;
      try { times = await railTimetable(sid, sp.id); } catch (e) { times = null; }
      if (!times) continue;
      const a = pos(sp.a), b = pos(sp.b);
      const mainAtA = new Set(originTimes.map(t => Math.round((t + offsets[a] - offsets[originPos]) / 60)));
      for (const t of times) if (!mainAtA.has(Math.round(t / 60))) trips.push([t, a, b]);
    }
    trips.sort((x, y) => x[0] - offsets[x[1]] - (y[0] - offsets[y[1]]));

    directions.push({
      dir: fwd ? "G" : "D",
      sense: fwd ? "fwd" : "rev",
      name: `${order[originPos].name} ➔ ${order[endPos].name}`,
      headsign: order[endPos].name,
      offsets,
      timetable_points: matched + 1,
      trips
    });
  }
  if (!directions.length) throw new Error("No timetable returned");

  return {
    v: RAIL_SCHEMA,
    line: code,
    service_date: day.dateKey,
    day_type: day.dayType,
    generated_at: Date.now(),
    official: true,
    source: "Metro İstanbul resmî istasyon tarifeleri (GetTimeTable)",
    note: "Konumlar resmî kalkış saatlerinden hesaplanır; anlık gecikmeler yansımaz.",
    dwell_s: prof.dwell,
    upstream_calls: calls,
    stations,
    directions
  };
}

// TCDD Taşımacılık published plan: Halkalı–Gebze every 15 min, Ataköy–Pendik short-turns
// interleaved (≈7.5 min between Ataköy and Pendik), 108 min end to end, Fri/Sat night extension.
const MARMARAY_PLAN = {
  runSec: 108 * 60,
  headway: 15 * 60,
  full: {
    G: { first: "05:58", last: "22:58", nightLast: "01:28" },
    D: { first: "06:05", last: "22:50", nightLast: "01:20" }
  },
  nightHeadway: 30 * 60,
  short: {
    from: "ATAKOY",
    to: "PENDIK",
    G: { first: "06:09", last: "21:54" },
    D: { first: "06:09", last: "20:39" }
  }
};

function buildMarmaraySchedule(day) {
  const stations = railStationsFor("B1");
  if (stations.length < 2) throw new Error("No Marmaray stations");
  const prof = railProfile("B1");
  const n = stations.length;
  const plan = MARMARAY_PLAN;
  const nightService = day.dow === 5 || day.dow === 6; // Fri→Sat and Sat→Sun nights
  const directions = [];
  for (const fwd of [true, false]) {
    const dir = fwd ? "G" : "D";
    const order = fwd ? stations : stations.slice().reverse();
    const prior = railPriorOffsets(order, prof);
    const scale = plan.runSec / prior[n - 1];
    const offsets = prior.map(x => Math.round(x * scale));
    const trips = [];
    const f = plan.full[dir];
    const first = railTimeToSec(f.first), last = railTimeToSec(f.last);
    for (let t = first; t <= last; t += plan.headway) trips.push([t, 0, n - 1]);
    if (nightService) {
      const nightLast = railTimeToSec(f.nightLast);
      for (let t = last + plan.nightHeadway; t <= nightLast; t += plan.nightHeadway) trips.push([t, 0, n - 1]);
    }
    const s = plan.short[dir];
    const ia = railFindStation(order, fwd ? plan.short.from : plan.short.to);
    const ib = railFindStation(order, fwd ? plan.short.to : plan.short.from);
    if (ia >= 0 && ib > ia) {
      for (let t = railTimeToSec(s.first); t <= railTimeToSec(s.last); t += plan.headway) trips.push([t, ia, ib]);
    }
    trips.sort((x, y) => x[0] - offsets[x[1]] - (y[0] - offsets[y[1]]));
    directions.push({
      dir,
      sense: fwd ? "fwd" : "rev",
      name: `${order[0].name} ➔ ${order[n - 1].name}`,
      headsign: order[n - 1].name,
      offsets,
      timetable_points: 2,
      trips
    });
  }
  return {
    v: RAIL_SCHEMA,
    line: "B1",
    service_date: day.dateKey,
    day_type: day.dayType,
    generated_at: Date.now(),
    official: false,
    source: "TCDD Taşımacılık yayımlanmış Marmaray sefer planı",
    note: "Marmaray için açık canlı konum verisi yok: konumlar ilk/son sefer ve 15 dk sefer aralığından hesaplanan tahminidir.",
    dwell_s: prof.dwell,
    upstream_calls: 0,
    stations,
    directions
  };
}

function railBearing(a, b) {
  const p1 = a.lat * Math.PI / 180, p2 = b.lat * Math.PI / 180, dl = (b.lon - a.lon) * Math.PI / 180;
  const y = Math.sin(dl) * Math.cos(p2);
  const x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl);
  return Math.round((Math.atan2(y, x) * 180 / Math.PI + 360) % 360);
}

/** Trains on the line at service second `now` (linear between stations; the app animates finer). */
function railPositionsAt(s, now) {
  const out = [];
  const n = s.stations.length;
  const dwell = s.dwell_s || 25;
  for (const d of s.directions) {
    const idx = p => (d.sense === "fwd" ? p : n - 1 - p);
    for (const [dep, a, b] of d.trips) {
      const base = dep - d.offsets[a];
      if (now < dep - dwell || now > base + d.offsets[b]) continue;
      let p = a;
      while (p < b && now >= base + d.offsets[p + 1] - dwell) p++;
      const from = s.stations[idx(p)];
      const to = s.stations[idx(Math.min(p + 1, b))];
      const depP = base + d.offsets[p];
      let f = 0, speed = 0;
      if (now >= depP && p < b) {
        const run = Math.max(1, d.offsets[p + 1] - dwell - d.offsets[p]);
        f = Math.min(1, (now - depP) / run);
        speed = Math.round(railHaversine(from, to) / run * 3.6);
      }
      const q = Math.min(p + 1, b);
      out.push({
        id: `${s.line}-${d.dir}-${dep}-${a}`,
        dir: d.dir,
        headsign: s.stations[idx(b)].name,
        lat: from.lat + (to.lat - from.lat) * f,
        lon: from.lon + (to.lon - from.lon) * f,
        next: to.name,
        next_eta_sec: Math.max(0, Math.round(base + d.offsets[q] - dwell - now)),
        terminal_eta_sec: Math.max(0, Math.round(base + d.offsets[b] - dwell - now)),
        stops_left: b - p,
        speed,
        bearing: railBearing(from, to)
      });
    }
  }
  return out;
}

function railCanonical(code) {
  const c = norm(code);
  return c === "MARMARAY" ? "B1" : c;
}

async function getRailSchedule(code, env, opts = {}) {
  const line = railCanonical(code);
  const day = railServiceDay();
  const key = `${line}:${day.dateKey}`;
  const mem = railMemo.get(key);
  if (mem) return mem;
  if (line === "B1") {
    const s = buildMarmaraySchedule(day);
    railMemo.set(key, s);
    return s;
  }
  const kvKey = `rail_v${RAIL_SCHEMA}:${key}`;
  // memory → edge cache → KV (one read per colo per day) → build (one KV write per line per day)
  const edge = await edgeGetJson(kvKey);
  if (edge && edge.directions && edge.directions.length) { railMemo.set(key, edge); return edge; }
  try {
    const c = await env.LIVE.get(kvKey, { type: "json", cacheTtl: 3600 });
    if (c && c.directions && c.directions.length) {
      railMemo.set(key, c);
      await edgePutJson(kvKey, c, 3 * 3600);
      return c;
    }
  } catch (e) { /* rebuild */ }
  if (opts.cacheOnly) return null;
  if (railInflight.has(key)) return railInflight.get(key);
  const p = (async () => {
    try {
      const s = await buildMetroRailSchedule(line, env, day);
      railMemo.set(key, s);
      if (railMemo.size > 60) railMemo.delete(railMemo.keys().next().value);
      await safeKvPut(env, kvKey, JSON.stringify(s), { expirationTtl: 30 * 3600 });
      await edgePutJson(kvKey, s, 3 * 3600);
      return s;
    } finally {
      railInflight.delete(key);
    }
  })();
  railInflight.set(key, p);
  return p;
}

function railLineFromText(s) {
  // Keep word boundaries (plainName strips them) so "SAAT 10" never reads as T1.
  const p = String(s || "").toLocaleUpperCase("tr-TR")
    .replace(/İ/g, "I").replace(/Ş/g, "S").replace(/Ğ/g, "G").replace(/Ü/g, "U").replace(/Ö/g, "O").replace(/Ç/g, "C");
  const m = /\b(TF[12]|M1[AB]|M\d{1,2}|T[1-5]|F[1-4]|B1)\b/.exec(p);
  if (m) return m[1];
  if (p.includes("MARMARAY")) return "B1";
  return "";
}

async function getRailStatus(env) {
  const now = Date.now();
  if (railStatusMemo.data && now - railStatusMemo.at < 120000) return railStatusMemo.data;
  let items = [];
  let ok = false;
  try {
    const rows = await railTimed(metroFetch("GetServiceStatuses"), 8000);
    ok = true;
    for (const r of Array.isArray(rows) ? rows : []) {
      const lineName = String(pickKey(r, ["LineName", "Line", "Name"]) || "");
      const desc = String(pickKey(r, ["Description", "Message", "Text", "Title"]) || "").trim();
      const active = pickKey(r, ["IsActive", "Active"]);
      if (active === false || !desc) continue;
      items.push({
        line: railLineFromText(lineName) || railLineFromText(desc),
        line_name: lineName,
        message: desc,
        updated: String(pickKey(r, ["UpdateDate", "UpdatedDate", "CreateDate", "Date"]) || "")
      });
    }
  } catch (e) {
    console.warn("GetServiceStatuses failed:", String(e));
  }
  const byLine = {};
  for (const it of items) if (it.line) (byLine[it.line] = byLine[it.line] || []).push(it);
  const data = { updated_at: now, ok, count: items.length, items, by_line: byLine, source: "Metro İstanbul GetServiceStatuses" };
  if (ok || !railStatusMemo.data) railStatusMemo = { at: now, data };
  return railStatusMemo.data;
}

async function handleRailSchedule(env, url) {
  const code = railCanonical(url.searchParams.get("line") || url.searchParams.get("code"));
  if (!code || code.length > 6) return json({ error: "line required (M2, T1, B1 …)" }, 400);
  if (!railStationsFor(code).length) return json({ error: `Unknown rail line ${code}` }, 404);
  const [schedule, status] = await Promise.all([
    getRailSchedule(code, env).catch(e => ({ error: String(e) })),
    getRailStatus(env).catch(() => null)
  ]);
  const disruptions = (status && status.by_line && status.by_line[code]) || [];
  if (!schedule || schedule.error) {
    return json({ line: code, error: schedule ? schedule.error : "unavailable", status: disruptions, server_time: Date.now() }, 503, { "cache-control": "no-store" });
  }
  return json(Object.assign({}, schedule, { status: disruptions, server_time: Date.now() }), 200, {
    "cache-control": "public, max-age=600, stale-while-revalidate=3600"
  });
}

async function handleRailStatus(env) {
  const s = await getRailStatus(env);
  return json(s, 200, { "cache-control": "public, max-age=120" });
}

/** Official departures at one station for both directions (Cache API, no KV writes). */
async function handleRailDepartures(env, url) {
  const code = railCanonical(url.searchParams.get("line"));
  const stationName = String(url.searchParams.get("station") || "");
  const stations = railStationsFor(code);
  const idx = railFindStation(stations, stationName);
  if (idx < 0) return json({ error: "station not found" }, 404);
  const day = railServiceDay();
  const cacheUrl = `https://cache.istanbulbizim.internal/rail/dep/${code}/${idx}/${day.dateKey}`;
  const cached = await getEdgeCache(cacheUrl);
  if (cached) {
    return new Response(cached, { headers: Object.assign({ "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=300" }, CORS) });
  }
  let body;
  if (code === "B1") {
    body = railDeparturesFromSchedule(buildMarmaraySchedule(day), idx, false);
  } else {
    try {
      const meta = await getMetroLineMeta(code, env);
      const api = meta.stations.find(s => railFindStation([stations[idx]], s.name) === 0);
      if (!api) throw new Error("station not in Metro API");
      const out = [];
      for (let di = 0; di < meta.directions.length; di++) {
        const d = meta.directions[di];
        const ends = railSplitEnds(d.name);
        let b = ends ? railFindStation(stations, ends[1]) : -1;
        if (b < 0) {
          if (di > 1) continue; // unknown short-turn pattern: cannot label its direction
          b = di === 0 ? stations.length - 1 : 0;
        }
        if (b === idx) continue; // terminus of this pattern: no departures
        let times = [];
        try { times = await railTimetable(api.id, d.id); } catch (e) { continue; }
        if (!times.length) continue;
        out.push({ dir: b > idx ? "G" : "D", pattern: d.name, headsign: stations[b].name, times });
      }
      if (!out.length) throw new Error("no departures");
      body = { line: code, station: stations[idx].name, service_date: day.dateKey, official: true, source: "Metro İstanbul GetTimeTable", departures: out };
    } catch (e) {
      const s = await getRailSchedule(code, env, { cacheOnly: true }).catch(() => null);
      if (!s) return json({ error: String(e) }, 503, { "cache-control": "no-store" });
      body = railDeparturesFromSchedule(s, idx, s.official);
    }
  }
  const raw = JSON.stringify(body);
  await putEdgeCache(cacheUrl, raw);
  return new Response(raw, { headers: Object.assign({ "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=300" }, CORS) });
}

function railDeparturesFromSchedule(s, idx, official) {
  const n = s.stations.length;
  const departures = s.directions.map(d => {
    const p = d.sense === "fwd" ? idx : n - 1 - idx;
    const times = [];
    for (const [dep, a, b] of d.trips) if (p >= a && p < b) times.push(dep + d.offsets[p] - d.offsets[a]);
    times.sort((x, y) => x - y);
    return { dir: d.dir, pattern: d.name, headsign: d.headsign, times };
  }).filter(d => d.times.length);
  return { line: s.line, station: s.stations[idx].name, service_date: s.service_date, official, source: s.source, departures };
}

/** Cron: build at most one missing line per tick so the day's schedules are warm by ~03:20. */
async function prewarmRail(env) {
  const day = railServiceDay();
  const lines = Object.keys(typeof METRO_STATIONS !== "undefined" ? METRO_STATIONS : {}).filter(c => c !== "B1");
  for (const code of lines) {
    const key = `${code}:${day.dateKey}`;
    if (railMemo.has(key)) continue;
    if (Date.now() - (railFailedAt.get(code) || 0) < 15 * 60000) continue;
    const cached = await getRailSchedule(code, env, { cacheOnly: true }).catch(() => null);
    if (cached) continue;
    await getRailSchedule(code, env).catch(e => {
      railFailedAt.set(code, Date.now());
      console.warn(`rail prewarm ${code}:`, String(e));
    });
    return code;
  }
  return null;
}
