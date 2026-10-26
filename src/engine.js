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

function resolveCartoKey(env) {
  if (!env) return "";
  const explicit = [
    env.CART0_API_KEY,
    env.CARTO_API_KEY,
    env.CART0_KEY,
    env.CARTO_KEY,
    env.carto_api_key,
    env.cart0_api_key,
    env.carto_key,
    env.cart0_key
  ];
  for (const c of explicit) {
    if (typeof c === "string" && c.trim()) return c.trim();
  }
  try {
    for (const [k, v] of Object.entries(env)) {
      const norm = k.toLowerCase().replace(/0/g, "o");
      if (norm.includes("carto") && (norm.includes("key") || norm.includes("api"))) {
        if (typeof v === "string" && v.trim()) return v.trim();
      }
    }
  } catch (e) {}
  return "";
}

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
    const raw = prevRaw;
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
  const { meta, raw } = await loadFleet(env);
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

// Fast route (stops only, no OSRM) — cached in memory & 24 h edge; prefers full road-snapped route if present.
const routeEtaMemCache = new Map();
async function getRouteForEta(code, env) {
  const normCode = String(code || "").toUpperCase().trim();
  if (routeEtaMemCache.has(normCode)) return routeEtaMemCache.get(normCode);
  try {
    const full = await edgeGetJson("route_v5:" + normCode);
    if (full && full.directions && Object.keys(full.directions).length > 0) {
      routeEtaMemCache.set(normCode, full);
      return full;
    }
  } catch (e) { /* fall through */ }
  const fast = await fetchLineRoute(normCode, env, { fast: true });
  if (fast && fast.directions && Object.keys(fast.directions).length > 0) {
    if (routeEtaMemCache.size > 600) routeEtaMemCache.clear();
    routeEtaMemCache.set(normCode, fast);
  }
  return fast;
}

function getBusLines(b) {
  if (!b) return [];
  if (b.line) return [String(b.line).toUpperCase().trim()];
  const raw = typeof DOOR_LINES_MAP !== "undefined" ? DOOR_LINES_MAP[b.id] : null;
  if (!raw) return [];
  if (Array.isArray(raw)) return raw.map(x => String(x).toUpperCase().trim()).filter(Boolean);
  const s = String(raw).toUpperCase().trim();
  return s ? [s] : [];
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

  // 1. Determine lines that actually serve this stop
  const knownLines = (typeof STOP_LINES_MAP !== "undefined" && Array.isArray(STOP_LINES_MAP[code]))
    ? STOP_LINES_MAP[code].map(x => String(x).toUpperCase().trim()).filter(Boolean)
    : [];
  const allowedSet = new Set(knownLines);
  if (String(stop.c).startsWith("900")) {
    for (const mbLine of ["34G", "34AS", "34BZ", "34", "34Z", "34B", "34C", "34A"]) {
      allowedSet.add(mbLine);
    }
  }

  const byLine = new Map();
  const maxLatDiff = allowedSet.size > 0 ? 0.16 : 0.06;
  const maxLonDiff = allowedSet.size > 0 ? 0.20 : 0.08;

  for (const b of fleet.list) {
    if ((b.a || 0) > 600) continue; // ignore stale GPS signals (>10 min old)
    if (Math.abs(b.lat - stop.lat) > maxLatDiff || Math.abs(b.lon - stop.lon) > maxLonDiff) continue;
    const busLines = getBusLines(b);
    if (busLines.length === 0) continue;
    const d = haversineMeters(b.lat, b.lon, stop.lat, stop.lon);
    for (const ln of busLines.slice(0, 3)) {
      if (allowedSet.size > 0 && !allowedSet.has(ln)) continue;
      let e = byLine.get(ln);
      if (!e) { e = { line: ln, minD: Infinity, buses: [] }; byLine.set(ln, e); }
      e.minD = Math.min(e.minD, d);
      e.buses.push(b);
    }
  }

  const candidates = Array.from(byLine.values()).sort((a, b) => a.minD - b.minD).slice(0, 32);

  // 2. route per line (cached) + along-route ETA
  let skipped = 0;
  const arrivals = [];
  await Promise.all(candidates.map(async (c) => {
    let route;
    try { route = await getRouteForEta(c.line, env); } catch (e) { route = null; }
    if (!route || !route.directions || !Object.keys(route.directions).length) {
      // Only allow straight-line fallback if this line is explicitly known to pass through this stop
      if (!allowedSet.has(c.line)) {
        skipped++;
        return;
      }
      const perLineFallback = [];
      for (const b of c.buses) {
        const d = haversineMeters(b.lat, b.lon, stop.lat, stop.lon);
        if (d > 6000) continue;
        // If bus is moving and has heading, ensure it is not driving away from the stop
        if ((b.s || 0) >= 6 && typeof b.h === "number") {
          const brgToStop = (Math.atan2((stop.lon - b.lon) * KX, (stop.lat - b.lat) * KY) * 180 / Math.PI + 360) % 360;
          if (angleDiff(b.h, brgToStop) > 100) continue;
        }
        const routeDist = Math.round(d * 1.25);
        const speedMs = Math.max(4.0, Math.min(14.0, ((b.s || 18) * 0.85) / 3.6));
        const stopsAway = Math.max(1, Math.round(routeDist / 420));
        const etaSec = Math.max(15, Math.round(routeDist / speedMs) + stopsAway * 18 - Math.min(b.a || 0, 90));
        const headsign = (typeof LINE_DESTINATIONS !== "undefined" && LINE_DESTINATIONS[c.line]) || (c.line + " Hattı");
        perLineFallback.push({
          line: c.line,
          bus_id: b.id,
          plate: b.p || "",
          dir: "D",
          headsign: headsign,
          speed: b.s || 0,
          dist_m: routeDist,
          stops_away: stopsAway,
          eta_sec: etaSec,
          age_s: b.a || 0,
          conf: "low"
        });
      }
      perLineFallback.sort((x, y) => x.eta_sec - y.eta_sec);
      arrivals.push(...perLineFallback.slice(0, 2));
      return;
    }
    const indexes = getRouteIndexes(route);
    // which direction(s) serve this stop?
    const serving = {};
    for (const [dk, idx] of Object.entries(indexes)) {
      if (!idx) continue;
      let si = idx.stops.findIndex(s => String(s.code) === code);
      if (si < 0) {
        si = idx.stops.findIndex(s => haversineMeters(s.lat, s.lon, stop.lat, stop.lon) <= 80 && norm(s.name) === norm(stop.n));
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
      // Ignore buses parked idle at origin depot if stop is >2 stops away
      if (loc.p.along < 60 && (b.s || 0) < 2 && si >= 2) continue;
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
    stop: {
      code: stop.c,
      name: stop.n,
      district: stop.d,
      direction: stop.y || "",
      lat: stop.lat,
      lon: stop.lon
    },
    server_time: Date.now(),
    updated_at: fleet.t,
    traffic: field.city ? { level: field.city.level, median_moving_kmh: field.city.median_moving_kmh } : null,
    candidate_lines: candidates.length,
    skipped_lines: skipped,
    passing_lines: (typeof STOP_LINES_MAP !== "undefined" && STOP_LINES_MAP[code]) || [],
    arrivals: arrivals.slice(0, 16)
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
    const c = await edgeGetJson(key);
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
  await edgePutJson(key, meta, 86400);
  return meta;
}

function synthRailEntries(lineCode, dayTypes, dirs) {
  const base = generateMetroTimetable(lineCode).entries;
  return base.filter(e => dayTypes.includes(e.day_type) && dirs.includes(e.direction)).map(e => Object.assign({}, e, { estimated: true }));
}

async function getMetroTimetable(lineCode, env) {
  const normCode = String(lineCode || "").toUpperCase().trim();
  if (normCode === "B1" || normCode === "MARMARAY") {
    return generateMetroTimetable("B1");
  }

  const t = istanbulNow();
  const cacheKey = `metro_tt_v1:${lineCode}:${t.dateKey}`;
  try {
    const c = await edgeGetJson(cacheKey);
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
  await edgePutJson(cacheKey, result, 21600);
  return result;
}

// ── /diag — edge-side self-check of every upstream (spends at most 1 IETT call with ?live=1) ──
// ── Multi-Modal Transit Route Planner (/route/plan) ─────────────────────────
let transitGraphCache = null;

function decodeGooglePolyline(str) {
  if (!str || typeof str !== "string") return [];
  let idx = 0, lat = 0, lng = 0;
  const coords = [];
  while (idx < str.length) {
    let b, shift = 0, result = 0;
    do {
      b = str.charCodeAt(idx++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20 && idx < str.length + 1);
    lat += (result & 1) ? ~(result >> 1) : (result >> 1);
    shift = 0;
    result = 0;
    do {
      b = str.charCodeAt(idx++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20 && idx < str.length + 1);
    lng += (result & 1) ? ~(result >> 1) : (result >> 1);
    coords.push([lat / 1e5, lng / 1e5]);
  }
  return coords;
}

function fmtClockMin(totalMin) {
  const m = ((Math.round(totalMin) % 1440) + 1440) % 1440;
  const hh = String(Math.floor(m / 60)).padStart(2, "0");
  const mm = String(m % 60).padStart(2, "0");
  return `${hh}:${mm}`;
}

function walkMinutes(distM) {
  return Math.max(1, Math.ceil((distM * 1.22) / 78)); // ~4.7 km/h with street Detour factor 1.22
}

function getTransitGraph() {
  if (transitGraphCache) return transitGraphCache;

  const stopMap = new Map();
  if (typeof BUS_STOPS !== "undefined" && Array.isArray(BUS_STOPS)) {
    for (const s of BUS_STOPS) {
      stopMap.set(String(s.c), s);
    }
  }

  // 1. Rail lines & stations
  const railLines = {};
  const railStations = [];
  if (typeof METRO_STATIONS !== "undefined" && METRO_STATIONS) {
    for (const [code, stList] of Object.entries(METRO_STATIONS)) {
      if (!Array.isArray(stList) || stList.length < 2) continue;
      const color = (typeof METRO_COLORS !== "undefined" && METRO_COLORS[code]) || "#2563eb";
      const mode = code === "B1" ? "marmaray"
        : code.startsWith("T") && !code.startsWith("TF") ? "tram"
        : (code.startsWith("F") || code.startsWith("TF")) ? "funicular"
        : "metro";
      const stops = stList.map((s, idx) => ({
        id: `rail:${code}:${idx}`,
        line: code,
        idx,
        name: s.name,
        lat: s.lat,
        lon: s.lon,
        color,
        mode
      }));
      // Cumulative travel minutes from index 0
      const cumMin = new Float64Array(stops.length);
      const speedKmh = code === "M11" ? 62 : code === "B1" ? 42 : mode === "tram" ? 21 : mode === "funicular" ? 18 : 36;
      const dwellMin = mode === "funicular" ? 0.2 : 0.38;
      for (let i = 1; i < stops.length; i++) {
        const dM = haversineMeters(stops[i - 1].lat, stops[i - 1].lon, stops[i].lat, stops[i].lon) * 1.12;
        const segMin = Math.max(0.9, (dM / 1000) / speedKmh * 60 + dwellMin);
        cumMin[i] = cumMin[i - 1] + segMin;
      }
      railLines[code] = {
        code,
        mode,
        color,
        stops,
        cumMin,
        headsignFirst: stops[0].name,
        headsignLast: stops[stops.length - 1].name
      };
      for (const st of stops) railStations.push(st);
    }
  }

  // Precompute rail-to-rail transfer pairs (stations within 380 m across different lines)
  const railTransfers = new Map(); // station.id -> [{ targetStation, distM, walkMin }]
  for (let i = 0; i < railStations.length; i++) {
    const a = railStations[i];
    const list = [];
    for (let j = 0; j < railStations.length; j++) {
      if (i === j) continue;
      const b = railStations[j];
      if (a.line === b.line) continue;
      if (Math.abs(a.lat - b.lat) > 0.004 || Math.abs(a.lon - b.lon) > 0.005) continue;
      const d = haversineMeters(a.lat, a.lon, b.lat, b.lon);
      if (d <= 380) {
        list.push({ target: b, distM: Math.round(d), walkMin: Math.max(2, walkMinutes(d)) });
      }
    }
    if (list.length) railTransfers.set(a.id, list);
  }

  // 2. Ferry piers, legs & lines
  const ferryNet = (typeof FERRY_NETWORK !== "undefined" && FERRY_NETWORK) ? FERRY_NETWORK : { operators: {}, piers: {}, lines: [], legs: {} };
  const ferryPiers = [];
  for (const [id, p] of Object.entries(ferryNet.piers || {})) {
    ferryPiers.push({
      id,
      name: p.name,
      full: p.full || p.name,
      lat: p.lat,
      lon: p.lon,
      ops: p.ops || ["sh"]
    });
  }

  // 3. Bus & Metrobüs routes from LINE_ROUTES_MAP
  const busRoutes = []; // { id, line, dir, isMetrobus, stops: [stopObj...], headsign, lineName }
  const stopToRoutes = new Map(); // stopCode -> [{ rIdx, seq }]
  const routesMap = (typeof LINE_ROUTES_MAP !== "undefined" && LINE_ROUTES_MAP) ? LINE_ROUTES_MAP : {};

  for (const [lineCode, dirs] of Object.entries(routesMap)) {
    const isMb = /^34[A-Z]*$/.test(lineCode);
    const fullLineName = (typeof BUS_LINES_MAP !== "undefined" && BUS_LINES_MAP[lineCode])
      || (typeof LINE_DESTINATIONS !== "undefined" && LINE_DESTINATIONS[lineCode])
      || `${lineCode} Hattı`;

    for (const [dirKey, codes] of Object.entries(dirs || {})) {
      if (!Array.isArray(codes) || codes.length < 2) continue;
      const stops = [];
      for (const rawC of codes) {
        const st = stopMap.get(String(rawC));
        if (st && typeof st.lat === "number" && typeof st.lon === "number") {
          stops.push(st);
        }
      }
      if (stops.length < 2) continue;
      const rIdx = busRoutes.length;
      const headsign = stops[stops.length - 1].n;
      busRoutes.push({
        rIdx,
        line: lineCode,
        dir: dirKey,
        isMetrobus: isMb,
        stops,
        headsign,
        lineName: fullLineName
      });
      for (let seq = 0; seq < stops.length; seq++) {
        const sc = String(stops[seq].c);
        let arr = stopToRoutes.get(sc);
        if (!arr) { arr = []; stopToRoutes.set(sc, arr); }
        arr.push({ rIdx, seq });
      }
    }
  }

  // Also ensure METROBUS_CORRIDOR is represented if 34G wasn't in LINE_ROUTES_MAP
  const mbStops = (typeof BUS_STOPS !== "undefined" ? BUS_STOPS : []).filter(s => String(s.c).startsWith("900") || (s.y && s.y === "METROBÜS"));
  if (!routesMap["34G"] && mbStops.length >= 10) {
    // Sort West to East by lon
    const sortedW2E = mbStops.slice().sort((a, b) => a.lon - b.lon);
    // Deduplicate by name
    const uniqueW2E = [];
    const seenNames = new Set();
    for (const s of sortedW2E) {
      const k = norm(s.n);
      if (!seenNames.has(k)) { seenNames.add(k); uniqueW2E.push(s); }
    }
    if (uniqueW2E.length >= 5) {
      for (const [dirKey, list] of [["D", uniqueW2E], ["G", uniqueW2E.slice().reverse()]]) {
        const rIdx = busRoutes.length;
        busRoutes.push({
          rIdx,
          line: "34G",
          dir: dirKey,
          isMetrobus: true,
          stops: list,
          headsign: list[list.length - 1].n,
          lineName: "Beylikdüzü – Söğütlüçeşme Metrobüs"
        });
        for (let seq = 0; seq < list.length; seq++) {
          const sc = String(list[seq].c);
          let arr = stopToRoutes.get(sc);
          if (!arr) { arr = []; stopToRoutes.set(sc, arr); }
          arr.push({ rIdx, seq });
        }
      }
    }
  }

  // Pre-link each Rail Station & Ferry Pier to nearby Bus Stops (within 360 m) for fast intermodal search
  const railNearbyBusStops = new Map(); // station.id -> [{ stop, distM, walkMin }]
  for (const st of railStations) {
    const near = [];
    for (const bs of BUS_STOPS) {
      if (Math.abs(bs.lat - st.lat) > 0.0034 || Math.abs(bs.lon - st.lon) > 0.0045) continue;
      if (!stopToRoutes.has(String(bs.c))) continue;
      const d = haversineMeters(st.lat, st.lon, bs.lat, bs.lon);
      if (d <= 360) near.push({ stop: bs, distM: Math.round(d), walkMin: walkMinutes(d) });
    }
    near.sort((a, b) => a.distM - b.distM);
    if (near.length) railNearbyBusStops.set(st.id, near.slice(0, 6));
  }

  const pierNearbyBusStops = new Map(); // pier.id -> [{ stop, distM, walkMin }]
  const pierNearbyRail = new Map();     // pier.id -> [{ station, distM, walkMin }]
  for (const p of ferryPiers) {
    const nearB = [];
    for (const bs of BUS_STOPS) {
      if (Math.abs(bs.lat - p.lat) > 0.004 || Math.abs(bs.lon - p.lon) > 0.0052) continue;
      if (!stopToRoutes.has(String(bs.c))) continue;
      const d = haversineMeters(p.lat, p.lon, bs.lat, bs.lon);
      if (d <= 420) nearB.push({ stop: bs, distM: Math.round(d), walkMin: walkMinutes(d) });
    }
    nearB.sort((a, b) => a.distM - b.distM);
    if (nearB.length) pierNearbyBusStops.set(p.id, nearB.slice(0, 6));

    const nearR = [];
    for (const rs of railStations) {
      if (Math.abs(rs.lat - p.lat) > 0.0045 || Math.abs(rs.lon - p.lon) > 0.006) continue;
      const d = haversineMeters(p.lat, p.lon, rs.lat, rs.lon);
      if (d <= 480) nearR.push({ station: rs, distM: Math.round(d), walkMin: walkMinutes(d) });
    }
    nearR.sort((a, b) => a.distM - b.distM);
    if (nearR.length) pierNearbyRail.set(p.id, nearR.slice(0, 5));
  }

  transitGraphCache = {
    stopMap,
    railLines,
    railStations,
    railTransfers,
    ferryNet,
    ferryPiers,
    busRoutes,
    stopToRoutes,
    railNearbyBusStops,
    pierNearbyBusStops,
    pierNearbyRail
  };
  return transitGraphCache;
}

function railHeadwayMin(code, mode, minOfDay, dow) {
  const m = ((minOfDay % 1440) + 1440) % 1440;
  const h = Math.floor(m / 60);
  const isNightWeekend = (dow === 5 || dow === 6) && (h < 6);
  const nightLines = new Set(["M1A", "M1B", "M2", "M4", "M5", "M6", "M7"]);
  if (m < 360 && m >= 30) {
    if (isNightWeekend && nightLines.has(code)) return 30;
    return null; // closed between 00:30 and 06:00
  }
  if (code === "B1") {
    if ((h >= 7 && h <= 9) || (h >= 16 && h <= 19)) return 7;
    if (h >= 22 || h < 6) return 15;
    return 8;
  }
  if (code === "M11") return 20;
  if (mode === "funicular") return 8;
  if (mode === "tram") {
    if ((h >= 7 && h <= 9) || (h >= 16 && h <= 19)) return 4;
    if (h >= 22) return 10;
    return 6;
  }
  if ((h >= 7 && h <= 9) || (h >= 16 && h <= 19)) return 4;
  if (h >= 22 || h < 6) return 10;
  return 6;
}

function scheduleRailLeg(rl, fromIdx, toIdx, readyMin, dow) {
  if (fromIdx === toIdx) return null;
  let hw = railHeadwayMin(rl.code, rl.mode, readyMin, dow);
  let baseReady = readyMin;
  if (hw === null) {
    // Wait until 06:00 opening if within reasonable morning window
    const m = ((readyMin % 1440) + 1440) % 1440;
    if (m >= 300 && m < 360) {
      baseReady = readyMin + (360 - m);
      hw = railHeadwayMin(rl.code, rl.mode, baseReady, dow) || 6;
    } else {
      return null;
    }
  }
  const forward = toIdx > fromIdx;
  const termOffset = Math.round(forward ? rl.cumMin[fromIdx] : (rl.cumMin[rl.stops.length - 1] - rl.cumMin[fromIdx]));
  const rel = Math.max(0, baseReady - 360 - termOffset);
  const k = Math.ceil(rel / hw);
  let depMin = 360 + k * hw + termOffset;
  if (depMin < baseReady) depMin += hw;
  const waitMin = Math.max(1, Math.round(depMin - readyMin));
  const travelMin = Math.max(2, Math.round(Math.abs(rl.cumMin[toIdx] - rl.cumMin[fromIdx])));
  const arrMin = depMin + travelMin;

  const step = forward ? 1 : -1;
  const intermediate = [];
  const coords = [];
  for (let i = fromIdx; forward ? i <= toIdx : i >= toIdx; i += step) {
    const st = rl.stops[i];
    coords.push([st.lat, st.lon]);
    if (i !== fromIdx && i !== toIdx) {
      const stMin = depMin + Math.round(Math.abs(rl.cumMin[i] - rl.cumMin[fromIdx]));
      intermediate.push({ name: st.name, code: st.id, lat: st.lat, lon: st.lon, time: fmtClockMin(stMin) });
    }
  }
  const headsign = forward ? rl.headsignLast : rl.headsignFirst;
  const opName = rl.code === "B1" ? "TCDD Marmaray" : "Metro İstanbul";
  return {
    type: rl.mode,
    line: rl.code,
    line_name: `${rl.headsignFirst} – ${rl.headsignLast}`,
    operator: opName,
    color: rl.color,
    headsign: `➔ ${headsign}`,
    from: { name: rl.stops[fromIdx].name, code: rl.stops[fromIdx].id, lat: rl.stops[fromIdx].lat, lon: rl.stops[fromIdx].lon },
    to: { name: rl.stops[toIdx].name, code: rl.stops[toIdx].id, lat: rl.stops[toIdx].lat, lon: rl.stops[toIdx].lon },
    dep_min: depMin,
    arr_min: arrMin,
    dep_time: fmtClockMin(depMin),
    arr_time: fmtClockMin(arrMin),
    wait_min: waitMin,
    duration_min: travelMin,
    stops_count: Math.abs(toIdx - fromIdx),
    intermediate_stops: intermediate,
    coords,
    schedule_note: `Sefer sıklığı: ~${hw} dk`
  };
}

function scheduleBusLeg(br, fromSeq, toSeq, readyMin, tObj, field, liveFleet, isFirstLeg) {
  if (toSeq <= fromSeq) return null;
  const stops = br.stops;
  const fromStop = stops[fromSeq];
  const toStop = stops[toSeq];

  // Calculate segment distance & traffic-aware duration
  let distM = 0;
  let travelSec = 0;
  const coords = [[fromStop.lat, fromStop.lon]];
  const stepTimesSec = [0];

  const legHour = Math.floor((((readyMin % 1440) + 1440) % 1440) / 60);
  const legT = { hour: legHour, minute: readyMin % 60, dow: tObj.dow, dayType: tObj.dayType, dateKey: tObj.dateKey };
  const dwell = br.isMetrobus ? 14 : dwellSeconds(legT);
  const sig = br.isMetrobus ? 0 : signalSecPerKm(legT);

  for (let i = fromSeq + 1; i <= toSeq; i++) {
    const a = stops[i - 1], b = stops[i];
    coords.push([b.lat, b.lon]);
    const segD = haversineMeters(a.lat, a.lon, b.lat, b.lon) * (br.isMetrobus ? 1.08 : 1.22);
    distM += segD;
    let spdKmh;
    if (br.isMetrobus) {
      spdKmh = 37;
    } else if (field && field.map && field.map.size > 0) {
      spdKmh = speedAt(field, (a.lat + b.lat) / 2, (a.lon + b.lon) / 2, legT);
    } else {
      spdKmh = priorSpeed((a.lat + b.lat) / 2, (a.lon + b.lon) / 2, legT);
    }
    const segSec = (segD / (Math.max(8, spdKmh) / 3.6)) + (segD / 1000) * sig + (i < toSeq ? dwell : 0);
    travelSec += segSec;
    stepTimesSec.push(travelSec);
  }

  const travelMin = Math.max(2, Math.round(travelSec / 60));

  // Determine wait time & exact departure minute
  let waitMin = 5;
  let depMin = readyMin + waitMin;
  let liveBusInfo = null;
  let scheduleNote = "";

  if (br.isMetrobus) {
    const m = ((readyMin % 1440) + 1440) % 1440;
    const hw = (m >= 360 && m <= 1410) ? 2 : 6;
    waitMin = Math.max(1, Math.ceil(hw / 2));
    depMin = readyMin + waitMin;
    scheduleNote = `7/24 Metrobüs · ~${hw} dk sıklık`;
  } else {
    const m = ((readyMin % 1440) + 1440) % 1440;
    // Check if regular bus operates at this hour (05:45 - 00:15, plus night lines)
    if (m < 340 && m > 30 && !/^(15F|19S|25G|40|500T|11ÜS|130A|E-\d+)$/.test(br.line)) {
      return null;
    }
    // Check live fleet if departing now and first transit leg
    if (isFirstLeg && liveFleet && liveFleet.length) {
      let bestEtaMin = Infinity;
      let bestBus = null;
      for (const b of liveFleet) {
        if ((b.a || 0) > 360) continue;
        const bLines = getBusLines(b);
        if (!bLines.includes(br.line)) continue;
        const dToBoard = haversineMeters(b.lat, b.lon, fromStop.lat, fromStop.lon);
        if (dToBoard > 6500) continue;
        // Check if bus is before or near boarding stop along stop sequence
        let nearestSeq = -1, minStopD = Infinity;
        const searchLo = Math.max(0, fromSeq - 18);
        const searchHi = Math.min(stops.length - 1, fromSeq + 2);
        for (let s = searchLo; s <= searchHi; s++) {
          const sd = haversineMeters(b.lat, b.lon, stops[s].lat, stops[s].lon);
          if (sd < minStopD) { minStopD = sd; nearestSeq = s; }
        }
        if (nearestSeq >= 0 && nearestSeq <= fromSeq && minStopD <= 450) {
          const etaM = Math.max(1, Math.round((dToBoard * 1.2) / (Math.max(12, b.s || 18) / 3.6 * 60)));
          if (etaM <= 25 && etaM < bestEtaMin) {
            bestEtaMin = etaM;
            bestBus = b;
          }
        }
      }
      if (bestBus) {
        waitMin = bestEtaMin;
        depMin = readyMin + waitMin;
        liveBusInfo = { id: bestBus.id, plate: bestBus.p || "", eta_min: bestEtaMin, speed: bestBus.s || 0 };
        scheduleNote = `Canlı araç yaklaşıyor (${bestBus.id} · ${bestEtaMin} dk)`;
      }
    }

    if (!liveBusInfo) {
      // Deterministic scheduled clock departure based on line hash & time-of-day headway
      let hash = 0;
      for (let i = 0; i < br.line.length; i++) hash = (hash * 31 + br.line.charCodeAt(i)) & 0xffff;
      const isPeakH = (legHour >= 7 && legHour <= 9) || (legHour >= 16 && legHour <= 19);
      const isTrunk = /^(11ÜS|14[A-Z]*|15[A-Z]*|19[A-Z]*|500T|32|36[A-Z]*|76[A-Z]*|79[A-Z]*|89[A-Z]*|97[A-Z]*|130[A-Z]*|251|522[A-Z]*|E-\d+)$/.test(br.line);
      const hw = isPeakH ? (isTrunk ? 8 : 12) : (legHour >= 21 ? 20 : (isTrunk ? 10 : 15));
      const phase = (hash + fromSeq * 2) % hw;
      const rem = ((readyMin - phase) % hw + hw) % hw;
      waitMin = rem === 0 ? hw : (hw - rem);
      if (waitMin < 1) waitMin += hw;
      depMin = readyMin + waitMin;
      scheduleNote = `Planlanan sefer (~${hw} dk sıklık)`;
    }
  }

  const arrMin = depMin + travelMin;
  const intermediate = [];
  for (let i = fromSeq + 1; i < toSeq; i++) {
    const st = stops[i];
    const stMin = depMin + Math.round(stepTimesSec[i - fromSeq] / 60);
    intermediate.push({ name: st.n, code: String(st.c), lat: st.lat, lon: st.lon, time: fmtClockMin(stMin) });
  }

  return {
    type: br.isMetrobus ? "metrobus" : "bus",
    line: br.line,
    line_name: br.lineName,
    operator: br.isMetrobus ? "İETT Metrobüs" : "İETT",
    color: br.isMetrobus ? "#f97316" : "#0891b2",
    headsign: `➔ ${br.headsign}`,
    from: { name: fromStop.n, code: String(fromStop.c), lat: fromStop.lat, lon: fromStop.lon },
    to: { name: toStop.n, code: String(toStop.c), lat: toStop.lat, lon: toStop.lon },
    dep_min: depMin,
    arr_min: arrMin,
    dep_time: fmtClockMin(depMin),
    arr_time: fmtClockMin(arrMin),
    wait_min: waitMin,
    duration_min: travelMin,
    stops_count: toSeq - fromSeq,
    intermediate_stops: intermediate,
    coords,
    live_bus: liveBusInfo,
    schedule_note: scheduleNote
  };
}

function scheduleFerryLeg(ferryNet, fromPierId, toPierId, readyMin, weekday, maxWaitMin) {
  const piers = ferryNet.piers || {};
  const fromPier = piers[fromPierId];
  const toPier = piers[toPierId];
  if (!fromPier || !toPier) return null;

  const dayBit = 1 << (weekday - 1);
  let best = null;

  for (const line of (ferryNet.lines || [])) {
    if (!line.piers || !line.piers.includes(fromPierId) || !line.piers.includes(toPierId)) continue;
    for (const pat of (line.patterns || [])) {
      for (const trip of (pat.trips || [])) {
        if (((trip.d || 127) & dayBit) === 0) continue;
        const stops = trip.s || [];
        let iFrom = -1, iTo = -1;
        for (let i = 0; i < stops.length; i++) {
          if (stops[i][0] === fromPierId && iFrom < 0) iFrom = i;
          else if (stops[i][0] === toPierId && iFrom >= 0) { iTo = i; break; }
        }
        if (iFrom < 0 || iTo <= iFrom) continue;
        const depMin = stops[iFrom][1];
        const arrMin = stops[iTo][1];
        if (arrMin <= depMin) continue;
        const wait = depMin - readyMin;
        if (wait < 0 || wait > (maxWaitMin || 90)) continue;
        if (!best || arrMin < best.arrMin || (arrMin === best.arrMin && wait < best.wait)) {
          best = { line, pat, trip, stops, iFrom, iTo, depMin, arrMin, wait };
        }
      }
    }
  }

  if (!best) return null;
  const { line, stops, iFrom, iTo, depMin, arrMin, wait } = best;
  const op = (ferryNet.operators && ferryNet.operators[line.op]) || { name: "Şehir Hatları", short: "ŞH", color: "#0B5CAD" };
  const lastPierId = stops[stops.length - 1][0];
  const headsignPier = piers[lastPierId] ? piers[lastPierId].name : toPier.name;

  // Build sea route coordinates & intermediate piers
  const coords = [];
  const intermediate = [];
  for (let i = iFrom; i < iTo; i++) {
    const pA = stops[i][0], pB = stops[i + 1][0];
    const legKey = `${pA}|${pB}`;
    const revKey = `${pB}|${pA}`;
    let seg = [];
    if (ferryNet.legs && ferryNet.legs[legKey]) {
      seg = decodeGooglePolyline(ferryNet.legs[legKey]);
    } else if (ferryNet.legs && ferryNet.legs[revKey]) {
      seg = decodeGooglePolyline(ferryNet.legs[revKey]).reverse();
    } else if (piers[pA] && piers[pB]) {
      seg = [[piers[pA].lat, piers[pA].lon], [piers[pB].lat, piers[pB].lon]];
    }
    for (const pt of seg) {
      if (!coords.length || coords[coords.length - 1][0] !== pt[0] || coords[coords.length - 1][1] !== pt[1]) {
        coords.push(pt);
      }
    }
    if (i > iFrom) {
      const mp = piers[pA];
      if (mp) intermediate.push({ name: mp.name, code: pA, lat: mp.lat, lon: mp.lon, time: fmtClockMin(stops[i][1]) });
    }
  }
  if (coords.length < 2) {
    coords.push([fromPier.lat, fromPier.lon], [toPier.lat, toPier.lon]);
  }

  return {
    type: "ferry",
    line: `${op.short || "Vapur"} ${line.name.split("–")[0].trim()}`,
    line_code: line.id,
    line_name: line.name,
    operator: op.name,
    color: op.color || "#0B5CAD",
    headsign: `➔ ${headsignPier} İskelesi`,
    from: { name: `${fromPier.name} İskelesi`, code: fromPierId, lat: fromPier.lat, lon: fromPier.lon },
    to: { name: `${toPier.name} İskelesi`, code: toPierId, lat: toPier.lat, lon: toPier.lon },
    dep_min: depMin,
    arr_min: arrMin,
    dep_time: fmtClockMin(depMin),
    arr_time: fmtClockMin(arrMin),
    wait_min: Math.round(wait),
    duration_min: Math.max(1, arrMin - depMin),
    stops_count: iTo - iFrom,
    intermediate_stops: intermediate,
    coords,
    schedule_note: `${op.name} resmi tarife (${fmtClockMin(depMin)} seferi)`
  };
}

function makeWalkLeg(fromName, fromLat, fromLon, toName, toLat, toLon, startMin) {
  const distM = Math.round(haversineMeters(fromLat, fromLon, toLat, toLon));
  if (distM < 25) return null;
  const durMin = walkMinutes(distM);
  return {
    type: "walk",
    line: "Yürüyüş",
    line_name: `${toName} yönüne yürüyüş`,
    operator: "",
    color: "#64748b",
    headsign: `➔ ${toName}`,
    from: { name: fromName, lat: fromLat, lon: fromLon },
    to: { name: toName, lat: toLat, lon: toLon },
    dep_min: startMin,
    arr_min: startMin + durMin,
    dep_time: fmtClockMin(startMin),
    arr_time: fmtClockMin(startMin + durMin),
    wait_min: 0,
    duration_min: durMin,
    dist_m: distM,
    stops_count: 0,
    intermediate_stops: [],
    instruction: `${toName} noktasına ${durMin} dk yürü (${distM} m)`,
    coords: [[fromLat, fromLon], [toLat, toLon]]
  };
}

function assembleItinerary(transitLegs, fromPt, toPt, startMin) {
  if (!transitLegs.length) return null;
  const allLegs = [];
  const firstT = transitLegs[0];
  const w0 = makeWalkLeg(fromPt.name, fromPt.lat, fromPt.lon, firstT.from.name, firstT.from.lat, firstT.from.lon, startMin);
  if (w0) {
    // Adjust w0 so it ends right before boarding or starts at startMin
    w0.dep_min = startMin;
    w0.arr_min = startMin + w0.duration_min;
    w0.dep_time = fmtClockMin(w0.dep_min);
    w0.arr_time = fmtClockMin(w0.arr_min);
    allLegs.push(w0);
  }

  for (let i = 0; i < transitLegs.length; i++) {
    const leg = transitLegs[i];
    allLegs.push(leg);
    if (i < transitLegs.length - 1) {
      const next = transitLegs[i + 1];
      const wMid = makeWalkLeg(leg.to.name, leg.to.lat, leg.to.lon, next.from.name, next.from.lat, next.from.lon, leg.arr_min);
      if (wMid) allLegs.push(wMid);
    }
  }

  const lastT = transitLegs[transitLegs.length - 1];
  const wEnd = makeWalkLeg(lastT.to.name, lastT.to.lat, lastT.to.lon, toPt.name, toPt.lat, toPt.lon, lastT.arr_min);
  if (wEnd) allLegs.push(wEnd);

  const depMin = w0 ? Math.max(startMin, firstT.dep_min - w0.duration_min - Math.min(firstT.wait_min, 3)) : firstT.dep_min;
  if (w0) {
    w0.dep_min = depMin;
    w0.arr_min = depMin + w0.duration_min;
    w0.dep_time = fmtClockMin(w0.dep_min);
    w0.arr_time = fmtClockMin(w0.arr_min);
  }
  const arrMin = allLegs[allLegs.length - 1].arr_min;
  const durationMin = Math.max(1, arrMin - depMin);
  let walkMin = 0;
  for (const l of allLegs) if (l.type === "walk") walkMin += l.duration_min;

  const modes = transitLegs.map(l => ({
    type: l.type,
    line: l.line,
    color: l.color,
    headsign: l.headsign
  }));

  const sig = transitLegs.map(l => `${l.type}:${l.line}`).join("|");
  const transfers = transitLegs.length - 1;
  // Score penalizes transfers & long walks slightly to surface clean routes
  const score = arrMin + transfers * 7 + walkMin * 0.6;

  return {
    signature: sig,
    dep_min: depMin,
    arr_min: arrMin,
    dep_time: fmtClockMin(depMin),
    arr_time: fmtClockMin(arrMin),
    duration_min: durationMin,
    walk_min: walkMin,
    transfers,
    modes,
    legs: allLegs,
    score
  };
}

function searchItinerariesAtStart(g, fromPt, toPt, startMin, tObj, weekday, field, liveFleet, isNow) {
  const candidates = [];

  // 1. Find nearby origin & destination access points
  const origStops = [];
  const destStops = [];
  for (const bs of BUS_STOPS) {
    if (!g.stopToRoutes.has(String(bs.c))) continue;
    if (Math.abs(bs.lat - fromPt.lat) <= 0.011 && Math.abs(bs.lon - fromPt.lon) <= 0.014) {
      const d = haversineMeters(fromPt.lat, fromPt.lon, bs.lat, bs.lon);
      if (d <= 1100) origStops.push({ stop: bs, distM: d, walkMin: d < 25 ? 0 : walkMinutes(d) });
    }
    if (Math.abs(bs.lat - toPt.lat) <= 0.011 && Math.abs(bs.lon - toPt.lon) <= 0.014) {
      const d = haversineMeters(toPt.lat, toPt.lon, bs.lat, bs.lon);
      if (d <= 1100) destStops.push({ stop: bs, distM: d, walkMin: d < 25 ? 0 : walkMinutes(d) });
    }
  }
  origStops.sort((a, b) => a.distM - b.distM);
  destStops.sort((a, b) => a.distM - b.distM);
  const topOrigStops = origStops.slice(0, 14);
  const topDestStops = destStops.slice(0, 14);

  const origRail = [];
  const destRail = [];
  for (const rs of g.railStations) {
    const d1 = haversineMeters(fromPt.lat, fromPt.lon, rs.lat, rs.lon);
    if (d1 <= 1350) origRail.push({ station: rs, distM: d1, walkMin: d1 < 25 ? 0 : walkMinutes(d1) });
    const d2 = haversineMeters(toPt.lat, toPt.lon, rs.lat, rs.lon);
    if (d2 <= 1350) destRail.push({ station: rs, distM: d2, walkMin: d2 < 25 ? 0 : walkMinutes(d2) });
  }
  origRail.sort((a, b) => a.distM - b.distM);
  destRail.sort((a, b) => a.distM - b.distM);
  const topOrigRail = origRail.slice(0, 8);
  const topDestRail = destRail.slice(0, 8);

  const origPiers = [];
  const destPiers = [];
  for (const p of g.ferryPiers) {
    const d1 = haversineMeters(fromPt.lat, fromPt.lon, p.lat, p.lon);
    if (d1 <= 1400) origPiers.push({ pier: p, distM: d1, walkMin: d1 < 25 ? 0 : walkMinutes(d1) });
    const d2 = haversineMeters(toPt.lat, toPt.lon, p.lat, p.lon);
    if (d2 <= 1400) destPiers.push({ pier: p, distM: d2, walkMin: d2 < 25 ? 0 : walkMinutes(d2) });
  }
  origPiers.sort((a, b) => a.distM - b.distM);
  destPiers.sort((a, b) => a.distM - b.distM);
  const topOrigPiers = origPiers.slice(0, 6);
  const topDestPiers = destPiers.slice(0, 6);

  // Map destination bus routes: rIdx -> best { seq, stop, walkMin }
  const destRouteMap = new Map();
  for (const ds of topDestStops) {
    const entries = g.stopToRoutes.get(String(ds.stop.c)) || [];
    for (const { rIdx, seq } of entries) {
      const prev = destRouteMap.get(rIdx);
      if (!prev || ds.walkMin < prev.walkMin) {
        destRouteMap.set(rIdx, { seq, stop: ds.stop, walkMin: ds.walkMin });
      }
    }
  }

  // ── A. Direct Rail (1 leg) ──
  const seenDirectRail = new Set();
  for (const oR of topOrigRail) {
    for (const dR of topDestRail) {
      if (oR.station.line !== dR.station.line || oR.station.idx === dR.station.idx) continue;
      if (seenDirectRail.has(oR.station.line)) continue;
      seenDirectRail.add(oR.station.line);
      const rl = g.railLines[oR.station.line];
      const leg1 = scheduleRailLeg(rl, oR.station.idx, dR.station.idx, startMin + oR.walkMin, tObj.dow);
      if (leg1) {
        const it = assembleItinerary([leg1], fromPt, toPt, startMin);
        if (it) candidates.push(it);
      }
    }
  }

  // ── B. Rail ➔ Rail (2 legs, 1 transfer) ──
  const seenRail2 = new Set();
  for (const oR of topOrigRail) {
    const rl1 = g.railLines[oR.station.line];
    if (!rl1) continue;
    for (const stMid of rl1.stops) {
      if (stMid.idx === oR.station.idx) continue;
      const xfers = g.railTransfers.get(stMid.id) || [];
      for (const xf of xfers) {
        for (const dR of topDestRail) {
          if (xf.target.line !== dR.station.line || xf.target.idx === dR.station.idx) continue;
          const key = `${rl1.code}>${xf.target.line}`;
          if (seenRail2.has(key)) continue;
          seenRail2.add(key);
          const leg1 = scheduleRailLeg(rl1, oR.station.idx, stMid.idx, startMin + oR.walkMin, tObj.dow);
          if (!leg1) continue;
          const rl2 = g.railLines[xf.target.line];
          const leg2 = scheduleRailLeg(rl2, xf.target.idx, dR.station.idx, leg1.arr_min + xf.walkMin, tObj.dow);
          if (!leg2) continue;
          const it = assembleItinerary([leg1, leg2], fromPt, toPt, startMin);
          if (it) candidates.push(it);
        }
      }
    }
  }

  // ── C. Direct Bus / Metrobüs (1 leg) ──
  const seenDirectBus = new Set();
  for (const oS of topOrigStops) {
    const entries = g.stopToRoutes.get(String(oS.stop.c)) || [];
    for (const { rIdx, seq: oSeq } of entries) {
      const dMatch = destRouteMap.get(rIdx);
      if (!dMatch || dMatch.seq <= oSeq) continue;
      const br = g.busRoutes[rIdx];
      if (seenDirectBus.has(br.line)) continue;
      seenDirectBus.add(br.line);
      const leg1 = scheduleBusLeg(br, oSeq, dMatch.seq, startMin + oS.walkMin, tObj, field, liveFleet, isNow);
      if (leg1) {
        const it = assembleItinerary([leg1], fromPt, toPt, startMin);
        if (it) candidates.push(it);
      }
    }
  }

  // ── D. Direct Ferry (1 leg) ──
  for (const oP of topOrigPiers) {
    for (const dP of topDestPiers) {
      if (oP.pier.id === dP.pier.id) continue;
      const leg1 = scheduleFerryLeg(g.ferryNet, oP.pier.id, dP.pier.id, startMin + oP.walkMin, weekday, 90);
      if (leg1) {
        const it = assembleItinerary([leg1], fromPt, toPt, startMin);
        if (it) candidates.push(it);
      }
    }
  }

  // ── E. Ferry + Rail / Rail + Ferry (2 legs) ──
  for (const oP of topOrigPiers) {
    for (const dR of topDestRail) {
      const rl2 = g.railLines[dR.station.line];
      if (!rl2) continue;
      for (const pMid of g.ferryPiers) {
        if (pMid.id === oP.pier.id) continue;
        const nearR = (g.pierNearbyRail.get(pMid.id) || []).find(x => x.station.line === rl2.code && x.station.idx !== dR.station.idx);
        if (!nearR) continue;
        const leg1 = scheduleFerryLeg(g.ferryNet, oP.pier.id, pMid.id, startMin + oP.walkMin, weekday, 75);
        if (!leg1) continue;
        const leg2 = scheduleRailLeg(rl2, nearR.station.idx, dR.station.idx, leg1.arr_min + nearR.walkMin, tObj.dow);
        if (!leg2) continue;
        const it = assembleItinerary([leg1, leg2], fromPt, toPt, startMin);
        if (it) candidates.push(it);
      }
    }
  }

  for (const oR of topOrigRail) {
    const rl1 = g.railLines[oR.station.line];
    if (!rl1) continue;
    for (const dP of topDestPiers) {
      for (const pMid of g.ferryPiers) {
        if (pMid.id === dP.pier.id) continue;
        const nearR = (g.pierNearbyRail.get(pMid.id) || []).find(x => x.station.line === rl1.code && x.station.idx !== oR.station.idx);
        if (!nearR) continue;
        const leg1 = scheduleRailLeg(rl1, oR.station.idx, nearR.station.idx, startMin + oR.walkMin, tObj.dow);
        if (!leg1) continue;
        const leg2 = scheduleFerryLeg(g.ferryNet, pMid.id, dP.pier.id, leg1.arr_min + nearR.walkMin, weekday, 75);
        if (!leg2) continue;
        const it = assembleItinerary([leg1, leg2], fromPt, toPt, startMin);
        if (it) candidates.push(it);
      }
    }
  }

  // ── F. Bus ➔ Rail (2 legs) ──
  // Find origin bus routes and see which rail stations on destRail's lines they pass near
  const origBusRoutes = [];
  const seenOrigRIdx = new Set();
  for (const oS of topOrigStops.slice(0, 8)) {
    for (const { rIdx, seq } of (g.stopToRoutes.get(String(oS.stop.c)) || [])) {
      if (seenOrigRIdx.has(rIdx)) continue;
      seenOrigRIdx.add(rIdx);
      origBusRoutes.push({ rIdx, oSeq: seq, oWalk: oS.walkMin });
    }
  }

  const seenBusRail = new Set();
  for (const dR of topDestRail.slice(0, 5)) {
    const rl = g.railLines[dR.station.line];
    if (!rl) continue;
    for (const stMid of rl.stops) {
      if (stMid.idx === dR.station.idx) continue;
      const nearBus = g.railNearbyBusStops.get(stMid.id) || [];
      for (const nb of nearBus) {
        const midRoutes = g.stopToRoutes.get(String(nb.stop.c)) || [];
        for (const { rIdx, seq: midSeq } of midRoutes) {
          const ob = origBusRoutes.find(x => x.rIdx === rIdx && midSeq > x.oSeq + 1);
          if (!ob) continue;
          const br = g.busRoutes[rIdx];
          const key = `${br.line}>${rl.code}`;
          if (seenBusRail.has(key)) continue;
          seenBusRail.add(key);
          const leg1 = scheduleBusLeg(br, ob.oSeq, midSeq, startMin + ob.oWalk, tObj, field, liveFleet, isNow);
          if (!leg1) continue;
          const leg2 = scheduleRailLeg(rl, stMid.idx, dR.station.idx, leg1.arr_min + nb.walkMin, tObj.dow);
          if (!leg2) continue;
          const it = assembleItinerary([leg1, leg2], fromPt, toPt, startMin);
          if (it) candidates.push(it);
        }
      }
    }
  }

  // ── G. Rail ➔ Bus (2 legs) ──
  const seenRailBus = new Set();
  for (const oR of topOrigRail.slice(0, 5)) {
    const rl = g.railLines[oR.station.line];
    if (!rl) continue;
    for (const stMid of rl.stops) {
      if (stMid.idx === oR.station.idx) continue;
      const nearBus = g.railNearbyBusStops.get(stMid.id) || [];
      for (const nb of nearBus) {
        const midRoutes = g.stopToRoutes.get(String(nb.stop.c)) || [];
        for (const { rIdx, seq: midSeq } of midRoutes) {
          const dMatch = destRouteMap.get(rIdx);
          if (!dMatch || dMatch.seq <= midSeq + 1) continue;
          const br = g.busRoutes[rIdx];
          const key = `${rl.code}>${br.line}`;
          if (seenRailBus.has(key)) continue;
          seenRailBus.add(key);
          const leg1 = scheduleRailLeg(rl, oR.station.idx, stMid.idx, startMin + oR.walkMin, tObj.dow);
          if (!leg1) continue;
          const leg2 = scheduleBusLeg(br, midSeq, dMatch.seq, leg1.arr_min + nb.walkMin, tObj, field, null, false);
          if (!leg2) continue;
          const it = assembleItinerary([leg1, leg2], fromPt, toPt, startMin);
          if (it) candidates.push(it);
        }
      }
    }
  }

  // ── H. Bus ➔ Ferry / Ferry ➔ Bus (2 legs) ──
  const seenBusFerry = new Set();
  for (const dP of topDestPiers.slice(0, 4)) {
    for (const pMid of g.ferryPiers) {
      if (pMid.id === dP.pier.id) continue;
      const nearBus = g.pierNearbyBusStops.get(pMid.id) || [];
      for (const nb of nearBus) {
        const midRoutes = g.stopToRoutes.get(String(nb.stop.c)) || [];
        for (const { rIdx, seq: midSeq } of midRoutes) {
          const ob = origBusRoutes.find(x => x.rIdx === rIdx && midSeq > x.oSeq + 1);
          if (!ob) continue;
          const br = g.busRoutes[rIdx];
          const key = `${br.line}>ferry:${pMid.id}>${dP.pier.id}`;
          if (seenBusFerry.has(key)) continue;
          seenBusFerry.add(key);
          const leg1 = scheduleBusLeg(br, ob.oSeq, midSeq, startMin + ob.oWalk, tObj, field, liveFleet, isNow);
          if (!leg1) continue;
          const leg2 = scheduleFerryLeg(g.ferryNet, pMid.id, dP.pier.id, leg1.arr_min + nb.walkMin, weekday, 75);
          if (!leg2) continue;
          const it = assembleItinerary([leg1, leg2], fromPt, toPt, startMin);
          if (it) candidates.push(it);
        }
      }
    }
  }

  for (const oP of topOrigPiers.slice(0, 4)) {
    for (const pMid of g.ferryPiers) {
      if (pMid.id === oP.pier.id) continue;
      const nearBus = g.pierNearbyBusStops.get(pMid.id) || [];
      for (const nb of nearBus) {
        const midRoutes = g.stopToRoutes.get(String(nb.stop.c)) || [];
        for (const { rIdx, seq: midSeq } of midRoutes) {
          const dMatch = destRouteMap.get(rIdx);
          if (!dMatch || dMatch.seq <= midSeq + 1) continue;
          const br = g.busRoutes[rIdx];
          const key = `ferry:${oP.pier.id}>${pMid.id}>${br.line}`;
          if (seenBusFerry.has(key)) continue;
          seenBusFerry.add(key);
          const leg1 = scheduleFerryLeg(g.ferryNet, oP.pier.id, pMid.id, startMin + oP.walkMin, weekday, 75);
          if (!leg1) continue;
          const leg2 = scheduleBusLeg(br, midSeq, dMatch.seq, leg1.arr_min + nb.walkMin, tObj, field, null, false);
          if (!leg2) continue;
          const it = assembleItinerary([leg1, leg2], fromPt, toPt, startMin);
          if (it) candidates.push(it);
        }
      }
    }
  }

  // ── I. Bus ➔ Bus / Bus ➔ Metrobüs (2 legs, shared stop transfer) ──
  const seenBus2 = new Set();
  for (const ob of origBusRoutes.slice(0, 24)) {
    const br1 = g.busRoutes[ob.rIdx];
    const maxSearch = Math.min(br1.stops.length, ob.oSeq + 42);
    for (let s1 = ob.oSeq + 2; s1 < maxSearch; s1++) {
      const midStop = br1.stops[s1];
      const midEntries = g.stopToRoutes.get(String(midStop.c)) || [];
      for (const { rIdx: rIdx2, seq: s2 } of midEntries) {
        if (rIdx2 === ob.rIdx) continue;
        const dMatch = destRouteMap.get(rIdx2);
        if (!dMatch || dMatch.seq <= s2 + 1) continue;
        const br2 = g.busRoutes[rIdx2];
        if (br1.line === br2.line) continue;
        const key = `${br1.line}>${br2.line}`;
        if (seenBus2.has(key)) continue;
        seenBus2.add(key);
        const leg1 = scheduleBusLeg(br1, ob.oSeq, s1, startMin + ob.oWalk, tObj, field, liveFleet, isNow);
        if (!leg1) continue;
        const leg2 = scheduleBusLeg(br2, s2, dMatch.seq, leg1.arr_min + 1, tObj, field, null, false);
        if (!leg2) continue;
        const it = assembleItinerary([leg1, leg2], fromPt, toPt, startMin);
        if (it) candidates.push(it);
      }
    }
  }

  // ── J. 3-leg Intermodal (Bus ➔ Rail ➔ Rail or Bus ➔ Rail ➔ Bus) when needed ──
  if (candidates.length < 4) {
    const seen3 = new Set();
    // Bus -> Rail -> Bus
    for (const ob of origBusRoutes.slice(0, 12)) {
      const br1 = g.busRoutes[ob.rIdx];
      for (const rl of Object.values(g.railLines)) {
        let boardSt = null, boardBusSeq = -1, boardWalk = 0;
        for (const st of rl.stops) {
          const nearB = g.railNearbyBusStops.get(st.id) || [];
          for (const nb of nearB) {
            const idx = br1.stops.findIndex((s, sq) => sq > ob.oSeq + 1 && String(s.c) === String(nb.stop.c));
            if (idx >= 0) { boardSt = st; boardBusSeq = idx; boardWalk = nb.walkMin; break; }
          }
          if (boardSt) break;
        }
        if (!boardSt) continue;
        for (const stAlight of rl.stops) {
          if (Math.abs(stAlight.idx - boardSt.idx) < 3) continue;
          const nearB2 = g.railNearbyBusStops.get(stAlight.id) || [];
          for (const nb2 of nearB2) {
            for (const { rIdx: rIdx2, seq: s2 } of (g.stopToRoutes.get(String(nb2.stop.c)) || [])) {
              const dMatch = destRouteMap.get(rIdx2);
              if (!dMatch || dMatch.seq <= s2 + 1) continue;
              const br2 = g.busRoutes[rIdx2];
              const key = `${br1.line}>${rl.code}>${br2.line}`;
              if (seen3.has(key)) continue;
              seen3.add(key);
              const leg1 = scheduleBusLeg(br1, ob.oSeq, boardBusSeq, startMin + ob.oWalk, tObj, field, liveFleet, isNow);
              if (!leg1) continue;
              const leg2 = scheduleRailLeg(rl, boardSt.idx, stAlight.idx, leg1.arr_min + boardWalk, tObj.dow);
              if (!leg2) continue;
              const leg3 = scheduleBusLeg(br2, s2, dMatch.seq, leg2.arr_min + nb2.walkMin, tObj, field, null, false);
              if (!leg3) continue;
              const it = assembleItinerary([leg1, leg2, leg3], fromPt, toPt, startMin);
              if (it) candidates.push(it);
            }
          }
        }
      }
    }
  }

  return candidates;
}

async function handleRoutePlan(env, url) {
  const fromLat = parseFloat(url.searchParams.get("fromLat"));
  const fromLon = parseFloat(url.searchParams.get("fromLon"));
  const toLat = parseFloat(url.searchParams.get("toLat"));
  const toLon = parseFloat(url.searchParams.get("toLon"));
  const fromName = (url.searchParams.get("fromName") || "Kalkış Noktası").trim();
  const toName = (url.searchParams.get("toName") || "Varış Noktası").trim();
  const mode = (url.searchParams.get("mode") || "now").toLowerCase(); // "now" | "dep" | "arr"

  if (!Number.isFinite(fromLat) || !Number.isFinite(fromLon) || !Number.isFinite(toLat) || !Number.isFinite(toLon)) {
    return json({ error: "fromLat, fromLon, toLat, toLon required" }, 400);
  }

  const nowIst = istanbulNow();
  const dateParam = (url.searchParams.get("date") || nowIst.dateKey).trim();
  const timeParam = (url.searchParams.get("time") || `${String(nowIst.hour).padStart(2, "0")}:${String(nowIst.minute).padStart(2, "0")}`).trim();

  // Parse requested date & time
  let dow = nowIst.dow;
  let dateKey = nowIst.dateKey;
  if (/^\d{4}-\d{2}-\d{2}$/.test(dateParam)) {
    dateKey = dateParam;
    const dt = new Date(`${dateParam}T12:00:00Z`);
    if (!Number.isNaN(dt.getTime())) dow = dt.getUTCDay();
  }
  const weekday = dow === 0 ? 7 : dow; // 1 = Mon .. 7 = Sun
  const dayType = dow === 0 ? "P" : dow === 6 ? "C" : "I";
  const dayLabel = dow === 0 ? "Pazar / Tatil Tarifesi" : dow === 6 ? "Cumartesi Tarifesi" : "İş Günü Tarifesi";

  let targetMin = nowIst.hour * 60 + nowIst.minute;
  if (mode !== "now" && /^\d{1,2}:\d{2}$/.test(timeParam)) {
    const [hh, mm] = timeParam.split(":").map(x => parseInt(x, 10));
    if (hh >= 0 && hh < 24 && mm >= 0 && mm < 60) targetMin = hh * 60 + mm;
  }

  const isNow = mode === "now" || (dateKey === nowIst.dateKey && Math.abs(targetMin - (nowIst.hour * 60 + nowIst.minute)) <= 10 && mode === "dep");
  const tObj = {
    hour: Math.floor(targetMin / 60) % 24,
    minute: targetMin % 60,
    dow,
    dayType,
    dateKey
  };

  const g = getTransitGraph();
  const field = isNow ? await getTrafficField(env) : null;
  const fleetObj = isNow ? await getFleet(env) : null;
  const liveFleet = fleetObj && fleetObj.list ? fleetObj.list : null;

  const fromPt = { name: fromName, lat: fromLat, lon: fromLon };
  const toPt = { name: toName, lat: toLat, lon: toLon };
  const directDistM = Math.round(haversineMeters(fromLat, fromLon, toLat, toLon));

  let rawCandidates = [];

  if (mode === "arr") {
    // For "Arrive By", search a few start windows before targetMin so arrival <= targetMin
    for (const leadMin of [35, 55, 75, 20, 95]) {
      const sMin = targetMin - leadMin;
      const batch = searchItinerariesAtStart(g, fromPt, toPt, sMin, tObj, weekday, field, null, false);
      for (const it of batch) {
        if (it.arr_min <= targetMin + 3) {
          // Prefer arrivals closest to targetMin without exceeding it
          const earlySlack = Math.max(0, targetMin - it.arr_min);
          it.score = it.duration_min + earlySlack * 0.45 + it.transfers * 7;
          rawCandidates.push(it);
        } else {
          // Shift non-ferry itinerary backward so it arrives right at targetMin
          const hasFerry = it.legs.some(l => l.type === "ferry");
          if (!hasFerry) {
            const diff = it.arr_min - targetMin;
            const shifted = searchItinerariesAtStart(g, fromPt, toPt, sMin - diff - 2, tObj, weekday, field, null, false);
            for (const sit of shifted) {
              if (sit.arr_min <= targetMin + 2) {
                sit.score = sit.duration_min + Math.max(0, targetMin - sit.arr_min) * 0.45 + sit.transfers * 7;
                rawCandidates.push(sit);
              }
            }
          }
        }
      }
    }
    if (!rawCandidates.length) {
      rawCandidates = searchItinerariesAtStart(g, fromPt, toPt, targetMin - 45, tObj, weekday, field, null, false);
    }
  } else {
    rawCandidates = searchItinerariesAtStart(g, fromPt, toPt, targetMin, tObj, weekday, field, liveFleet, isNow);
  }

  // Deduplicate by signature, keeping the best-scoring itinerary per unique line combination
  const bySig = new Map();
  for (const it of rawCandidates) {
    const prev = bySig.get(it.signature);
    if (!prev || it.score < prev.score) bySig.set(it.signature, it);
  }

  let sorted = Array.from(bySig.values()).sort((a, b) => a.score - b.score);

  // Ensure diversity (include fastest, direct if available, rail/ferry if available)
  const selected = [];
  const usedSigs = new Set();

  function pick(pred) {
    const found = sorted.find(it => !usedSigs.has(it.signature) && pred(it));
    if (found) {
      usedSigs.add(found.signature);
      selected.push(found);
    }
  }

  pick(() => true); // #1 Best overall
  pick(it => it.transfers === 0); // Direct option
  pick(it => it.modes.some(m => m.type === "ferry")); // Ferry option
  pick(it => it.modes.some(m => m.type === "metro" || m.type === "marmaray" || m.type === "tram")); // Rail option
  pick(it => it.modes.some(m => m.type === "metrobus")); // Metrobüs option
  for (const it of sorted) {
    if (selected.length >= 5) break;
    if (!usedSigs.has(it.signature)) {
      usedSigs.add(it.signature);
      selected.push(it);
    }
  }

  selected.sort((a, b) => a.score - b.score);

  // Assign descriptive minimalist tags
  let minDur = Infinity;
  for (const it of selected) if (it.duration_min < minDur) minDur = it.duration_min;

  const finalItins = selected.map((it, idx) => {
    let tag = "Alternatif";
    if (idx === 0 || it.duration_min === minDur) tag = "En Hızlı";
    else if (it.transfers === 0) tag = "Aktarmasız";
    else if (it.modes.some(m => m.type === "ferry")) tag = "Deniz Yolu";
    else if (it.modes.every(m => m.type === "metro" || m.type === "marmaray" || m.type === "tram" || m.type === "funicular")) tag = "Raylı Sistem";
    else if (it.transfers <= 1) tag = "Az Aktarma";
    return Object.assign({ id: `itin-${idx + 1}`, tag }, it);
  });

  return json({
    summary: {
      from: fromPt,
      to: toPt,
      date: dateKey,
      day_type: dayType,
      day_label: dayLabel,
      time: fmtClockMin(targetMin),
      mode,
      is_live: isNow,
      direct_dist_m: directDistM
    },
    itineraries: finalItins
  }, 200, { "cache-control": "no-store" });
}

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
      ok: f.list.length > 1000 && inBounds === f.list.length,
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
    try {
      const rows = await soap(IETT, "GetHatOtoKonum_json", { HatKodu: "15B" }, env);
      const ok = Array.isArray(rows) && (rows.length === 0 || ["kapino", "enlem", "boylam"].every(k => k in lower(rows[0])));
      return { ok, detail: `rows=${Array.isArray(rows) ? rows.length : "n/a"}`, sample: Array.isArray(rows) ? rows[0] : null };
    } catch (e) {
      const msg = String(e.message || e);
      if (msg.includes("Policy Falsified")) {
        return { ok: true, detail: "IETT gateway IP policy (line lookup uses local bus_lines_map)", sample: null };
      }
      throw e;
    }
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
    const key = resolveCartoKey(env);
    // (no KV read here: diagnostics should not consume the KV quota)
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
