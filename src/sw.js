// İstanbul Bizim — PWA Service Worker v2
// • App shell: network-first, cache fallback (offline start)
// • Live data (/buses /line /traffic /stop/arrivals /bus/eta /feed /status /disruptions /diag): network only
// • Slow-changing data (/stops /lines /metro/* /line/route /timetable /bootstrap …): stale-while-revalidate
// • Map tiles (/tile/* and cartocdn): cache-first in a size-capped tile cache → no blank map on flaky data
const VERSION = 'v2';
const SHELL = 'ib-shell-' + VERSION;
const DATA = 'ib-data-' + VERSION;
const TILES = 'ib-tiles-' + VERSION;
const TILE_LIMIT = 900;

const SHELL_ASSETS = [
  '/',
  '/manifest.json',
  '/icon.svg',
  '/icon-192.png',
  '/icon-512.png',
  'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.css',
  'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.js'
];

const LIVE_PREFIXES = ['/buses', '/feed', '/status', '/disruptions', '/traffic', '/stop/arrivals', '/bus/eta', '/diag'];
const SWR_PREFIXES = ['/stops', '/lines', '/doors', '/metro', '/metrobus', '/line/route', '/timetable', '/bootstrap', '/config'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(SHELL)
      .then((cache) => Promise.all(SHELL_ASSETS.map((u) => cache.add(u).catch(() => {}))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => ![SHELL, DATA, TILES].includes(k)).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

async function trim(cacheName, max) {
  const cache = await caches.open(cacheName);
  const keys = await cache.keys();
  if (keys.length > max) await Promise.all(keys.slice(0, keys.length - max).map((k) => cache.delete(k)));
}

async function staleWhileRevalidate(request) {
  const cache = await caches.open(DATA);
  const cached = await cache.match(request);
  const fetching = fetch(request)
    .then((res) => { if (res && res.status === 200) cache.put(request, res.clone()); return res; })
    .catch(() => null);
  return cached || (await fetching) || new Response('{"error":"offline"}', { status: 503, headers: { 'content-type': 'application/json' } });
}

async function tileFirst(request) {
  const cache = await caches.open(TILES);
  const hit = await cache.match(request);
  if (hit) return hit;
  try {
    const res = await fetch(request);
    if (res && (res.status === 200 || res.type === 'opaque')) {
      cache.put(request, res.clone());
      trim(TILES, TILE_LIMIT);
    }
    return res;
  } catch (e) {
    return new Response('', { status: 504 });
  }
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (url.pathname.startsWith('/tile/') || url.hostname.endsWith('basemaps.cartocdn.com')) {
    return event.respondWith(tileFirst(req));
  }

  if (url.origin === self.location.origin) {
    const p = url.pathname;
    if (p === '/line' || LIVE_PREFIXES.some((x) => p.startsWith(x))) {
      return event.respondWith(fetch(req));
    }
    if (SWR_PREFIXES.some((x) => p.startsWith(x))) {
      return event.respondWith(staleWhileRevalidate(req));
    }
  }

  // App shell + third-party static assets: network-first, cache fallback
  event.respondWith(
    fetch(req)
      .then((res) => {
        if (res && res.status === 200) {
          const copy = res.clone();
          caches.open(SHELL).then((c) => c.put(req, copy));
        }
        return res;
      })
      .catch(() =>
        caches.match(req).then((hit) => hit || (req.mode === 'navigate' ? caches.match('/') : undefined))
      )
  );
});
