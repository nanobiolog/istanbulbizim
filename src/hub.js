// ───────────────────────── TransitHub (Durable Object) ─────────────────────────
// One instance ("hub") owns everything that changes over time, so the Worker never writes to KV
// on its hot path:
//   • İETT fleet — refreshed on the hub's own alarm every ~37 s (≤ 98 calls/hour), kept in memory
//     and in the object's SQLite storage; Workers read it through /fleet (+ edge cache).
//   • Metro İstanbul official timetables — prewarmed once per service day (rail.js → KV, ~20 writes/day).
//   • Şehir Hatları — cancellations / replacement timetables every 10 min, full timetables daily.
//   • Rail network changes — new or removed lines detected weekly from OpenStreetMap.
//   • Live AIS ferries (only with AISSTREAM_API_KEY).
// Free plan: SQLite-backed Durable Objects, 100k requests/day, 100k rows written/day.

const HUB_ALARM_MS = 37000;
const HUB_CHUNK = 60000; // characters per stored row (≤ 120 KB even for 2-byte UTF-8)
const HUB_SH = "https://sehirhatlari.istanbul";
const HUB_OVERPASS = ["https://maps.mail.ru/osm/tools/overpass/api/interpreter", "https://overpass-api.de/api/interpreter"];
const HUB_UA = "IstanbulBizim/2.0 (+https://github.com/nanobiolog/istanbulbizim)";

// Şehir Hatları answers some cloud / Worker traffic with a Cloudflare challenge page instead of
// content. Never treat that page as data: throw, keep the last good copy, and back off.
async function shGet(path) {
  const res = await fetch(HUB_SH + path, { headers: { "user-agent": HUB_UA, "accept-language": "tr" } });
  const html = await res.text();
  // (normal pages also load /cdn-cgi/challenge-platform/scripts/jsd, so match only the interstitial)
  if (!res.ok || /<title>\s*Just a moment|window\._cf_chl_opt|id="challenge-form"|cf-chl-widget/i.test(html.slice(0, 30000))) {
    const err = new Error(`sehirhatlari unavailable (HTTP ${res.status}${res.ok ? ", challenge page" : ""})`);
    err.blocked = true;
    err.status = res.status;
    throw err;
  }
  return html;
}

export class TransitHub {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.fleet = null; // { raw, meta }
    this.state = {};
    this.mem = {}; // big documents (ferry status, timetables, network changes, ais)
    this.ref = {}; // bundled network files read from the static assets
    this.fleetWrites = 0;
    ctx.blockConcurrencyWhile(async () => {
      this.state = (await ctx.storage.get("state")) || {};
      this.fleet = await this.getBig("fleet");
    });
  }

  // ── storage helpers (large JSON split across rows) ──
  async putBig(key, value) {
    const str = typeof value === "string" ? value : JSON.stringify(value);
    const n = Math.max(1, Math.ceil(str.length / HUB_CHUNK));
    const entries = { [`${key}#n`]: n };
    for (let i = 0; i < n; i++) entries[`${key}#${i}`] = str.slice(i * HUB_CHUNK, (i + 1) * HUB_CHUNK);
    await this.ctx.storage.put(entries);
  }

  async getBig(key) {
    const n = await this.ctx.storage.get(`${key}#n`);
    if (!n) return null;
    const keys = Array.from({ length: n }, (_, i) => `${key}#${i}`);
    const m = await this.ctx.storage.get(keys);
    const str = keys.map((k) => m.get(k) || "").join("");
    try { return JSON.parse(str); } catch (e) { return null; }
  }

  async doc(key) {
    if (!(key in this.mem)) this.mem[key] = await this.getBig(key);
    return this.mem[key];
  }

  async setDoc(key, value) {
    this.mem[key] = value;
    await this.putBig(key, value);
  }

  async saveState() {
    await this.ctx.storage.put("state", this.state);
  }

  async ensureAlarm() {
    const a = await this.ctx.storage.getAlarm();
    if (!a) await this.ctx.storage.setAlarm(Date.now() + 500);
  }

  // ── requests from the Worker ──
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;
    try {
      if (path === "/fleet") {
        await this.ensureAlarm();
        if (!this.fleet || Date.now() - this.fleet.meta.t > 150000) await this.refreshFleet(true);
        if (!this.fleet) return new Response("fleet unavailable", { status: 503 });
        return new Response(this.fleet.raw, { headers: { "x-meta": JSON.stringify(this.fleet.meta), "content-type": "application/json" } });
      }
      if (path === "/kick") {
        await this.ensureAlarm();
        return hubJsonResponse({ ok: true, fleet_t: this.fleet ? this.fleet.meta.t : 0 });
      }
      if (path === "/push" && request.method === "POST") {
        const data = await request.json();
        await annotateFleet(data.buses, this.fleet ? this.fleet.raw : null, this.env);
        this.fleet = { raw: JSON.stringify(data.buses), meta: { t: data.t || Date.now(), count: data.buses.length } };
        await this.putBig("fleet", this.fleet);
        return hubJsonResponse({ ok: true });
      }
      if (path === "/ferries/status") {
        await this.ensureAlarm();
        return hubJsonResponse((await this.doc("ferry_status")) || { updated_at: 0, notices: [], cancelled_line_ids: [], overrides: {} });
      }
      if (path === "/ferries/timetables") {
        await this.ensureAlarm();
        return hubJsonResponse((await this.doc("sh_timetables")) || { version: "", lines: [] });
      }
      if (path === "/network/changes") {
        await this.ensureAlarm();
        return hubJsonResponse((await this.doc("network_changes")) || { checked_at: 0, added: [], removed: [], stations: {} });
      }
      if (path === "/ferries/live") {
        await this.ensureAlarm();
        const d = (await this.doc("ferries_live")) || { configured: true, updated_at: 0, vessels: [] };
        const now = Date.now();
        return hubJsonResponse(Object.assign({}, d, { vessels: (d.vessels || []).map((v) => Object.assign({}, v, { age: Math.round((now - v.t) / 1000) })) }));
      }
      if (path === "/state") {
        return hubJsonResponse({ state: this.state, fleet: this.fleet ? this.fleet.meta : null, alarm: await this.ctx.storage.getAlarm() });
      }
      return hubJsonResponse({ error: "not found" }, 404);
    } catch (e) {
      return hubJsonResponse({ error: String(e) }, 500);
    }
  }

  // ── the clock ──
  async alarm() {
    const started = Date.now();
    try {
      if (!this.fleet || started - this.fleet.meta.t >= 36000) await this.refreshFleet(false);
    } catch (e) {
      console.warn("hub fleet:", String(e));
    }
    try {
      await this.housekeeping();
    } catch (e) {
      console.warn("hub housekeeping:", String(e));
    }
    await this.ctx.storage.setAlarm(Date.now() + HUB_ALARM_MS);
  }

  async refreshFleet(force) {
    const hour = Math.floor(Date.now() / 3600000);
    if (this.state.qHour !== hour) { this.state.qHour = hour; this.state.qN = 0; }
    if (this.state.qN >= 98 && !force) return;
    const f = await fetchIettFleet(this.env, this.fleet ? this.fleet.raw : null);
    this.state.qN = (this.state.qN || 0) + 1;
    if (!f) return;
    this.fleet = f;
    // Persist every 3rd snapshot: memory serves reads; storage only matters after an eviction.
    if (++this.fleetWrites % 3 === 1) await this.putBig("fleet", f);
  }

  async housekeeping() {
    const now = Date.now();
    const s = this.state;
    let dirty = false;
    // Şehir Hatları cancellations and replacement timetables
    const statusEvery = s.shBlocked && now - s.shBlocked.at < 6 * 3600000 ? 30 * 60000 : 10 * 60000;
    if (now - (s.ferryStatusAt || 0) > statusEvery) {
      s.ferryStatusAt = now;
      dirty = true;
      await this.refreshFerryStatus().catch((e) => console.warn("ferry status:", String(e)));
    } else if (this.env.AISSTREAM_API_KEY && now - (s.aisAt || 0) > 2 * 60000) {
      s.aisAt = now;
      dirty = true;
      const prev = await this.doc("ferries_live");
      const d = await refreshFerries(this.env, 8000, prev).catch(() => null);
      if (d) await this.setDoc("ferries_live", d);
    } else if (await this.prewarmRailStep()) {
      dirty = true;
    } else if (await this.timetableStep()) {
      dirty = true;
    } else if (await this.networkStep()) {
      dirty = true;
    }
    if (dirty || now - (s.savedAt || 0) > 10 * 60000) {
      s.savedAt = now;
      await this.saveState();
    }
  }

  // ── reference data bundled with the website ──
  async asset(name) {
    if (this.ref[name]) return this.ref[name];
    const path = `/assets/assets/data/${name}`;
    let res = null;
    try {
      if (this.env.ASSETS) res = await this.env.ASSETS.fetch(new Request("https://assets.local" + path));
    } catch (e) { res = null; }
    if (!res || !res.ok) res = await fetch((this.env.PUBLIC_ORIGIN || "https://istanbulbizim.nano-carbay.workers.dev") + path);
    if (!res.ok) throw new Error(`asset ${name}: HTTP ${res.status}`);
    this.ref[name] = await res.json();
    return this.ref[name];
  }

  // ── Metro İstanbul official timetables, once per service day (one line per tick) ──
  async prewarmRailStep() {
    const day = railServiceDay();
    if (this.state.railDay !== day.dateKey) { this.state.railDay = day.dateKey; this.state.railDone = []; }
    const lines = Object.keys(typeof METRO_STATIONS !== "undefined" ? METRO_STATIONS : {}).filter((c) => c !== "B1");
    const next = lines.find((c) => !(this.state.railDone || []).includes(c));
    if (!next) return false;
    this.state.railDone.push(next);
    await getRailSchedule(next, this.env).catch((e) => console.warn(`rail ${next}:`, String(e)));
    return true;
  }

  // ── Şehir Hatları: today's cancellations + replacement timetables ──
  async refreshFerryStatus() {
    let html;
    try {
      html = await shGet("/tr/iptal-seferler");
      delete this.state.shBlocked;
    } catch (e) {
      if (!e.blocked) throw e;
      this.state.shBlocked = { at: Date.now(), status: e.status };
      const prev = await this.doc("ferry_status");
      // keep a good notice for today; otherwise publish "no data" rather than a stale or broken one
      if (!(prev && prev.available === true && prev.date === railServiceDay().dateKey)) {
        await this.setDoc("ferry_status", {
          updated_at: prev && prev.available === true ? prev.updated_at : 0,
          date: "", active: false, available: false, blocked_at: Date.now(), operator: "sh",
          message: "", cancelled_names: [], cancelled_line_ids: [], overrides: {}
        });
      }
      throw e;
    }
    const net = await this.asset("ferry_network.json");
    const main = shMainContent(html);
    const text = shText(main);
    const dm = text.match(/(\d{2})\.(\d{2})\.(\d{4})/);
    const date = dm ? `${dm[3]}-${dm[2]}-${dm[1]}` : "";
    const today = railServiceDay().dateKey;
    const label = main.search(/İptal Seferler\s*:/i);
    const listPart = label >= 0 ? main.slice(label).replace(/^İptal Seferler\s*:/i, "") : "";
    const beforeTables = listPart.split(/<table/i)[0] || "";
    const names = [];
    for (const raw of shText(beforeTables).split(/\s*[|\n]\s*/)) {
      const x = raw.trim();
      if (!x) continue;
      if (/HATTI\b|Tarihi Yap|\d{2}\.\d{2}\.\d{4}/.test(x)) break; // replacement timetables start here
      if (x.length < 80 && /[a-zçğıöşü]/i.test(x) && !/yolcu|bilgi|sunarız|duyuru/i.test(x)) names.push(x);
    }
    const headText = shText(label >= 0 ? main.slice(0, label) : main);
    const message = headText.replace(/^[\s\S]*?\d{2}\.\d{2}\.\d{4}/, "").replace(/\s+/g, " ").trim().slice(0, 600);
    const shLines = net.lines.filter((l) => l.op === "sh");
    const cancelled = new Set();
    const matchedNames = [];
    for (const n of names) {
      const ids = shMatchLines(n, shLines, net.piers);
      if (ids.length) { ids.forEach((i) => cancelled.add(i)); matchedNames.push(n); }
    }
    // replacement timetables published on the same page ("… HATTI · dd.mm.yyyy Tarihi Yapılır")
    const overrides = {};
    const re = /<table[\s\S]*?<\/table>/gi;
    let m;
    while ((m = re.exec(main))) {
      const tables = shParseTables(m[0]);
      if (!tables.length) continue;
      let title = tables[0].title;
      if (!title) {
        const before = shText(main.slice(Math.max(0, m.index - 600), m.index));
        const hm = before.match(/([A-ZÇĞİÖŞÜ][A-ZÇĞİÖŞÜa-zçğıöşü\s\-]+?)\s+HATTI/);
        title = hm ? hm[1] : "";
      }
      if (!title) continue;
      const ids = shMatchLines(title.replace(/\s*HATTI\s*$/i, ""), shLines, net.piers);
      if (!ids.length) continue;
      const patterns = shTablesToPatterns(tables, title, net, true);
      if (patterns.length) for (const id of ids) overrides[id] = { date: date || today, patterns };
    }
    const active = !date || date >= today;
    await this.setDoc("ferry_status", {
      updated_at: Date.now(),
      date: date || today,
      active,
      available: true,
      operator: "sh",
      source: HUB_SH + "/tr/iptal-seferler",
      message: active ? message : "",
      cancelled_names: active ? names : [],
      cancelled_line_ids: active ? Array.from(cancelled) : [],
      overrides: active ? overrides : {},
      unmatched: names.filter((n) => !matchedNames.includes(n))
    });
  }

  // ── Şehir Hatları: full timetables, re-read once a day (one page per tick) ──
  async timetableStep() {
    const day = railServiceDay().dateKey;
    const st = this.state.sh || {};
    if (st.done === day) return false;
    if (st.retryAt && Date.now() < st.retryAt) return false;
    const net = await this.asset("ferry_network.json");
    if (st.day !== day || !st.pages) {
      let idx;
      try {
        idx = await shGet("/tr/seferler/ic-hatlar");
      } catch (e) {
        if (!e.blocked) throw e;
        this.state.sh = { day, retryAt: Date.now() + 3 * 3600000, blocked: e.status };
        return true;
      }
      const pages = Array.from(new Set((idx.match(/href="(\/tr\/seferler\/ic-hatlar\/[a-z-]+\/[a-z0-9-]+-\d+)"/g) || []).map((h) => h.slice(6, -1))));
      this.state.sh = { day, pages, i: 0, lines: [] };
      this.mem.sh_partial = [];
      return true;
    }
    if (!this.mem.sh_partial) this.mem.sh_partial = (await this.getBig("sh_partial")) || [];
    if (st.i < st.pages.length) {
      const href = st.pages[st.i++];
      try {
        const html = await shGet(href);
        const tm = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || html.match(/<title>([\s\S]*?)<\/title>/);
        const title = tm ? shText(tm[1]).replace(/\s*[-|]\s*Şehir Hatları.*$/, "").trim() : href;
        const tables = shParseTables(html);
        const patterns = shTablesToPatterns(tables, title, net, false);
        if (patterns.length) {
          const slug = href.split("/").pop();
          const piers = [];
          for (const p of patterns) for (const t of p.trips) for (const [pid] of t.s) if (!piers.includes(pid)) piers.push(pid);
          this.mem.sh_partial.push({ id: "sh-" + slug, op: "sh", name: shTitle(title), src: "Şehir Hatları güncel tarife", official: true, url: HUB_SH + href, patterns, piers });
        }
      } catch (e) {
        console.warn("sh page", href, String(e));
        if (e.blocked) { st.i--; st.retryAt = Date.now() + 3 * 3600000; st.blocked = e.status; }
      }
      await this.putBig("sh_partial", this.mem.sh_partial);
      return true;
    }
    const lines = this.mem.sh_partial || [];
    if (lines.length >= Math.max(5, (net.lines.filter((l) => l.op === "sh").length) * 0.6)) {
      await this.setDoc("sh_timetables", { version: day, generated_at: Date.now(), lines });
    }
    this.state.sh = { done: day };
    this.mem.sh_partial = [];
    await this.putBig("sh_partial", []);
    return true;
  }

  // ── Rail network: new / removed lines from OpenStreetMap, weekly ──
  async networkStep() {
    const now = Date.now();
    const st = this.state.net || {};
    if (st.queue && st.queue.length) {
      const rid = st.queue.shift();
      this.state.net = st;
      try {
        const line = await osmBuildVariant(rid);
        if (line) {
          const doc = (await this.doc("network_changes_partial")) || { variants: [] };
          doc.variants.push(line);
          await this.setDoc("network_changes_partial", doc);
        }
      } catch (e) {
        console.warn("osm relation", rid, String(e));
      }
      if (!st.queue.length) await this.finishNetwork();
      return true;
    }
    if (now - (st.checkedAt || 0) < 7 * 86400000) return false;
    if (st.failedAt && now - st.failedAt < 6 * 3600000) return false;
    const q = '[out:json][timeout:60];relation["type"="route"]["route"~"^(subway|light_rail|tram|train|funicular|monorail|aerialway)$"](40.75,28.40,41.30,29.50);out tags;';
    let rels = null;
    for (const ep of HUB_OVERPASS) {
      try {
        const res = await fetch(ep, { method: "POST", body: "data=" + encodeURIComponent(q), headers: { "content-type": "application/x-www-form-urlencoded", "user-agent": HUB_UA } });
        if (res.ok) { const j = await res.json(); if (j.elements) { rels = j.elements; break; } }
      } catch (e) {}
    }
    if (!rels) { this.state.net = Object.assign(st, { failedAt: now }); return true; }
    const rail = await this.asset("rail_network.json");
    const bundled = new Map(); // relation id -> line code
    for (const l of rail.lines) for (const v of l.variants) bundled.set(v.id, l.code);
    const lineRef = /^(M\d{1,2}[A-Z]?|T\d|F\d|B\d|TF\d)$/;
    const current = rels.filter((r) => {
      const t = r.tags || {};
      if (t.state === "proposed" || t.state === "construction" || /Ulaşım Park/i.test(t.operator || "")) return false;
      const ref = (t.ref || "").trim();
      return lineRef.test(ref) || /marmaray/i.test(t.network || t.name || "");
    });
    const currentIds = new Set(current.map((r) => r.id));
    const added = current.filter((r) => !bundled.has(r.id) && !rail.lines.some((l) => l.code === (r.tags.ref || "").trim()));
    let removedCodes = [];
    for (const l of rail.lines) {
      if (l.variants.every((v) => !currentIds.has(v.id))) removedCodes.push(l.code);
    }
    // A truncated Overpass answer must not hide half the network: only trust small, plausible diffs.
    if (removedCodes.length > 3 || current.length < bundled.size * 0.7) removedCodes = [];
    this.state.net = { checkedAt: now, queue: added.slice(0, 12).map((r) => r.id), removed: removedCodes, meta: added.slice(0, 12).map((r) => ({ id: r.id, ref: r.tags.ref || "", name: r.tags.name || "", colour: r.tags.colour || "", route: r.tags.route })) };
    await this.setDoc("network_changes_partial", { variants: [] });
    if (!added.length) await this.finishNetwork();
    return true;
  }

  async finishNetwork() {
    const st = this.state.net || {};
    const partial = (await this.doc("network_changes_partial")) || { variants: [] };
    const byCode = {};
    const stations = {};
    for (const v of partial.variants) {
      const meta = (st.meta || []).find((m) => m.id === v.id) || {};
      const code = (meta.ref || v.ref || "").trim() || `R${v.id}`;
      const mode = { subway: "metro", light_rail: "metro", tram: "tram", train: "suburban", funicular: "funicular", aerialway: "cable", monorail: "metro" }[meta.route] || "metro";
      const line = byCode[code] || (byCode[code] = {
        code, name: code, long: meta.name || code, mode, color: /^#[0-9a-f]{6}$/i.test(meta.colour) ? meta.colour : "#64748B",
        operator: "", speed_kmh: mode === "tram" ? 30 : 70, dwell_s: 30, headways: [[360, 1440, 420]], headway_src: "tahmini", variants: [], is_new: true
      });
      line.variants.push({ id: v.id, from: v.from, to: v.to, length_m: v.length_m, path: v.path, stops: v.stops.map((s) => [s.sid, s.d, s.lat, s.lon]) });
      for (const s of v.stops) {
        const cur = stations[s.sid] || (stations[s.sid] = { name: s.name, lat: s.lat, lon: s.lon, lines: [], kind: "underground", depth: 20, depth_src: "tahmini", entrances: [], elevators: 0, escalators: 0, platforms: 0, platform: "island", kinds: {}, depths: {}, depth_srcs: {} });
        if (!cur.lines.includes(code)) cur.lines.push(code);
        cur.kinds[code] = mode === "metro" ? "u" : "s";
        cur.depths[code] = mode === "metro" ? 20 : 0;
        cur.depth_srcs[code] = "tahmini";
      }
    }
    await this.setDoc("network_changes", { checked_at: st.checkedAt || Date.now(), added: Object.values(byCode), removed: st.removed || [], stations });
    this.state.net = { checkedAt: st.checkedAt || Date.now() };
  }
}

function hubJsonResponse(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json; charset=utf-8" } });
}

// ───────────────── Şehir Hatları parsing (mirrors tools/build_transit_data.py) ─────────────────

function shFold(s) {
  return String(s || "").replace(/İ/g, "i").replace(/I/g, "ı").toLowerCase()
    .replace(/ı/g, "i").replace(/ğ/g, "g").replace(/ü/g, "u").replace(/ş/g, "s").replace(/ö/g, "o").replace(/ç/g, "c")
    .normalize("NFKD").replace(/[̀-ͯ]/g, "")
    .replace(/\(.*?\)/g, " ")
    .replace(/\b(sh|ido|turyol|dentur|iskelesi|iskele|hatti|hatt|ring)\b/g, " ")
    .replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim();
}

function shText(html) {
  return String(html || "").replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|div|li|tr|h\d)>/gi, "\n")
    .replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&([a-z]+);/gi, (m, n) => ({ Uuml: "Ü", uuml: "ü", Ouml: "Ö", ouml: "ö", Ccedil: "Ç", ccedil: "ç" }[n] || m))
    .replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n").trim();
}

function shMainContent(html) {
  const i = html.search(/İptal Seferler<\/h/i);
  const start = i >= 0 ? i : Math.max(0, html.search(/İptal Seferler/i));
  const end = html.search(/<footer/i);
  return html.slice(start, end > start ? end : undefined);
}

function shTitle(s) {
  const low = (w) => w.replace(/I/g, "ı").replace(/İ/g, "i").toLowerCase();
  const up = (c) => ({ i: "İ", ı: "I" }[c] || c.toUpperCase());
  return String(s).trim().split(/(\s+|-|\/|\()/).map((w) => (/^[A-Za-zÇĞİÖŞÜçğıöşü]/.test(w) ? up(low(w)[0]) + low(w).slice(1) : w)).join("").replace(/\s*-\s*/g, " – ");
}

function shParseTables(html) {
  const out = [];
  const tables = html.match(/<table[\s\S]*?<\/table>/gi) || [];
  for (const t of tables) {
    const rows = (t.match(/<tr[^>]*>[\s\S]*?<\/tr>/gi) || []).map((r) => (r.match(/<t[dh][^>]*>[\s\S]*?<\/t[dh]>/gi) || []).map((c) => shText(c).replace(/\s+/g, " ").trim()));
    if (rows.length < 3) continue;
    let title = "";
    let r0 = 0;
    // replacement timetables: "LINE HATTI" / "dd.mm.yyyy Tarihi Yapılır" / "PIER KALKIŞ" columns
    if (rows[0].length === 1 && /HATTI/i.test(rows[0][0]) && rows[1] && rows[1].length === 1) { title = rows[0][0]; r0 = 1; }
    const head = rows[r0].join(" ");
    const notes = {};
    const nre = /(\*+)\s*([^*]+)/g;
    let nm;
    while ((nm = nre.exec(head))) notes[nm[1]] = nm[2].trim();
    const days = head.replace(/\*.*/, "").trim();
    const pierRow = rows[r0 + 1] || [];
    const allDepartures = pierRow.length > 0 && pierRow.every((c) => /KALKI[ŞS]/i.test(c));
    let piers = pierRow.map((c) => c.replace(/\s*(KALKI[ŞS]|VARI[ŞS])\s*$/i, "").trim());
    let body = rows.slice(r0 + 2);
    if (rows[r0 + 2] && /Kalkış|Varış/i.test(rows[r0 + 2].join(" "))) body = rows.slice(r0 + 3);
    if (!piers.length) continue;
    const outRows = [];
    for (const r of body) {
      if (r.length !== piers.length) continue;
      const vals = r.map((c) => { const m = c.match(/(\d{1,2})[:.](\d{2})\s*(\**)/); return m ? [Number(m[1]) * 60 + Number(m[2]), m[3]] : null; });
      if (vals.some(Boolean)) outRows.push(vals);
    }
    if (outRows.length) out.push({ piers, rows: outRows, notes, days, title, allDepartures });
  }
  return out;
}

function shDaysMask(dayLabel, note) {
  const lab = shFold(dayLabel);
  const WEEK = 0b0011111, SAT = 0b0100000, SUN = 0b1000000, ALL = 0b1111111;
  const mentioned = (t) => {
    let m = 0;
    if (t.includes("hafta ici") || t.includes("haftaici")) m |= WEEK;
    if (t.includes("cumartesi") || t.includes("c tesi") || t.includes("ctesi")) m |= SAT;
    if (t.includes("pazar")) m |= SUN;
    if (t.includes("hafta sonu")) m |= SAT | SUN;
    return m;
  };
  let mask;
  if (lab.includes("baglayan")) mask = 0b0110000;
  else if (lab.includes("her gun") || lab.includes("hergun") || lab.includes("tarihi yapilir")) mask = ALL;
  else if (lab.includes("yapilmaz")) {
    const head = lab.split("yapilmaz")[0];
    const base = lab.includes("hafta ici") || lab.includes("haftaici") ? WEEK : ALL;
    mask = base === ALL ? base & ~mentioned(head.replace("hafta ici", "").replace("haftaici", "")) : base;
  } else mask = mentioned(lab) || ALL;
  if (note) {
    const nf = shFold(note);
    if (nf.includes("yapilmaz")) mask &= ~mentioned(nf.split("yapilmaz")[0]);
    else if (nf.includes("sadece") || nf.includes("yapilir")) { const m2 = mentioned(nf); if (m2) mask &= m2; }
  }
  return mask || ALL;
}

const SH_ALIAS = { "yeni kadikoy": "kadikoy", "eminonu camli": "eminonu", eyupsultan: "eyup", besiktas: "besiktas tarihi" };

function shFindPier(name, piers) {
  let key = shFold(name);
  key = SH_ALIAS[key] || key;
  const entries = Object.entries(piers);
  const exact = entries.filter(([, p]) => shFold(p.name) === key);
  const pool = exact.length ? exact : entries.filter(([, p]) => { const f = shFold(p.name); return f.startsWith(key + " ") || key.startsWith(f + " ") || f.split(" ")[0] === key; });
  const sh = pool.filter(([, p]) => (p.ops || []).includes("sh"));
  const pick = (sh.length ? sh : pool)[0];
  return pick ? pick[0] : null;
}

function shOrderByTime(stops) {
  const st = stops.map((x) => [x[0], x[1]]);
  const mins = st.map((x) => x[1]);
  if (Math.max(...mins) - Math.min(...mins) > 720) for (const x of st) if (x[1] < 360) x[1] += 1440;
  st.sort((a, b) => a[1] - b[1]);
  return st;
}

function shTablesToPatterns(tables, title, net, today) {
  const terminals = String(title).replace(/hatt?ı?\s*$/i, "").split(/\s+-\s*|\s*-\s+|\s*–\s*/).map((x) => x.trim()).filter(Boolean);
  const patterns = [];
  const seen = new Map();
  for (const tb of tables) {
    let pids = tb.piers.map((p) => shFindPier(p, net.piers));
    let rows = tb.rows;
    if (pids.length === 1 && pids[0] && terminals.length >= 2) {
      const f0 = shFold(tb.piers[0]);
      const other = terminals.filter((t) => !f0.includes(shFold(t)) && !shFold(t).includes(f0));
      const dest = shFindPier(other.length ? other[other.length - 1] : terminals[terminals.length - 1], net.piers);
      if (dest && dest !== pids[0]) {
        const a = net.piers[pids[0]], b = net.piers[dest];
        const km = haversineMeters(a.lat, a.lon, b.lat, b.lon) / 1000 * 1.25;
        const mins = Math.round(km / 20 * 60 + 1);
        rows = rows.map((r) => [r[0], r[0] ? [r[0][0] + mins, ""] : null]);
        pids = [pids[0], dest];
      }
    }
    if (pids.filter(Boolean).length < 2) continue;
    const trips = [];
    if (tb.allDepartures) {
      // every column is a departure from that pier: sail to the next pier (the last one returns to the first)
      const legMin = (a, b) => {
        const A = net.piers[a], B = net.piers[b];
        return Math.round(haversineMeters(A.lat, A.lon, B.lat, B.lon) / 1000 * 1.25 / 20 * 60 + 1);
      };
      const late = (m) => (m < 240 ? m + 1440 : m); // 00:30 at the end of a day list is after midnight
      for (const row of rows) {
        pids.forEach((pid, j) => {
          const cell = row[j];
          if (!pid || !cell) return;
          const nj = (j + 1) % pids.length, next = pids[nj];
          if (!next || next === pid) return;
          const dep = late(cell[0]);
          let arr = row[nj] && nj > j ? late(row[nj][0]) : dep + legMin(pid, next);
          if (arr <= dep) arr = dep + legMin(pid, next);
          trips.push({ d: 0b1111111, s: [[pid, dep], [next, arr]] });
        });
      }
      if (trips.length) patterns.push({ label: pids.filter(Boolean).map((p) => net.piers[p].name).join(" ⇄ "), days: tb.days, trips: trips.sort((a, b) => a.s[0][1] - b.s[0][1]) });
      continue;
    }
    for (const row of rows) {
      const stops = [];
      let marker = "";
      pids.forEach((pid, i) => {
        const cell = row[i];
        if (pid && cell) { stops.push([pid, cell[0]]); if (cell[1] && cell[1].length > marker.length) marker = cell[1]; }
      });
      if (stops.length < 2) continue;
      const s = shOrderByTime(stops);
      const key = JSON.stringify(s);
      const d = today ? 0b1111111 : shDaysMask(tb.days, tb.notes[marker]);
      if (seen.has(key)) { seen.get(key).d |= d; continue; }
      const trip = Object.assign({ d, s }, tb.notes[marker] ? { n: tb.notes[marker] } : {});
      seen.set(key, trip);
      trips.push(trip);
    }
    if (trips.length) patterns.push({ label: pids.filter(Boolean).map((p) => net.piers[p].name).join(" → "), days: tb.days, trips: trips.sort((a, b) => a.s[0][1] - b.s[0][1]) });
  }
  return patterns;
}

/// Lines a published name refers to ("Kadıköy-Haliç", "Boğaz Gidiş-Geliş"): every word of the
/// name must occur in the line's name; pier names are only used when no line name matches.
function shMatchLines(name, lines, piers) {
  const words = shFold(name).split(" ").filter((w) => w.length > 1 && !["ve", "hatti", "turu"].includes(w));
  if (!words.length) return [];
  const flat = (s) => shFold(s).replace(/\s+/g, "");
  const byName = lines.filter((l) => words.every((w) => flat(l.name).includes(w)));
  if (byName.length) {
    // closest name wins ("Kadıköy-Beşiktaş" is not "Kadıköy-Karaköy-Beşiktaş")
    const extra = (l) => shFold(l.name).split(" ").filter((w) => w.length > 1 && !words.some((x) => w.includes(x) || x.includes(w))).length;
    const best = Math.min(...byName.map(extra));
    return byName.filter((l) => extra(l) === best).map((l) => l.id);
  }
  const byPiers = lines.filter((l) => {
    const all = flat(l.name + " " + (l.piers || []).map((p) => (piers[p] || {}).name || "").join(" "));
    return words.every((w) => all.includes(w));
  });
  return byPiers.length <= 2 ? byPiers.map((l) => l.id) : [];
}

// ───────────────── OpenStreetMap: build one route variant (mirrors the Python tool) ─────────────────

async function osmBuildVariant(rid) {
  const res = await fetch(`https://api.openstreetmap.org/api/0.6/relation/${rid}/full.json`, { headers: { "user-agent": HUB_UA } });
  if (!res.ok) throw new Error("OSM HTTP " + res.status);
  const data = await res.json();
  const nodes = new Map(), ways = new Map();
  let rel = null;
  for (const e of data.elements) {
    if (e.type === "node") nodes.set(e.id, e);
    else if (e.type === "way") ways.set(e.id, e);
    else if (e.type === "relation" && e.id === rid) rel = e;
  }
  if (!rel) return null;
  const member = [], stops = [];
  for (const m of rel.members) {
    if (m.type === "way" && ["", "forward", "backward"].includes(m.role) && ways.has(m.ref)) {
      let pts = ways.get(m.ref).nodes.filter((n) => nodes.has(n)).map((n) => [nodes.get(n).lat, nodes.get(n).lon]);
      if (m.role === "backward") pts = pts.reverse();
      member.push(pts);
    } else if (m.type === "node" && m.role.startsWith("stop") && nodes.has(m.ref)) {
      const n = nodes.get(m.ref);
      const nm = (n.tags || {}).name;
      if (nm) stops.push({ name: nm, lat: n.lat, lon: n.lon, id: n.id });
    }
  }
  let path = osmChain(member);
  if (path.length < 2 || stops.length < 2) return null;
  if (haversineMeters(path[0][0], path[0][1], stops[0].lat, stops[0].lon) > haversineMeters(path[path.length - 1][0], path[path.length - 1][1], stops[0].lat, stops[0].lon)) path.reverse();
  path = osmSimplify(path, 3);
  const cum = [0];
  for (let i = 1; i < path.length; i++) cum.push(cum[i - 1] + haversineMeters(path[i - 1][0], path[i - 1][1], path[i][0], path[i][1]));
  const placed = stops.map((s) => ({ s, d: osmProject(path, cum, s) })).sort((a, b) => a.d - b.d);
  const out = [];
  for (const { s, d } of placed) {
    if (out.length && out[out.length - 1].name === s.name) continue;
    out.push({ sid: `n${s.id}`, name: s.name, d: Math.round(d * 10) / 10, lat: +s.lat.toFixed(6), lon: +s.lon.toFixed(6) });
  }
  return { id: rid, ref: (rel.tags || {}).ref || "", from: out[0].name, to: out[out.length - 1].name, length_m: Math.round(cum[cum.length - 1]), path: osmEncode(path), stops: out };
}

function osmChain(ways) {
  let path = [];
  for (const w of ways) {
    if (!w.length) continue;
    if (!path.length) { path = w.slice(); continue; }
    const end = path[path.length - 1];
    const dF = haversineMeters(end[0], end[1], w[0][0], w[0][1]);
    const dR = haversineMeters(end[0], end[1], w[w.length - 1][0], w[w.length - 1][1]);
    if (path.length === ways[0].length) {
      const dFirst = Math.min(haversineMeters(path[0][0], path[0][1], w[0][0], w[0][1]), haversineMeters(path[0][0], path[0][1], w[w.length - 1][0], w[w.length - 1][1]));
      if (dFirst < Math.min(dF, dR)) path.reverse();
    }
    const e2 = path[path.length - 1];
    let seg = haversineMeters(e2[0], e2[1], w[0][0], w[0][1]) <= haversineMeters(e2[0], e2[1], w[w.length - 1][0], w[w.length - 1][1]) ? w : w.slice().reverse();
    if (haversineMeters(e2[0], e2[1], seg[0][0], seg[0][1]) < 1) seg = seg.slice(1);
    path.push(...seg);
  }
  return path;
}

function osmSimplify(pts, tol) {
  if (pts.length < 3) return pts;
  const lat0 = pts[0][0] * Math.PI / 180;
  const xy = pts.map((p) => [p[1] * Math.PI / 180 * 6371000 * Math.cos(lat0), p[0] * Math.PI / 180 * 6371000]);
  const keep = new Array(pts.length).fill(false);
  keep[0] = keep[pts.length - 1] = true;
  const stack = [[0, pts.length - 1]];
  while (stack.length) {
    const [i, j] = stack.pop();
    const [ax, ay] = xy[i], [bx, by] = xy[j];
    const dx = bx - ax, dy = by - ay, L2 = dx * dx + dy * dy;
    let best = -1, bi = -1;
    for (let k = i + 1; k < j; k++) {
      const [px, py] = xy[k];
      const t = L2 ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / L2)) : 0;
      const d = Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
      if (d > best) { best = d; bi = k; }
    }
    if (best > tol) { keep[bi] = true; stack.push([i, bi], [bi, j]); }
  }
  return pts.filter((_, i) => keep[i]);
}

function osmProject(path, cum, s) {
  let best = Infinity, bestD = 0;
  const lat0 = s.lat * Math.PI / 180;
  const X = (p) => [p[1] * Math.PI / 180 * 6371000 * Math.cos(lat0), p[0] * Math.PI / 180 * 6371000];
  const [px, py] = X([s.lat, s.lon]);
  for (let i = 0; i < path.length - 1; i++) {
    const [ax, ay] = X(path[i]), [bx, by] = X(path[i + 1]);
    const dx = bx - ax, dy = by - ay, L2 = dx * dx + dy * dy;
    const t = L2 ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / L2)) : 0;
    const d = Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
    if (d < best) { best = d; bestD = cum[i] + t * (cum[i + 1] - cum[i]); }
  }
  return bestD;
}

function osmEncode(points) {
  let out = "", plat = 0, plon = 0;
  for (const [lat, lon] of points) {
    const ilat = Math.round(lat * 1e5), ilon = Math.round(lon * 1e5);
    for (let v of [ilat - plat, ilon - plon]) {
      v = v < 0 ? ~(v << 1) : v << 1;
      while (v >= 0x20) { out += String.fromCharCode((0x20 | (v & 0x1f)) + 63); v >>= 5; }
      out += String.fromCharCode(v + 63);
    }
    plat = ilat; plon = ilon;
  }
  return out;
}
