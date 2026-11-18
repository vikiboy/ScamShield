// ScamShield service worker: app-shell cache + web push.
// API calls (/api/*) are never intercepted: the page caches item data itself, and
// audio needs Range requests to reach the Mac untouched.

const CACHE = 'scamshield-shell-v1';
const SHELL = [
  './',
  './index.html',
  './app.js',
  './style.css',
  './manifest.webmanifest',
  './icons/icon.svg',
  './icons/icon-180.png',
  './icons/icon-192.png',
  './icons/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith('scamshield-') && k !== CACHE).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith(new URL('api/', self.registration.scope).pathname)) return;
  event.respondWith(staleWhileRevalidate(req, event));
});

// Serve the cached shell immediately and refresh it in the background. The Mac may
// be asleep, and a request to it can hang rather than fail, so the app must never
// wait on the network to start. A new version shows up on the following launch.
async function staleWhileRevalidate(req, event) {
  const cache = await caches.open(CACHE);
  const key = req.mode === 'navigate' ? './' : req;
  const cached = await cache.match(key, { ignoreSearch: req.mode === 'navigate' });
  const network = fetch(req).then((res) => {
    if (res.ok && res.type === 'basic') return cache.put(key, res.clone()).then(() => res, () => res);
    return res;
  });
  if (!cached) return network;
  event.waitUntil(network.catch(() => {}));
  return cached;
}

// Safari revokes push permission if a push doesn't show a notification, so this
// always shows one and never waits on the Mac.
self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch {
    try {
      payload = { body: event.data ? event.data.text() : '' };
    } catch {
      payload = {};
    }
  }
  const title = (payload && typeof payload.title === 'string' && payload.title) || 'ScamShield';
  const body = (payload && typeof payload.body === 'string' && payload.body) || 'A call needs your attention.';
  const url = (payload && typeof payload.url === 'string' && payload.url)
    || (payload && payload.id ? `./#/item/${encodeURIComponent(payload.id)}` : './#/attention');
  event.waitUntil(self.registration.showNotification(title, {
    body,
    tag: payload && payload.id ? String(payload.id) : undefined,
    icon: './icons/icon-192.png',
    badge: './icons/icon-192.png',
    data: { url },
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = new URL((event.notification.data && event.notification.data.url) || './', self.registration.scope).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if (new URL(client.url).origin !== self.location.origin) continue;
      await client.focus();
      client.postMessage({ type: 'navigate', url });
      return;
    }
    await self.clients.openWindow(url);
  })());
});
