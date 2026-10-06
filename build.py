#!/usr/bin/env python3
"""
build.py - Compiles worker.js, bus_lines_map.json, metro stations/colors,
index.html, manifest.json, sw.js, and app icons into src/bundle.js for Cloudflare Workers deployment.
"""

import base64
import json
import os

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(BASE_DIR, "src")

def main():
    print("Building src/bundle.js...")
    
    with open(os.path.join(SRC_DIR, "worker.js"), "r", encoding="utf-8") as f:
        worker_code = f.read()

    with open(os.path.join(SRC_DIR, "bus_lines_map.json"), "r", encoding="utf-8") as f:
        bus_lines_map = json.load(f)

    with open(os.path.join(SRC_DIR, "metro_stations.json"), "r", encoding="utf-8") as f:
        metro_stations = json.load(f)

    with open(os.path.join(SRC_DIR, "metro_colors.json"), "r", encoding="utf-8") as f:
        metro_colors = json.load(f)

    with open(os.path.join(SRC_DIR, "index.html"), "r", encoding="utf-8") as f:
        html_page = f.read()

    with open(os.path.join(SRC_DIR, "manifest.json"), "r", encoding="utf-8") as f:
        manifest_json = f.read()

    with open(os.path.join(SRC_DIR, "sw.js"), "r", encoding="utf-8") as f:
        sw_code = f.read()

    with open(os.path.join(SRC_DIR, "icon.svg"), "r", encoding="utf-8") as f:
        icon_svg = f.read()

    with open(os.path.join(SRC_DIR, "icon-192.png"), "rb") as f:
        icon_192_b64 = base64.b64encode(f.read()).decode("ascii")

    with open(os.path.join(SRC_DIR, "icon-512.png"), "rb") as f:
        icon_512_b64 = base64.b64encode(f.read()).decode("ascii")

    export_default_block = """
function b64ToUint8Array(b64) {
  const bin = atob(b64);
  const len = bin.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    bytes[i] = bin.charCodeAt(i);
  }
  return bytes;
}

export default {
  async fetch(request, env, ctx) {
    if (request.method === "OPTIONS") return new Response(null, { headers: CORS });
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === "/") {
      const key = env.CARTO_API_KEY || "";
      const page = HTML_PAGE.replace(/__CARTO_KEY__/g, key);
      return new Response(page, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-cache" }
      });
    }

    // PWA Assets
    if (path === "/manifest.json") {
      return new Response(MANIFEST_JSON, {
        headers: { "content-type": "application/manifest+json; charset=utf-8", "cache-control": "public, max-age=86400" }
      });
    }
    if (path === "/sw.js") {
      return new Response(SW_CODE, {
        headers: { "content-type": "application/javascript; charset=utf-8", "cache-control": "no-cache" }
      });
    }
    if (path === "/icon.svg") {
      return new Response(ICON_SVG, {
        headers: { "content-type": "image/svg+xml; charset=utf-8", "cache-control": "public, max-age=604800" }
      });
    }
    if (path === "/icon-192.png") {
      const bytes = b64ToUint8Array(ICON_192_B64);
      return new Response(bytes, {
        headers: { "content-type": "image/png", "cache-control": "public, max-age=604800" }
      });
    }
    if (path === "/icon-512.png") {
      const bytes = b64ToUint8Array(ICON_512_B64);
      return new Response(bytes, {
        headers: { "content-type": "image/png", "cache-control": "public, max-age=604800" }
      });
    }

    if (path === "/buses") return handleBuses(request, env);
    if (path === "/line") return handleLine(env, url);
    if (path === "/line/route") return handleLineRoute(env, url);
    if (path === "/lines") return handleLines(env);
    if (path === "/lines/map") return handleLinesMap(env);
    if (path === "/doors/map") return handleDoorsMap(env);
    if (path === "/metro/stations") return json(METRO_STATIONS, 200, { "cache-control": "public, max-age=86400" });
    if (path === "/metro/colors") return json(METRO_COLORS, 200, { "cache-control": "public, max-age=86400" });
    if (path === "/feed/buses") return handleFeed(request, env);
    if (path === "/feed/mapping") return handleFeedMapping(request, env);
    if (path === "/stops") return json(BUS_STOPS, 200, { "cache-control": "public, max-age=86400" });
    if (path === "/disruptions") return handleDisruptions(env, url);
    if (path.startsWith("/tile/")) {
      // Proxy CARTO raster tiles using CARTO_API_KEY from Cloudflare secrets
      const parts = path.replace("/tile/", "").split("/");
      if (parts.length >= 4) {
        const style = parts[0]; // e.g. "voyager", "light_all", "dark_all"
        const z = parts[1];
        const x = parts[2];
        const y = parts[3];
        const sub = ["a", "b", "c", "d"][Math.abs(parseInt(x, 10) + parseInt(y, 10)) % 4] || "a";
        const key = env.CARTO_API_KEY || env.CARTO_KEY || "";
        const query = key ? `?key=${key}` : "";
        const tileUrl = `https://${sub}.basemaps.cartocdn.com/rastertiles/${style}/${z}/${x}/${y}${query}`;
        try {
          const tileRes = await fetch(tileUrl, {
            headers: {
              "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
              "Referer": "https://istanbulbizim.nano-carbay.workers.dev/"
            }
          });
          const tileHeaders = new Headers(tileRes.headers);
          tileHeaders.set("Access-Control-Allow-Origin", "*");
          tileHeaders.set("Cache-Control", "public, max-age=604800, stale-while-revalidate=86400");
          return new Response(tileRes.body, {
            status: tileRes.status,
            headers: tileHeaders
          });
        } catch (e) {
          return new Response("Tile fetch error", { status: 502, headers: CORS });
        }
      }
    }

    if (path === "/config/carto") {
      const key = env.CARTO_API_KEY || env.CARTO_KEY || "";
      return json({ carto_key: key, has_key: Boolean(key) });
    }

    if (path === "/status") {
      const q = await quota(env);
      const meta = inMemoryMeta || (await env.LIVE.get("meta", { type: "json", cacheTtl: 30 }));
      let map = await env.LIVE.get("bus_lines_map", "json");
      const mappedLinesCount = map ? Object.keys(map).length : Object.keys(BUS_LINES_MAP).length;
      const key = env.CARTO_API_KEY || env.CARTO_KEY || "";
      return json({
        status: "ok",
        meta,
        mapped_lines_count: mappedLinesCount,
        bus_stops_count: BUS_STOPS.length,
        iett_quota_used_this_hour: q.n,
        iett_quota_max: 99,
        has_api_key: Boolean(env.IBB_API_KEY || env.IBB_SECRET),
        has_carto_key: Boolean(key),
        carto_key: key
      });
    }

    return json({ error: "Not found", routes: ["/", "/manifest.json", "/sw.js", "/icon.svg", "/buses", "/line?code=15B", "/line/route?code=15B", "/lines", "/lines/map", "/stops", "/disruptions", "/metro/stations", "/metro/colors", "/status", "/config/carto", "/tile/voyager/{z}/{x}/{y}"] }, 404);
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(refreshFleet(env).catch(e => console.error("Cron refresh failed:", String(e))));
  }
};
"""

    with open(os.path.join(SRC_DIR, "bus_stops.json"), "r", encoding="utf-8") as f:
        bus_stops = json.load(f)

    with open(os.path.join(SRC_DIR, "door_lines_map.json"), "r", encoding="utf-8") as f:
        door_lines_map = json.load(f)

    bundle_parts = [
        worker_code.strip(),
        "\n\n",
        f"const BUS_LINES_MAP = {json.dumps(bus_lines_map, ensure_ascii=False)};\n",
        f"const DOOR_LINES_MAP = {json.dumps(door_lines_map, ensure_ascii=False)};\n",
        f"const BUS_STOPS = {json.dumps(bus_stops, ensure_ascii=False)};\n",
        f"const METRO_STATIONS = {json.dumps(metro_stations, ensure_ascii=False)};\n",
        f"const METRO_COLORS = {json.dumps(metro_colors, ensure_ascii=False)};\n",
        f"const HTML_PAGE = {json.dumps(html_page, ensure_ascii=False)};\n",
        f"const MANIFEST_JSON = {json.dumps(manifest_json, ensure_ascii=False)};\n",
        f"const SW_CODE = {json.dumps(sw_code, ensure_ascii=False)};\n",
        f"const ICON_SVG = {json.dumps(icon_svg, ensure_ascii=False)};\n",
        f"const ICON_192_B64 = {json.dumps(icon_192_b64)};\n",
        f"const ICON_512_B64 = {json.dumps(icon_512_b64)};\n",
        export_default_block
    ]

    bundle_content = "".join(bundle_parts)
    bundle_path = os.path.join(SRC_DIR, "bundle.js")
    with open(bundle_path, "w", encoding="utf-8") as f:
        f.write(bundle_content)

    print(f"Successfully generated {bundle_path} ({len(bundle_content)} bytes)")


if __name__ == "__main__":
    main()
