// IstanbulBizim Live Transit: IETT Buses + Metro Istanbul Rail System
// Cloudflare Worker serving live GPS tracking, line search, metro schedules, and Leaflet interactive map.

const IETT = "https://api.ibb.gov.tr/iett/FiloDurum/SeferGerceklesme.asmx";
const ROUTES = "https://api.ibb.gov.tr/iett/UlasimAnaVeri/HatDurakGuzergah.asmx";
const METRO_API = "https://api.ibb.gov.tr/MetroIstanbul/api/MetroMobile/V2";
const NS = "http://tempuri.org/";
const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "Content-Type, Authorization, X-Requested-With, X-IBB-Key"
};

function esc(s) {
  return String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function unesc(s) {
  return String(s || "")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function num(v) {
  const n = parseFloat(String(v || "").replace(",", "."));
  return Number.isFinite(n) ? n : null;
}

function lower(o) {
  const r = {};
  for (const k of Object.keys(o)) r[k.toLowerCase()] = o[k];
  return r;
}

function ageSec(saat) {
  const p = String(saat || "").split(":");
  if (p.length < 3) return 99999;
  const s = (+p[0]) * 3600 + (+p[1]) * 60 + (+p[2]);
  const now = (Math.floor(Date.now() / 1000) + 10800) % 86400; // Istanbul UTC+3
  const d = (now - s + 86400) % 86400;
  return d > 43200 ? 0 : d;
}

function norm(code) {
  let c = String(code || "").trim();
  try { c = c.toLocaleUpperCase("tr-TR"); } catch (e) { c = c.toUpperCase(); }
  return c;
}

function json(obj, status = 200, extra = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: Object.assign({ "content-type": "application/json; charset=utf-8" }, CORS, extra)
  });
}

// IETT allows 100 requests per hour. Quota guard in KV.
async function quota(env) {
  const key = "q:" + Math.floor(Date.now() / 3600000);
  const n = parseInt((await env.LIVE.get(key)) || "0", 10);
  return { key, n };
}

async function spend(env, q) {
  q.n += 1;
  await env.LIVE.put(q.key, String(q.n), { expirationTtl: 7200 });
}

// SOAP caller with rate-limit retry & auth headers
async function soap(url, method, args, env) {
  let inner = "";
  if (args) {
    for (const k of Object.keys(args)) {
      inner += "<" + k + ">" + esc(args[k]) + "</" + k + ">";
    }
  }

  const body = `<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><${method} xmlns="${NS}">${inner}</${method}></soap:Body></soap:Envelope>`;

  const headers = {
    "Content-Type": "text/xml; charset=utf-8",
    "SOAPAction": `"${NS}${method}"`,
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  };

  const res = await fetch(url, { method: "POST", headers, body });
  const xml = await res.text();

  if (!res.ok) {
    throw new Error(`IETT ${method} HTTP ${res.status}: ${xml.slice(0, 300)}`);
  }

  const a = xml.indexOf("<" + method + "Result>");
  const b = xml.indexOf("</" + method + "Result>");
  if (a < 0 || b < 0) {
    // Check if SOAP fault
    const faultMatch = xml.match(/<faultstring>(.*?)<\/faultstring>/i);
    const detailMatch = xml.match(/<detail>(.*?)<\/detail>/is);
    const errMsg = faultMatch ? `${faultMatch[1]} ${detailMatch ? detailMatch[1].replace(/<[^>]+>/g, " ") : ""}` : "No result returned";
    throw new Error(`IETT ${method}: ${errMsg.trim()}`);
  }

  return JSON.parse(unesc(xml.slice(a + method.length + 8, b)));
}

async function soapWithRetry(url, method, args, env, maxRetries = 2) {
  for (let i = 0; i <= maxRetries; i++) {
    try {
      return await soap(url, method, args, env);
    } catch (e) {
      const errStr = String(e);
      const isRetryable = errStr.includes("Rate limit") || errStr.includes("Policy") || errStr.includes("HTTP 5") || errStr.includes("HTTP 429");
      if (i === maxRetries || !isRetryable) {
        throw e;
      }
      await new Promise(r => setTimeout(r, 1500 * (i + 1)));
    }
  }
}

// Fleet refresh: in-memory fast cache + KV with cacheTtl: 30 + IETT fallback (99 req/hr max)
let inMemoryBusesRaw = null;
let inMemoryMeta = null;
const MIN_REFRESH_INTERVAL_MS = 36364; // 3600s / 99 = ~36.36s

async function refreshFleet(env) {
  const meta = inMemoryMeta || (await env.LIVE.get("meta", { type: "json", cacheTtl: 30 }));
  if (meta && (Date.now() - meta.t < MIN_REFRESH_INTERVAL_MS)) {
    return meta;
  }

  // Prevent concurrent duplicate fetches
  const lockTime = parseInt((await env.LIVE.get("lock")) || "0", 10);
  if (lockTime && (Date.now() - lockTime < 30000)) {
    return meta;
  }

  const q = await quota(env);
  if (q.n >= 99) {
    console.warn(`Hourly IETT quota reached (${q.n}/100), serving cached fleet.`);
    return meta;
  }

  await env.LIVE.put("lock", String(Date.now()), { expirationTtl: 60 });

  try {
    const rows = await soapWithRetry(IETT, "GetFiloAracKonum_json", null, env);
    if (!Array.isArray(rows) || rows.length === 0) {
      return meta;
    }

    const out = [];
    for (const r of rows) {
      const lon = num(r.Boylam);
      const lat = num(r.Enlem);
      if (lon === null || lat === null || lat < 40.5 || lat > 41.6 || lon < 27.8 || lon > 29.8) continue;
      out.push({
        id: r.KapiNo,
        lat: Math.round(lat * 1e5) / 1e5,
        lon: Math.round(lon * 1e5) / 1e5,
        s: Math.round(num(r.Hiz) || 0),
        t: r.Saat,
        a: ageSec(r.Saat),
        op: r.Operator || "",
        p: r.Plaka || ""
      });
    }

    const m = { t: Date.now(), count: out.length };
    const raw = JSON.stringify(out);
    inMemoryBusesRaw = raw;
    inMemoryMeta = m;

    await env.LIVE.put("buses", raw);
    await env.LIVE.put("meta", JSON.stringify(m));
    // Increment quota counter ONLY upon successful IETT fetch
    await spend(env, q);
    return m;
  } catch (err) {
    console.error("refreshFleet error:", String(err));
    return meta;
  } finally {
    await env.LIVE.delete("lock").catch(() => {});
  }
}

async function handleBuses(request, env) {
  let meta = inMemoryMeta;
  let raw = inMemoryBusesRaw;

  // 1. If memory empty or older than 30s, check KV with cacheTtl: 30
  if (!meta || !raw || (Date.now() - meta.t >= 30000)) {
    try {
      const kvMeta = await env.LIVE.get("meta", { type: "json", cacheTtl: 30 });
      if (kvMeta && (!meta || kvMeta.t > meta.t)) {
        meta = kvMeta;
        raw = await env.LIVE.get("buses", { cacheTtl: 30 });
        inMemoryMeta = meta;
        inMemoryBusesRaw = raw;
      }
    } catch (e) {
      console.warn("KV read error:", String(e));
    }
  }

  // 2. Direct IETT fetch ONLY if no feeder pushed data for 75+ seconds
  if (!meta || (Date.now() - meta.t >= 75000)) {
    try {
      meta = (await refreshFleet(env)) || meta;
      if (meta) {
        raw = inMemoryBusesRaw || (await env.LIVE.get("buses", { cacheTtl: 30 }));
      }
    } catch (e) {
      console.error("Fleet refresh error:", String(e));
    }
  }

  if (!raw || !meta) {
    return json({ error: "İETT verisi henüz yükleniyor, lütfen birkaç saniye sonra tekrar deneyin." }, 503);
  }

  // 3. Fast ETag check: return 304 Not Modified if client is already on current batch
  const etag = `"${meta.t}"`;
  const ifNoneMatch = request && request.headers ? request.headers.get("if-none-match") : null;
  if (ifNoneMatch && (ifNoneMatch === etag || ifNoneMatch === String(meta.t))) {
    return new Response(null, {
      status: 304,
      headers: Object.assign({
        "etag": etag,
        "cache-control": "no-cache, no-store, must-revalidate",
        "access-control-expose-headers": "ETag"
      }, CORS)
    });
  }

  return new Response(`{"updated_at":${meta.t},"count":${meta.count},"source":"IBB Open Data - IETT","buses":${raw}}`, {
    headers: Object.assign({
      "content-type": "application/json; charset=utf-8",
      "etag": etag,
      "cache-control": "no-cache, no-store, must-revalidate",
      "access-control-expose-headers": "ETag"
    }, CORS)
  });
}

// Fetch line route, stops, and directions from IETT ibb.asmx (cached for 24h)
async function fetchLineRoute(code, env) {
  const key = "route:" + code;
  let cached = await env.LIVE.get(key, "json");
  if (cached && cached.directions) return cached;

  const url = "https://api.ibb.gov.tr/iett/ibb/ibb.asmx";
  const body = `<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema"><soap:Body><DurakDetay_GYY xmlns="${NS}"><hat_kodu>${esc(code)}</hat_kodu></DurakDetay_GYY></soap:Body></soap:Envelope>`;
  const headers = {
    "content-type": "text/xml; charset=utf-8",
    "soapaction": `"${NS}DurakDetay_GYY"`,
    "User-Agent": "Mozilla/5.0"
  };

  const apiKey = env.IBB_API_KEY || env.IBB_SECRET || "";
  if (apiKey) {
    headers["X-Api-Key"] = apiKey;
    headers["Authorization"] = apiKey.startsWith("Bearer ") ? apiKey : `Bearer ${apiKey}`;
  }

  let xml = "";
  try {
    const res = await fetch(url, { method: "POST", headers, body });
    xml = await res.text();
  } catch (e) {
    console.error(`Route fetch error for ${code}:`, String(e));
  }

  const dirs = {};
  const tableRe = /<Table>([\s\S]*?)<\/Table>/g;
  let m;
  while ((m = tableRe.exec(xml)) !== null) {
    const row = m[1];
    const getTag = tag => {
      const tm = new RegExp("<" + tag + ">([^<]*)<\\/" + tag + ">", "i").exec(row);
      return tm ? tm[1].trim() : "";
    };
    let yon = getTag("YON") || "D";
    if (!dirs[yon]) dirs[yon] = [];
    const lon = num(getTag("XKOORDINATI"));
    const lat = num(getTag("YKOORDINATI"));
    if (lat !== null && lon !== null && lat > 40.0 && lat < 42.0 && lon > 27.0 && lon < 30.5) {
      dirs[yon].push({
        seq: parseInt(getTag("SIRANO") || "0", 10),
        code: getTag("DURAKKODU"),
        name: getTag("DURAKADI"),
        district: getTag("ILCEADI"),
        lat,
        lon
      });
    }
  }

  const directions = {};
  for (const k of Object.keys(dirs)) {
    dirs[k].sort((a, b) => a.seq - b.seq);
    const stops = dirs[k];
    if (stops.length > 0) {
      const origin = stops[0].name;
      const destination = stops[stops.length - 1].name;
      const isOutbound = k === "G" || k === "GİDİŞ";
      directions[k] = {
        code: k,
        name: (isOutbound ? "Gidiş: " : "Dönüş: ") + destination,
        origin,
        destination,
        headsign: `${origin} ➔ ${destination}`,
        color: isOutbound ? "#a855f7" : "#06b6d4",
        stops,
        coordinates: stops.map(s => [s.lat, s.lon])
      };
    }
  }

  // Fetch official line name
  let lineName = code;
  try {
    const hBody = `<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><HatServisi_GYY xmlns="${NS}"><hat_kodu>${esc(code)}</hat_kodu></HatServisi_GYY></soap:Body></soap:Envelope>`;
    const hRes = await fetch(url, { method: "POST", headers: { "content-type": "text/xml; charset=utf-8", "soapaction": `"${NS}HatServisi_GYY"`, "User-Agent": "Mozilla/5.0" }, body: hBody });
    const hXml = await hRes.text();
    const hMatch = /<HAT_ADI>([^<]*)<\/HAT_ADI>/i.exec(hXml);
    if (hMatch && hMatch[1]) lineName = hMatch[1].trim();
  } catch (e) {}

  const routeData = {
    code,
    name: lineName,
    directions,
    total_stops: Object.values(directions).reduce((acc, d) => acc + d.stops.length, 0)
  };

  if (Object.keys(directions).length > 0) {
    await env.LIVE.put(key, JSON.stringify(routeData), { expirationTtl: 86400 }).catch(() => {});
  }
  return routeData;
}

// Geometric match for bus direction & nearest stop if not reported by GPS service
function matchBusDirection(bus, directions, lineCode = "") {
  if (!directions) return { dir: "D", dir_name: "Hat Güzergahı", headsign: "", stop: "", color: "#06b6d4" };
  const dD = directions.D;
  const dG = directions.G;
  if (!dD && !dG) return { dir: "D", dir_name: "Hat Güzergahı", headsign: "", stop: "", color: "#06b6d4" };
  if (!dD) return { dir: "G", dir_name: dG.destination || "Gidiş", headsign: dG.headsign, stop: (dG.stops && dG.stops[0]) ? dG.stops[0].name : "", color: "#a855f7" };
  if (!dG) return { dir: "D", dir_name: dD.destination || "Dönüş", headsign: dD.headsign, stop: (dD.stops && dD.stops[0]) ? dD.stops[0].name : "", color: "#06b6d4" };

  // Specialized check for Metrobüs (34, 34G, 34AS, 34BZ, 34C, 34Z, 34B, 34A)
  // Beylikdüzü is at West (lon ~28.62), Söğütlüçeşme is at East (lon ~29.04).
  const isMetrobus = lineCode.startsWith("34") || (dG.destination && dG.destination.includes("SÖĞÜTLÜ"));
  if (isMetrobus && bus.bearing != null && (bus.s || 0) >= 5) {
    // Eastbound (heading roughly 30° - 150°) -> Heading to Söğütlüçeşme (G)
    // Westbound (heading roughly 210° - 330°) -> Heading to Beylikdüzü (D)
    if (bus.bearing >= 30 && bus.bearing <= 150) {
      let minDistG = Infinity, closestStopG = null;
      for (const s of (dG.stops || [])) {
        const dist = (s.lat - bus.lat) ** 2 + (s.lon - bus.lon) ** 2;
        if (dist < minDistG) { minDistG = dist; closestStopG = s; }
      }
      return {
        dir: "G",
        dir_name: dG.destination || "Gidiş Yönü",
        headsign: dG.headsign || "",
        stop: closestStopG ? closestStopG.name : "",
        color: "#a855f7"
      };
    } else if (bus.bearing >= 210 && bus.bearing <= 330) {
      let minDistD = Infinity, closestStopD = null;
      for (const s of (dD.stops || [])) {
        const dist = (s.lat - bus.lat) ** 2 + (s.lon - bus.lon) ** 2;
        if (dist < minDistD) { minDistD = dist; closestStopD = s; }
      }
      return {
        dir: "D",
        dir_name: dD.destination || "Dönüş Yönü",
        headsign: dD.headsign || "",
        stop: closestStopD ? closestStopD.name : "",
        color: "#06b6d4"
      };
    }
  }

  let minDistD = Infinity, closestStopD = null;
  for (const s of (dD.stops || [])) {
    const dist = (s.lat - bus.lat) ** 2 + (s.lon - bus.lon) ** 2;
    if (dist < minDistD) {
      minDistD = dist;
      closestStopD = s;
    }
  }

  let minDistG = Infinity, closestStopG = null;
  for (const s of (dG.stops || [])) {
    const dist = (s.lat - bus.lat) ** 2 + (s.lon - bus.lon) ** 2;
    if (dist < minDistG) {
      minDistG = dist;
      closestStopG = s;
    }
  }

  if (minDistG < minDistD) {
    return {
      dir: "G",
      dir_name: dG.destination || "Gidiş Yönü",
      headsign: dG.headsign || "",
      stop: closestStopG ? closestStopG.name : "",
      color: "#a855f7"
    };
  } else {
    return {
      dir: "D",
      dir_name: dD.destination || "Dönüş Yönü",
      headsign: dD.headsign || "",
      stop: closestStopD ? closestStopD.name : "",
      color: "#06b6d4"
    };
  }
}

async function handleLine(env, url) {
  const code = norm(url.searchParams.get("code"));
  if (!code || code.length > 12) return json({ error: "Lütfen bir hat kodu girin (örn. 15B, 500T, 14BK)" }, 400);

  // 1. Fetch route line stops and directions (cached in KV)
  const routeData = await fetchLineRoute(code, env);

  // 2. Load door number mapping
  let map = await env.LIVE.get("bus_lines_map", "json");
  if (!map && typeof BUS_LINES_MAP !== "undefined") {
    map = BUS_LINES_MAP;
  }
  const assignedDoors = (map && map[code]) || [];
  const doorSet = new Set(assignedDoors);

  // 3. Load fleet directly from fast in-memory or KV cache
  let fleet = null;
  if (inMemoryBusesRaw) {
    try { fleet = JSON.parse(inMemoryBusesRaw); } catch (e) {}
  }
  if (!fleet) {
    const raw = await env.LIVE.get("buses", { cacheTtl: 30 });
    if (raw) {
      try { fleet = JSON.parse(raw); } catch (e) {}
    }
  }
  fleet = fleet || [];

  const busMap = new Map();

  // 4. Fallback: ONLY query slow SOAP GetHatOtoKonum if line has NO mapped doors in bus_lines_map
  if (assignedDoors.length === 0) {
    const otoKey = "line_oto:" + code;
    let otoData = await env.LIVE.get(otoKey, "json");

    if (!otoData) {
      const q = await quota(env);
      if (q.n < 95) {
        try {
          await spend(env, q);
          // Query with a 2-second timeout to never block user response
          const timeoutPromise = new Promise((_, reject) => setTimeout(() => reject(new Error("Timeout")), 2000));
          const rows = await Promise.race([soap(IETT, "GetHatOtoKonum_json", { HatKodu: code }, env), timeoutPromise]);
          if (Array.isArray(rows)) {
            otoData = rows;
            await env.LIVE.put(otoKey, JSON.stringify(otoData), { expirationTtl: 25 }).catch(() => {});
          }
        } catch (e) {
          // Graceful fallback to fleet
        }
      }
    }

    if (Array.isArray(otoData)) {
      for (const row of otoData) {
        const r = lower(row);
        const lat = num(r.enlem);
        const lon = num(r.boylam);
        if (lat === null || lon === null) continue;
        const kapi = r.kapino;
        const gCode = String(r.guzergahkodu || "");
        let dir = gCode.includes("_G_") ? "G" : (gCode.includes("_D_") ? "D" : "");
        let dirName = r.yon || "";

        if (!dir) {
          const match = matchBusDirection({ lat, lon }, routeData.directions, code);
          dir = match.dir;
          if (!dirName) dirName = match.dir_name;
        }

        const dirObj = routeData.directions && routeData.directions[dir];
        const headsign = dirObj ? dirObj.headsign : (dirName ? `➔ ${dirName}` : "");
        const color = dir === "G" ? "#a855f7" : "#06b6d4";

        busMap.set(kapi, {
          id: kapi,
          lat,
          lon,
          line: code,
          name: routeData.name,
          dir,
          dir_name: dirName,
          headsign,
          color,
          stop: r.yakindurakkodu || "",
          time: r.son_konum_zamani || "",
          s: 0,
          op: "İETT",
          p: "",
          a: 0
        });
      }
    }
  }

  for (const b of fleet) {
    if (doorSet.has(b.id) || busMap.has(b.id)) {
      const existing = busMap.get(b.id);
      if (existing) {
        existing.lat = b.lat;
        existing.lon = b.lon;
        existing.s = b.s;
        existing.time = b.t || existing.time;
        existing.op = b.op || existing.op;
        existing.p = b.p || existing.p;
        existing.a = b.a || 0;
      } else {
        const match = matchBusDirection(b, routeData.directions);
        busMap.set(b.id, {
          id: b.id,
          lat: b.lat,
          lon: b.lon,
          line: code,
          name: routeData.name,
          dir: match.dir,
          dir_name: match.dir_name,
          headsign: match.headsign,
          color: match.color,
          stop: match.stop,
          time: b.t,
          s: b.s,
          op: b.op || "İETT",
          p: b.p || "",
          a: b.a || 0
        });
      }
    }
  }

  const buses = Array.from(busMap.values());
  const meta = inMemoryMeta || (await env.LIVE.get("meta", { type: "json", cacheTtl: 30 })) || { t: Date.now() };

  return json({
    code,
    name: routeData.name,
    directions: routeData.directions,
    buses,
    count: buses.length,
    assigned_count: assignedDoors.length,
    updated_at: meta.t || Date.now(),
    source: "İETT Canlı GPS + Hat Güzergahı"
  }, 200, { "cache-control": "no-cache, no-store, must-revalidate" });
}

async function handleLineRoute(env, url) {
  const code = norm(url.searchParams.get("code"));
  if (!code || code.length > 12) return json({ error: "Lütfen bir hat kodu girin" }, 400);
  const route = await fetchLineRoute(code, env);
  return json(route, 200, { "cache-control": "public, max-age=604800, stale-while-revalidate=86400" });
}

async function handleLinesMap(env) {
  let map = await env.LIVE.get("bus_lines_map", "json");
  if (!map && typeof BUS_LINES_MAP !== "undefined") {
    map = BUS_LINES_MAP;
  }
  return json(map || {}, 200, { "cache-control": "public, max-age=3600" });
}

async function handleLines(env) {
  let c = await env.LIVE.get("lines", "json");
  if (!c) {
    c = [];
    try {
      const q = await quota(env);
      if (q.n < 99) {
        await spend(env, q);
        const rows = await soapWithRetry(ROUTES, "GetHat_json", { HatKodu: "" }, env);
        for (const row of rows) {
          const r = lower(row);
          if (r.shatkodu) c.push({ c: r.shatkodu, n: r.shatadi || "" });
        }
      }
    } catch (e) {
      console.error("Lines list error:", String(e));
    }
    await env.LIVE.put("lines", JSON.stringify(c), { expirationTtl: c.length ? 86400 : 1800 });
  }
  return json({ lines: c }, 200, { "cache-control": "public, max-age=3600" });
}

// Ingestion endpoint for local feeder or external proxy
async function handleFeed(request, env) {
  if (request.method !== "POST") return json({ error: "POST required" }, 405);
  try {
    const data = await request.json();
    if (!Array.isArray(data.buses)) return json({ error: "Invalid payload: buses array required" }, 400);

    const now = (typeof data.pushed_at === "number" && data.pushed_at > 0) ? data.pushed_at : Date.now();
    const m = { t: now, count: data.buses.length };
    const raw = JSON.stringify(data.buses);
    inMemoryBusesRaw = raw;
    inMemoryMeta = m;

    await env.LIVE.put("buses", raw);
    await env.LIVE.put("meta", JSON.stringify(m));
    return json({ success: true, count: m.count, updated_at: m.t });
  } catch (err) {
    return json({ error: String(err) }, 400);
  }
}

async function handleFeedMapping(request, env) {
  if (request.method !== "POST") return json({ error: "POST required" }, 405);
  try {
    const data = await request.json();
    if (!data || typeof data !== "object") return json({ error: "Invalid payload: mapping object required" }, 400);
    const count = Object.keys(data).length;
    await env.LIVE.put("bus_lines_map", JSON.stringify(data));
    return json({ success: true, count, updated_at: Date.now() });
  } catch (err) {
    return json({ error: String(err) }, 400);
  }
}
