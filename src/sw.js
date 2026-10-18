// İstanbul Bizim — service worker v5 (retired)
// The website is now the Flutter app compiled to WebAssembly. Earlier versions (v1–v4) cached the
// old Leaflet page as the app shell; this version clears those caches and unregisters itself so
// returning visitors always get the new app.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith('ib-')).map((k) => caches.delete(k)));
    await self.registration.unregister();
    const clients = await self.clients.matchAll({ type: 'window' });
    for (const c of clients) c.navigate(c.url);
  })());
});
