#!/usr/bin/env python3
"""
build.py - Compiles worker.js, bus_lines_map.json, metro stations/colors,
and index.html into src/bundle.js for Cloudflare Workers deployment.
"""

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

    export_default_block = """
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
    if (path === "/buses") return handleBuses(env);
    if (path === "/line") return handleLine(env, url);
    if (path === "/line/route") return handleLineRoute(env, url);
    if (path === "/lines") return handleLines(env);
    if (path === "/lines/map") return handleLinesMap(env);
    if (path === "/metro/stations") return json(METRO_STATIONS, 200, { "cache-control": "public, max-age=86400" });
    if (path === "/metro/colors") return json(METRO_COLORS, 200, { "cache-control": "public, max-age=86400" });
    if (path === "/feed/buses") return handleFeed(request, env);
    if (path === "/feed/mapping") return handleFeedMapping(request, env);
    if (path === "/status") {
      const q = await quota(env);
      const meta = await env.LIVE.get("meta", "json");
      let map = await env.LIVE.get("bus_lines_map", "json");
      const mappedLinesCount = map ? Object.keys(map).length : Object.keys(BUS_LINES_MAP).length;
      return json({
        status: "ok",
        meta,
        mapped_lines_count: mappedLinesCount,
        iett_quota_used_this_hour: q.n,
        iett_quota_max: 99,
        has_api_key: Boolean(env.IBB_API_KEY || env.IBB_SECRET),
        has_carto_key: Boolean(env.CARTO_API_KEY)
      });
    }

    return json({ error: "Not found", routes: ["/", "/buses", "/line?code=15B", "/line/route?code=15B", "/lines", "/lines/map", "/metro/stations", "/metro/colors", "/status"] }, 404);
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(refreshFleet(env).catch(e => console.error("Cron refresh failed:", String(e))));
  }
};
"""

    bundle_parts = [
        worker_code.strip(),
        "\n\n",
        f"const BUS_LINES_MAP = {json.dumps(bus_lines_map, ensure_ascii=False)};\n",
        f"const METRO_STATIONS = {json.dumps(metro_stations, ensure_ascii=False)};\n",
        f"const METRO_COLORS = {json.dumps(metro_colors, ensure_ascii=False)};\n",
        f"const HTML_PAGE = {json.dumps(html_page, ensure_ascii=False)};\n",
        export_default_block
    ]

    bundle_content = "".join(bundle_parts)
    bundle_path = os.path.join(SRC_DIR, "bundle.js")
    with open(bundle_path, "w", encoding="utf-8") as f:
        f.write(bundle_content)

    print(f"Successfully generated {bundle_path} ({len(bundle_content)} bytes)")

if __name__ == "__main__":
    main()
