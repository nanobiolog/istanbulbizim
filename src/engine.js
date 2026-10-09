// ─────────────────────────────────────────────────────────────────────────────
// engine.js — İstanbul Bizim engine layer (concatenated after worker.js by build.py)
//
//  • Live traffic field   : per-cell bus speeds derived from the live fleet (probe data)
//  • Historical prior     : hour/day-type speed prior (optional IBB-derived profile)
//  • Route-aware ETA      : bus → stop distance measured ALONG the route polyline,
//                           integrated cell-by-cell with live traffic + dwell + signals
//  • Heading tracking     : bearing from consecutive fleet snapshots (direction detection)
//  • Metro İstanbul       : official timetable client (GetLines/GetDirectionById/GetTimeTable)
//  • /diag                : edge-side self-check of every upstream the app depends on
//
// Shares scope with worker.js: soap(), json(), norm(), num(), esc(), unesc(), CORS,
// haversineMeters(), quota(), inMemoryBusesRaw, inMemoryMeta, METRO_API, BUS_STOPS,
// DOOR_LINES_MAP, TRAFFIC_PROFILE (may be null) are all defined there / by build.py.
// ─────────────────────────────────────────────────────────────────────────────

const CELL_LAT = 0.004;   // ≈ 443 m
const CELL_LON = 0.0053;  // ≈ 445 m at 41°N
const CELL_MUL = 10000;
const KX = 111320 * Math.cos(41 * Math.PI / 180);
const KY = 110540;

// Typical İstanbul bus speeds (km/h) by hour — SEED PRIOR used only where there is no live
// probe data nearby and no IBB-derived profile (tools/build_traffic_profile.py). Conservative
// estimates, not measurements.
const PRIOR_I = [31, 32, 33, 33, 32, 30, 26, 20, 16, 17, 19, 20, 20, 20, 20, 19, 17, 15, 14, 16, 20, 24, 27, 29];
const PRIOR_C = [30, 31, 32, 33, 32, 31, 29, 26, 23, 21, 20, 19, 19, 19, 19, 19, 19, 19, 19, 20, 22, 24, 26, 28];
const PRIOR_P = [30, 31, 32, 33, 33, 32, 31, 29, 27, 25, 24, 23, 22, 22, 22, 22, 22, 22, 22, 23, 24, 26, 28, 29];

function clampN(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }

function medianOf(arr) {
  if (!arr.length) return 0;
  const a = arr.slice().sort((x, y) => x - y);
  const m = a.length >> 1;
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
}

function istanbulNow(ms) {
  const d = new Date((ms || Date.now()) + 3 * 3600 * 1000);
  const dow = d.getUTCDay();
  return {
    hour: d.getUTCHours(),
    minute: d.getUTCMinutes(),
    dow,
    dayType: dow === 0 ? "P" : dow === 6 ? "C" : "I",
    dateKey: d.toISOString().slice(0, 10)
  };
}

function isPeak(t) {
  if (t.dayType !== "I") return false;
  return (t.hour >= 7 && t.hour <= 9) || (t.hour >= 16 && t.hour <= 19);
}
function dwellSeconds(t) { return isPeak(t) ? 24 : 16; }
function signalSecPerKm(t) { return isPeak(t) ? 12 : 7; }

// ── Geohash (precision 5 ≈ 4.9 km) for the optional IBB-derived profile ──────
const GH32 = "0123456789bcdefghjkmnpqrstuvwxyz";
function geohash(lat, lon, precision) {
  let latR = [-90, 90], lonR = [-180, 180], bit = 0, ch = 0, even = true, out = "";
  const p = precision || 5;
  while (out.length < p) {
    if (even) {
      const mid = (lonR[0] + lonR[1]) / 2;
      if (lon >= mid) { ch = (ch << 1) | 1; lonR[0] = mid; } else { ch = ch << 1; lonR[1] = mid; }
    } else {
      const mid = (latR[0] + latR[1]) / 2;
      if (lat >= mid) { ch = (ch << 1) | 1; latR[0] = mid; } else { ch = ch << 1; latR[1] = mid; }
    }
    even = !even;
    if (++bit === 5) { out += GH32[ch]; bit = 0; ch = 0; }
  }
  return out;
}

function priorSpeed(lat, lon, t) {
  const di = t.dayType === "I" ? 0 : t.dayType === "C" ? 1 : 2;
  if (typeof TRAFFIC_PROFILE !== "undefined" && TRAFFIC_PROFILE && TRAFFIC_PROFILE.cells) {
    const row = TRAFFIC_PROFILE.cells[geohash(lat, lon, 5)];
    if (row && row[di] && row[di][t.hour] > 0) return row[di][t.hour];
    const city = TRAFFIC_PROFILE.city;
    if (city && city[di] && city[di][t.hour] > 0) return city[di][t.hour];
  }
  return (t.dayType === "I" ? PRIOR_I : t.dayType === "C" ? PRIOR_C : PRIOR_P)[t.hour];
}

// ── Bearing / heading tracking ───────────────────────────────────────────────
function bearingDeg(lat1, lon1, lat2, lon2) {
  const dy = (lat2 - lat1) * KY;
  const dx = (lon2 - lon1) * KX;
  return (Math.atan2(dx, dy) * 180 / Math.PI + 360) % 360;
}

function angleDiff(a, b) { return Math.abs(((a - b + 540) % 360) - 180); }

// Annotates `list` in place: h (heading°) from the previous snapshot, a (GPS-fix age, s).
async function annotateFleet(list, prevRaw, env) {
  let prev = null;
  try {
    const raw = prevRaw || (env && env.LIVE ? await env.LIVE.get("buses") : null);
    if (raw) prev = new Map(JSON.parse(raw).map(b => [b.id, b]));
  } catch (e) { prev = null; }
  for (const b of list) {
    if (typeof b.a !== "number") b.a = ageSec(b.t);
    const p = prev ? prev.get(b.id) : null;
    if (!p) continue;
    const dM = Math.hypot((b.lat - p.lat) * KY, (b.lon - p.lon) * KX);
    if (dM >= 20 && dM < 3000) b.h = Math.round(bearingDeg(p.lat, p.lon, b.lat, b.lon));
    else if (typeof p.h === "number") b.h = p.h;
  }
  return list;
}

// ── Fleet access (parsed, cached per snapshot) ───────────────────────────────
let fleetParsed = { t: 0, list: [] };

async function getFleet(env) {
  let meta = inMemoryMeta;
  let raw = inMemoryBusesRaw;
  if (!meta || !raw || Date.now() - meta.t >= 30000) {
    try {
      const kvMeta = await env.LIVE.get("meta", { type: "json", cacheTtl: 30 });
      if (kvMeta && (!meta || kvMeta.t > meta.t)) {
        raw = await env.LIVE.get("buses", { cacheTtl: 30 });
        meta = kvMeta;
        inMemoryMeta = meta;
        inMemoryBusesRaw = raw;
      }
    } catch (e) { /* use memory */ }
  }
  if (!meta || !raw) return { t: 0, list: [] };
  if (fleetParsed.t !== meta.t) {
    try { fleetParsed = { t: meta.t, list: JSON.parse(raw) }; } catch (e) { return { t: 0, list: [] }; }
  }
  return fleetParsed;
}

// ── Live traffic field ───────────────────────────────────────────────────────
let trafficCache = { t: -1, field: null };

function buildTrafficField(fleet, snapshotT) {
  const t = istanbulNow();
  const cells = new Map();
  const movingAll = [];
  let total = 0;
  for (const b of fleet) {
    if ((b.a || 0) > 240) continue; // stale fix
    const key = Math.floor(b.lat / CELL_LAT) * CELL_MUL + Math.floor(b.lon / CELL_LON);
    let c = cells.get(key);
    if (!c) { c = { moving: [], stopped: 0 }; cells.set(key, c); }
    total++;
    if (b.s > 3) { c.moving.push(b.s); movingAll.push(b.s); } else c.stopped++;
  }
  const map = new Map();
  const arr = [];
  for (const [key, c] of cells) {
    const n = c.moving.length + c.stopped;
    // cells with no moving bus are garages/terminals/unknown → leave to neighbours + prior
    if (n < 2 || c.moving.length === 0) continue;
    const sr = c.stopped / n;
    let v = medianOf(c.moving);
    if (sr > 0.5 && n >= 4) v *= 0.65; // many stationary buses among moving ones = jam
    v = clampN(v, 3, 60);
    map.set(key, { v, n, sr });
    arr.push([Math.floor(key / CELL_MUL), key % CELL_MUL, Math.round(v * 10) / 10, n, Math.round(sr * 100)]);
  }
  const medMoving = medianOf(movingAll);
  const prior = priorSpeed(41.01, 28.98, t);
  const ratio = medMoving > 0 ? medMoving / prior : 1;
  const level = ratio >= 0.95 ? "akici" : ratio >= 0.75 ? "yogun" : "cok_yogun";
  return {
    map,
    arr,
    snapshot_t: snapshotT,
    city: {
      vehicles: total,
      moving: movingAll.length,
      moving_ratio: total ? Math.round(movingAll.length / total * 100) / 100 : 0,
      median_moving_kmh: Math.round(medMoving * 10) / 10,
      hour_prior_kmh: prior,
      flow_ratio: Math.round(ratio * 100) / 100,
      level
    },
    hour: t.hour,
    day_type: t.dayType
  };
}

async function getTrafficField(env) {
  const f = await getFleet(env);
  if (!f.list.length) return { map: new Map(), arr: [], snapshot_t: 0, city: null, hour: istanbulNow().hour, day_type: istanbulNow().dayType };
  if (trafficCache.t !== f.t || !trafficCache.field) {
    trafficCache = { t: f.t, field: buildTrafficField(f.list, f.t) };
  }
  return trafficCache.field;
}

function speedAt(field, lat, lon, t) {
  const prior = priorSpeed(lat, lon, t);
  const ci = Math.floor(lat / CELL_LAT), cj = Math.floor(lon / CELL_LON);
  let sw = 0, sv = 0;
  for (let di = -1; di <= 1; di++) {
    for (let dj = -1; dj <= 1; dj++) {
      const c = field.map.get((ci + di) * CELL_MUL + (cj + dj));
      if (!c) continue;
      const w = (di === 0 && dj === 0 ? 1 : 0.35) * Math.min(c.n, 8);
      sw += w; sv += w * c.v;
    }
  }
  if (sw === 0) return clampN(prior, 5, 55);
  const live = sv / sw;
  const wl = Math.min(0.85, sw / 10);
  return clampN(wl * live + (1 - wl) * prior, 5, 55);
}

async function handleTraffic(env) {
  const field = await getTrafficField(env);
  return json({
    updated_at: field.snapshot_t,
    server_time: Date.now(),
    source: "fleet-probe",
    has_ibb_profile: typeof TRAFFIC_PROFILE !== "undefined" && !!TRAFFIC_PROFILE,
    cell: { lat: CELL_LAT, lon: CELL_LON, mul: CELL_MUL },
    hour: field.hour,
    day_type: field.day_type,
    city: field.city,
    cells: field.arr
  }, 200, { "cache-control": "public, max-age=15" });
}

// ── Route index & ETA ────────────────────────────────────────────────────────
function buildRouteIndex(dir) {
  const pts = (dir.coordinates && dir.coordinates.length >= 2)
    ? dir.coordinates
    : (dir.stops || []).map(s => [s.lat, s.lon]);
  const n = pts.length;
  if (n < 2) return null;
  const xs = new Float64Array(n), ys = new Float64Array(n), cum = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    xs[i] = pts[i][1] * KX;
    ys[i] = pts[i][0] * KY;
    if (i > 0) cum[i] = cum[i - 1] + Math.hypot(xs[i] - xs[i - 1], ys[i] - ys[i - 1]);
  }
  const idx = { pts, xs, ys, cum, length: cum[n - 1], stops: [] };
  let prev = 0;
  for (const s of (dir.stops || [])) {
    const p = projectOnRoute(idx, s.lat, s.lon, prev - 200, Infinity);
    const along = Math.max(prev, p.along);
    idx.stops.push({ seq: s.seq, code: s.code, name: s.name, lat: s.lat, lon: s.lon, along, off: p.off });
    prev = along;
  }
  return idx;
}

function projectOnRoute(idx, lat, lon, minAlong, maxAlong) {
  const lo = minAlong === undefined ? -Infinity : minAlong;
  const hi = maxAlong === undefined ? Infinity : maxAlong;
  const x = lon * KX, y = lat * KY;
  const { xs, ys, cum } = idx;
  let best = Infinity, bestAlong = 0, bestSeg = 0;
  for (let i = 0; i < xs.length - 1; i++) {
    if (cum[i + 1] < lo || cum[i] > hi) continue;
    const dx = xs[i + 1] - xs[i], dy = ys[i + 1] - ys[i];
    const l2 = dx * dx + dy * dy;
    let u = l2 > 0 ? ((x - xs[i]) * dx + (y - ys[i]) * dy) / l2 : 0;
    u = u < 0 ? 0 : u > 1 ? 1 : u;
    const d = Math.hypot(x - (xs[i] + u * dx), y - (ys[i] + u * dy));
    if (d < best) { best = d; bestAlong = cum[i] + u * Math.sqrt(l2); bestSeg = i; }
  }
  return { along: bestAlong, off: best === Infinity ? 99999 : best, seg: bestSeg };
}

function segmentBearing(idx, seg) {
  const i = clampN(seg, 0, idx.xs.length - 2);
  return (Math.atan2(idx.xs[i + 1] - idx.xs[i], idx.ys[i + 1] - idx.ys[i]) * 180 / Math.PI + 360) % 360;
}

function positionAt(idx, along) {
  const a = clampN(along, 0, idx.length);
  let lo = 0, hi = idx.cum.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (idx.cum[mid] <= a) lo = mid; else hi = mid;
  }
  const span = idx.cum[hi] - idx.cum[lo];
  const u = span > 0 ? (a - idx.cum[lo]) / span : 0;
  return [idx.pts[lo][0] + (idx.pts[hi][0] - idx.pts[lo][0]) * u, idx.pts[lo][1] + (idx.pts[hi][1] - idx.pts[lo][1]) * u];
}

function travelSeconds(idx, a0, a1, field, t) {
  if (a1 <= a0) return 0;
  const STEP = 300;
  let sec = 0, a = a0;
  while (a < a1) {
    const b = Math.min(a1, a + STEP);
    const p = positionAt(idx, (a + b) / 2);
    sec += (b - a) / (speedAt(field, p[0], p[1], t) / 3.6);
    a = b;
  }
  return sec + (a1 - a0) / 1000 * signalSecPerKm(t);
}

// Cumulative ETA (s) from `fromAlong` to each upcoming stop; stops after `untilI` are skipped.
function etaTimeline(idx, fromAlong, field, t, untilI) {
  const out = [];
  const dw = dwellSeconds(t);
  let a = fromAlong, sec = 0;
  const last = untilI === undefined ? idx.stops.length - 1 : untilI;
  for (let i = 0; i <= last && i < idx.stops.length; i++) {
    const s = idx.stops[i];
    if (s.along < fromAlong - 25) continue;
    const target = Math.max(s.along, a);
    sec += travelSeconds(idx, a, target, field, t);
    a = target;
    out.push({ i, sec: Math.round(sec), dist: Math.max(0, Math.round(s.along - fromAlong)) });
    sec += dw;
  }
  return out;
}

const routeIndexCache = new Map();
function getRouteIndexes(routeData) {
  const out = {};
  for (const [k, d] of Object.entries(routeData.directions || {})) {
    const key = [routeData.code, k, (d.stops || []).length, (d.coordinates || []).length].join("|");
    let idx = routeIndexCache.get(key);
    if (idx === undefined) {
      idx = buildRouteIndex(d);
      if (routeIndexCache.size > 500) routeIndexCache.clear();
      routeIndexCache.set(key, idx);
    }
    out[k] = idx;
  }
  return out;
}

// Pick the direction a bus is travelling in: nearest polyline, penalising opposite heading.
function locateBus(b, indexes) {
  const moving = (b.s || 0) >= 6 && typeof b.h === "number";
  let best = null;
  for (const [dk, idx] of Object.entries(indexes)) {
    if (!idx) continue;
    const p = projectOnRoute(idx, b.lat, b.lon);
    let score = p.off;
    if (moving) {
      const d = angleDiff(b.h, segmentBearing(idx, p.seg));
      if (d > 100) score += 250; else if (d > 60) score += 60;
    }
    if (!best || score < best.score) best = { dk, idx, p, score };
  }
  return best;
}

function etaConfidence(age, off) {
  if (age <= 45 && off <= 50) return "high";
  if (age <= 120 && off <= 120) return "med";
  return "low";
}

function enrichBusEta(b, indexes, field, t) {
  const loc = locateBus(b, indexes);
  if (!loc || loc.p.off > 400) return null;
  const { idx, p, dk } = loc;
  const tl = etaTimeline(idx, p.along, field, t);
  if (!tl.length) return null;
  const age = Math.min(b.a || 0, 120);
  let next = tl[0];
  const dist0 = next.dist;
  const atStop = dist0 <= 35 && (b.s || 0) < 8;
  if (atStop && tl.length > 1) next = tl[1];
  const stop = idx.stops[next.i];
  const term = tl[tl.length - 1];
  return {
    dir: dk,
    next_stop: stop.name,
    next_stop_code: stop.code,
    next_stop_seq: stop.seq,
    next_stop_dist_m: next.dist,
    next_stop_eta_sec: atStop && next === tl[0] ? 0 : Math.max(0, next.sec - age),
    at_stop: atStop,
    stops_left: tl.length,
    terminal_eta_sec: Math.max(0, term.sec - age),
    route_progress: Math.round(p.along / idx.length * 1000) / 1000,
    off_route_m: Math.round(p.off),
    eta_conf: etaConfidence(b.a || 0, p.off)
  };
}

// Fast route (stops only, no OSRM) — cached 24 h; prefers the full road-snapped route if present.
async function getRouteForEta(code, env) {
  try {
    const full = await env.LIVE.get("route_v4:" + code, { type: "json", cacheTtl: 300 });
    if (full && full.directions) return full;
    const fast = await env.LIVE.get("route_fast_v1:" + code, { type: "json", cacheTtl: 300 });
    if (fast && fast.directions) return fast;
  } catch (e) { /* fall through */ }
  return fetchLineRoute(code, env, { fast: true });
}

// Adds route-aware ETA fields to the bus objects built by handleLine (mutates).
async function enrichLineBusesEta(buses, routeData, env) {
  const field = await getTrafficField(env);
  const t = istanbulNow();
  const indexes = getRouteIndexes(routeData);
  for (const b of buses) {
    const r = enrichBusEta(b, indexes, field, t);
    if (!r) continue;
    const d = routeData.directions[r.dir];
    Object.assign(b, r);
    b.dir = r.dir;
    b.dir_name = d ? d.destination : b.dir_name;
    b.headsign = d ? d.headsign : b.headsign;
    b.destination = d ? d.destination : "";
    b.color = r.dir === "G" ? "#a855f7" : "#06b6d4";
    b.stop = r.next_stop;
  }
  return field;
}

// ── /bus/eta — full upcoming-stop timeline for one bus ───────────────────────
async function handleBusEta(env, url) {
  const code = norm(url.searchParams.get("line"));
  const id = String(url.searchParams.get("id") || "");
  if (!code || !id) return json({ error: "line and id required" }, 400);
  const route = await getRouteForEta(code, env);
  const fleet = await getFleet(env);
  const bus = fleet.list.find(b => b.id === id);
  if (!bus || !route || !route.directions) return json({ error: "not_found" }, 404);
  const field = await getTrafficField(env);
  const t = istanbulNow();
  const indexes = getRouteIndexes(route);
  const loc = locateBus(bus, indexes);
  if (!loc || loc.p.off > 400) return json({ error: "off_route" }, 404);
  const age = Math.min(bus.a || 0, 120);
  const tl = etaTimeline(loc.idx, loc.p.along, field, t);
  return json({
    line: code, id, dir: loc.dk, server_time: Date.now(), age_s: bus.a || 0,
    conf: etaConfidence(bus.a || 0, loc.p.off),
    stops: tl.map(e => {
      const s = loc.idx.stops[e.i];
      return { seq: s.seq, code: s.code, name: s.name, lat: s.lat, lon: s.lon, dist_m: e.dist, eta_sec: Math.max(0, e.sec - age) };
    })
  }, 200, { "cache-control": "public, max-age=10" });
}

// ── /stop/arrivals — live arrivals at a stop, measured along each candidate route ─
let stopByCode = null;
const arrivalsCache = new Map();

async function handleStopArrivals(env, url) {
  const code = String(url.searchParams.get("code") || "").trim();
  if (!stopByCode) stopByCode = new Map(BUS_STOPS.map(s => [String(s.c), s]));
  const stop = stopByCode.get(code);
  if (!stop) return json({ error: "unknown_stop" }, 404);

  const hit = arrivalsCache.get(code);
  if (hit && Date.now() - hit.at < 10000 && hit.snapshot === (inMemoryMeta ? inMemoryMeta.t : 0)) {
    return json(hit.body, 200, { "cache-control": "public, max-age=10" });
  }

  const fleet = await getFleet(env);
  const field = await getTrafficField(env);
  const t = istanbulNow();

  // 1. candidate lines from nearby vehicles (door → assigned lines)
  const byLine = new Map();
  for (const b of fleet.list) {
    if (Math.abs(b.lat - stop.lat) > 0.065 || Math.abs(b.lon - stop.lon) > 0.085) continue;
    const lines = DOOR_LINES_MAP[b.id];
    if (!lines) continue;
    const d = haversineMeters(b.lat, b.lon, stop.lat, stop.lon);
    for (const ln of lines.slice(0, 2)) {
      let e = byLine.get(ln);
      if (!e) { e = { line: ln, minD: Infinity, buses: [] }; byLine.set(ln, e); }
      e.minD = Math.min(e.minD, d);
      e.buses.push(b);
    }
  }
  const candidates = Array.from(byLine.values()).sort((a, b) => a.minD - b.minD).slice(0, 14);

  // 2. route per line (cached) + along-route ETA
  let skipped = 0;
  const arrivals = [];
  await Promise.all(candidates.map(async (c) => {
    let route;
    try { route = await getRouteForEta(c.line, env); } catch (e) { route = null; }
    if (!route || !route.directions || !Object.keys(route.directions).length) { skipped++; return; }
    const indexes = getRouteIndexes(route);
    // which direction(s) serve this stop?
    const serving = {};
    for (const [dk, idx] of Object.entries(indexes)) {
      if (!idx) continue;
      let si = idx.stops.findIndex(s => String(s.code) === code);
      if (si < 0) {
        si = idx.stops.findIndex(s => haversineMeters(s.lat, s.lon, stop.lat, stop.lon) <= 40 && norm(s.name) === norm(stop.n));
      }
      if (si >= 0) serving[dk] = si;
    }
    if (!Object.keys(serving).length) return;
    const perLine = [];
    for (const b of c.buses) {
      const loc = locateBus(b, indexes);
      if (!loc || loc.p.off > 400 || !(loc.dk in serving)) continue;
      const si = serving[loc.dk];
      const target = loc.idx.stops[si];
      if (target.along < loc.p.along - 25) continue; // already passed
      const tl = etaTimeline(loc.idx, loc.p.along, field, t, si);
      const e = tl[tl.length - 1];
      if (!e || e.i !== si) continue;
      const age = Math.min(b.a || 0, 120);
      const d = route.directions[loc.dk];
      perLine.push({
        line: c.line,
        bus_id: b.id,
        plate: b.p || "",
        dir: loc.dk,
        headsign: d ? (d.destination || d.headsign) : "",
        speed: b.s || 0,
        dist_m: e.dist,
        stops_away: tl.length - 1,
        eta_sec: Math.max(0, e.sec - age),
        age_s: b.a || 0,
        conf: etaConfidence(b.a || 0, loc.p.off)
      });
    }
    perLine.sort((x, y) => x.eta_sec - y.eta_sec);
    arrivals.push(...perLine.slice(0, 2));
  }));
  arrivals.sort((x, y) => x.eta_sec - y.eta_sec);

  const body = {
    stop: { code: stop.c, name: stop.n, district: stop.d, lat: stop.lat, lon: stop.lon },
    server_time: Date.now(),
    updated_at: fleet.t,
    traffic: field.city ? { level: field.city.level, median_moving_kmh: field.city.median_moving_kmh } : null,
    candidate_lines: candidates.length,
    skipped_lines: skipped,
    arrivals: arrivals.slice(0, 14)
  };
  arrivalsCache.set(code, { at: Date.now(), snapshot: inMemoryMeta ? inMemoryMeta.t : 0, body });
  if (arrivalsCache.size > 300) arrivalsCache.clear();
  return json(body, 200, { "cache-control": "public, max-age=10" });
}

// ── Metro İstanbul official timetable ────────────────────────────────────────
async function metroFetch(path, method, body) {
  const res = await fetch(`${METRO_API}/${path}`, {
    method: method || "GET",
    headers: { "Content-Type": "application/json", "Accept": "application/json", "User-Agent": "Mozilla/5.0" },
    body: body ? JSON.stringify(body) : undefined
  });
  if (!res.ok) throw new Error(`Metro ${path} HTTP ${res.status}`);
  const j = await res.json();
  if (j && j.Success === false) throw new Error(`Metro ${path}: ${(j.Error && j.Error.Message) || j.Message || "failed"}`);
  return j && j.Data !== undefined ? j.Data : j;
}

function pickKey(o, names) {
  if (!o || typeof o !== "object") return undefined;
  const lower = {};
  for (const k of Object.keys(o)) lower[k.toLowerCase()] = o[k];
  for (const n of names) if (lower[n.toLowerCase()] !== undefined && lower[n.toLowerCase()] !== null) return lower[n.toLowerCase()];
  return undefined;
}

function plainName(s) {
  return String(s || "").toLocaleUpperCase("tr-TR")
    .replace(/İ/g, "I").replace(/Ş/g, "S").replace(/Ğ/g, "G").replace(/Ü/g, "U").replace(/Ö/g, "O").replace(/Ç/g, "C")
    .replace(/İSTASYONU|ISTASYONU|ISTASYON/g, "").replace(/[^A-Z0-9]/g, "");
}

function dayTypeFromName(dayName, dayNum) {
  const s = plainName(dayName);
  if (s.includes("CUMARTESI")) return "C";
  if (s.includes("PAZAR") && !s.includes("PAZARTESI")) return "P";
  if (s.includes("HAFTAICI") || s.includes("ISGUNU") || s.includes("PAZARTESI") || s.includes("SALI") || s.includes("CARSAMBA") || s.includes("PERSEMBE") || s.includes("CUMA")) return "I";
  if (typeof dayNum === "number") return dayNum === 6 ? "C" : dayNum === 0 || dayNum === 7 ? "P" : "I";
  return null;
}

function extractTimeInfos(data) {
  const out = [];
  const walk = (node) => {
    if (!node) return;
    if (Array.isArray(node)) { node.forEach(walk); return; }
    if (typeof node !== "object") return;
    const ti = pickKey(node, ["TimeInfos"]);
    if (ti) { walk(ti); return; }
    const times = pickKey(node, ["Times"]);
    if (Array.isArray(times)) {
      const list = times
        .map(x => (typeof x === "string" ? x : pickKey(x, ["Time", "Hour", "Saat"]) || ""))
        .map(x => String(x).trim())
        .filter(x => /^\d{1,2}:\d{2}/.test(x))
        .map(x => x.slice(0, 5).padStart(5, "0"));
      out.push({ day: pickKey(node, ["Day"]), dayName: pickKey(node, ["DayName"]), times: list });
    }
  };
  walk(data);
  return out;
}

async function getMetroLineMeta(lineCode, env) {
  const key = "metro_meta_v1:" + lineCode;
  try {
    const c = await env.LIVE.get(key, { type: "json", cacheTtl: 3600 });
    if (c && c.lineId !== undefined) return c;
  } catch (e) { /* refetch */ }

  const lines = await metroFetch("GetLines");
  const want = plainName(lineCode);
  const line = (Array.isArray(lines) ? lines : []).find(l =>
    ["Name", "ShortName", "Code", "LineName", "LineCode", "Description"].some(k => plainName(pickKey(l, [k])) === want));
  if (!line) throw new Error(`Metro line ${lineCode} not in GetLines`);
  const lineId = pickKey(line, ["Id", "LineId"]);

  const [stationsRaw, dirsRaw] = await Promise.all([
    metroFetch(`GetStationById/${encodeURIComponent(lineId)}`),
    metroFetch(`GetDirectionById/${encodeURIComponent(lineId)}`)
  ]);
  const stations = (Array.isArray(stationsRaw) ? stationsRaw : []).map(s => ({
    id: pickKey(s, ["Id", "StationId"]),
    name: String(pickKey(s, ["Description", "Name", "StationName"]) || "")
  })).filter(s => s.id !== undefined);
  const directions = (Array.isArray(dirsRaw) ? dirsRaw : []).map(d => ({
    id: pickKey(d, ["DirectionId", "Id"]),
    name: String(pickKey(d, ["DirectionName", "Name"]) || ""),
    value: pickKey(d, ["DirectionValue"])
  })).filter(d => d.id !== undefined);

  const meta = { lineId, stations, directions };
  await env.LIVE.put(key, JSON.stringify(meta), { expirationTtl: 86400 }).catch(() => {});
  return meta;
}

function synthRailEntries(lineCode, dayTypes, dirs) {
  const base = generateMetroTimetable(lineCode).entries;
  return base.filter(e => dayTypes.includes(e.day_type) && dirs.includes(e.direction)).map(e => Object.assign({}, e, { estimated: true }));
}

async function getMetroTimetable(lineCode, env) {
  const t = istanbulNow();
  const cacheKey = `metro_tt_v1:${lineCode}:${t.dateKey}`;
  try {
    const c = await env.LIVE.get(cacheKey, { type: "json", cacheTtl: 600 });
    if (c && c.entries && c.entries.length) return c;
  } catch (e) { /* refetch */ }

  const meta = await getMetroLineMeta(lineCode, env);
  if (!meta.directions.length || !meta.stations.length) throw new Error("Metro meta incomplete");

  const entries = [];
  const dirInfo = [];
  const have = new Set();
  for (let di = 0; di < Math.min(2, meta.directions.length); di++) {
    const d = meta.directions[di];
    const dir = di === 0 ? "G" : "D";
    const origin = plainName(String(d.name).split(/->|→|–|—|-/)[0]);
    let st = meta.stations.find(s => plainName(s.name) === origin) ||
             meta.stations.find(s => origin && (plainName(s.name).includes(origin) || origin.includes(plainName(s.name))));
    if (!st) st = di === 0 ? meta.stations[0] : meta.stations[meta.stations.length - 1];
    const data = await metroFetch("GetTimeTable", "POST", { boardingStationId: st.id, directionId: d.id });
    const infos = extractTimeInfos(data);
    dirInfo.push({ dir, direction_id: d.id, name: d.name, boarding_station: st.name });
    for (const info of infos) {
      const dt = dayTypeFromName(info.dayName, typeof info.day === "number" ? info.day : undefined) || t.dayType;
      for (const time of info.times) {
        entries.push({ time, direction: dir, day_type: dt, service_type: "Metro", route_sign: st.name, estimated: false });
        have.add(dt + dir);
      }
    }
  }
  if (!entries.length) throw new Error("Metro GetTimeTable returned no times");

  // Fill day types the API did not return with clearly-flagged frequency estimates.
  const missing = [];
  for (const dt of ["I", "C", "P"]) for (const dir of ["D", "G"]) if (!have.has(dt + dir)) missing.push([dt, dir]);
  for (const [dt, dir] of missing) entries.push(...synthRailEntries(lineCode, [dt], [dir]));

  const official = Array.from(have);
  const result = {
    line_code: lineCode,
    is_metro: true,
    official: true,
    official_day_types: Array.from(new Set(official.map(x => x[0]))),
    directions: dirInfo,
    entries,
    total_departures: entries.length,
    source: "Metro İstanbul GetTimeTable",
    note: missing.length ? "Resmî Metro İstanbul tarifesi (bugün). Diğer gün tipleri tahmini sıklıktır." : "Resmî Metro İstanbul tarifesi.",
    updated_at: Date.now()
  };
  await env.LIVE.put(cacheKey, JSON.stringify(result), { expirationTtl: 21600 }).catch(() => {});
  return result;
}

// ── /diag — edge-side self-check of every upstream (spends at most 1 IETT call with ?live=1) ──
async function timed(name, fn, timeoutMs) {
  const t0 = Date.now();
  try {
    const r = await Promise.race([
      fn(),
      new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), timeoutMs || 9000))
    ]);
    return Object.assign({ name, ms: Date.now() - t0 }, r);
  } catch (e) {
    return { name, ok: false, ms: Date.now() - t0, detail: String(e).slice(0, 240) };
  }
}

async function handleDiag(env, url) {
  const live = url.searchParams.get("live") === "1";
  const tests = [];

  tests.push(timed("cached fleet (feeder push)", async () => {
    const f = await getFleet(env);
    const meta = inMemoryMeta;
    const ageS = meta ? Math.round((Date.now() - meta.t) / 1000) : null;
    const fresh = f.list.filter(b => (b.a || 0) <= 180).length;
    const inBounds = f.list.filter(b => b.lat > 40.5 && b.lat < 41.6 && b.lon > 27.8 && b.lon < 29.8).length;
    return {
      ok: f.list.length > 1000 && ageS !== null && ageS < 180 && fresh / f.list.length > 0.5 && inBounds === f.list.length,
      detail: `vehicles=${f.list.length}, snapshot_age_s=${ageS}, fix<=180s=${fresh}, in_bounds=${inBounds}`,
      sample: f.list[0] || null
    };
  }));

  tests.push(timed("traffic field", async () => {
    const field = await getTrafficField(env);
    return { ok: field.arr.length > 100, detail: `cells=${field.arr.length}, city=${JSON.stringify(field.city)}` };
  }));

  if (live) {
    tests.push(timed("IETT GetFiloAracKonum_json (live, spends 1 quota)", async () => {
      const q = await quota(env);
      if (q.n >= 95) return { ok: false, detail: `quota ${q.n}/99 — skipped` };
      await spend(env, q);
      const rows = await soap(IETT, "GetFiloAracKonum_json", null, env);
      const ok = Array.isArray(rows) && rows.length > 1000 && ["KapiNo", "Enlem", "Boylam", "Hiz", "Saat"].every(k => k in rows[0]);
      return { ok, detail: `rows=${Array.isArray(rows) ? rows.length : "n/a"}`, sample: Array.isArray(rows) ? rows[0] : null };
    }));
  }

  tests.push(timed("IETT GetHatOtoKonum_json 15B", async () => {
    const rows = await soap(IETT, "GetHatOtoKonum_json", { HatKodu: "15B" }, env);
    const ok = Array.isArray(rows) && (rows.length === 0 || ["kapino", "enlem", "boylam"].every(k => k in lower(rows[0])));
    return { ok, detail: `rows=${Array.isArray(rows) ? rows.length : "n/a"}`, sample: Array.isArray(rows) ? rows[0] : null };
  }));

  tests.push(timed("IBB DurakDetay_GYY 15B", async () => {
    const r = await fetchLineRoute("15B", env, { fast: true });
    const dirs = Object.keys(r.directions || {});
    return { ok: dirs.length > 0 && r.total_stops > 10, detail: `directions=${dirs.join(",")}, stops=${r.total_stops}, name=${r.name}` };
  }));

  tests.push(timed("IBB GetPlanlananSeferSaati_json 15B", async () => {
    const body = `<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><GetPlanlananSeferSaati_json xmlns="${NS}"><HatKodu>15B</HatKodu></GetPlanlananSeferSaati_json></soap:Body></soap:Envelope>`;
    const res = await fetch(TIMETABLE_URL, { method: "POST", headers: { "Content-Type": "text/xml; charset=utf-8", "SOAPAction": `"${NS}GetPlanlananSeferSaati_json"` }, body });
    const xml = await res.text();
    const a = xml.indexOf("<GetPlanlananSeferSaati_jsonResult>"), b = xml.indexOf("</GetPlanlananSeferSaati_jsonResult>");
    if (a < 0 || b < 0) return { ok: false, detail: `HTTP ${res.status}: ${xml.slice(0, 160)}` };
    const rows = JSON.parse(unesc(xml.slice(a + 35, b)));
    const ok = Array.isArray(rows) && rows.length > 10 && ["DT", "SYON", "SGUNTIPI"].every(k => k in rows[0]);
    return { ok, detail: `rows=${rows.length}`, sample: rows[0] };
  }));

  tests.push(timed("IBB GetDuyurular_json", async () => {
    const rows = await soap(DUYURULAR_URL, "GetDuyurular_json", null, env);
    return { ok: Array.isArray(rows), detail: `rows=${Array.isArray(rows) ? rows.length : "n/a"}`, sample: Array.isArray(rows) ? rows[0] : null };
  }));

  tests.push(timed("Metro İstanbul GetLines", async () => {
    const d = await metroFetch("GetLines");
    return { ok: Array.isArray(d) && d.length > 5, detail: `lines=${Array.isArray(d) ? d.length : "n/a"}`, sample: Array.isArray(d) ? d[0] : null };
  }));

  tests.push(timed("Metro İstanbul timetable M2", async () => {
    const r = await getMetroTimetable("M2", env);
    return { ok: r.official === true && r.entries.length > 20, detail: `entries=${r.entries.length}, official_days=${(r.official_day_types || []).join("")}, dirs=${JSON.stringify(r.directions)}` };
  }));

  tests.push(timed("data.ibb.gov.tr CKAN (hourly traffic density)", async () => {
    const res = await fetch("https://data.ibb.gov.tr/api/3/action/package_show?id=hourly-traffic-density-data-set", { headers: { "User-Agent": "Mozilla/5.0" } });
    const j = await res.json();
    const resources = (j.result && j.result.resources) || [];
    const last = resources[resources.length - 1];
    return { ok: !!j.success && resources.length > 0, detail: `resources=${resources.length}, last=${last ? last.name : "n/a"}` };
  }));

  tests.push(timed("secrets / KV", async () => {
    const key = env.CARTO_API_KEY || env.CARTO_KEY || "";
    await env.LIVE.get("meta");
    return { ok: !!key, detail: `CARTO key ${key ? "present" : "MISSING"}, IBB key ${(env.IBB_API_KEY || env.IBB_SECRET) ? "present" : "absent (optional)"}` };
  }));

  const results = await Promise.all(tests);
  return json({
    generated_at: new Date().toISOString(),
    passed: results.filter(r => r.ok).length,
    total: results.length,
    results
  }, 200, { "cache-control": "no-store" });
}
