/**
 * Adaptateur de secours : hors Electron (aperçu navigateur / `npm run dev:web`),
 * on fournit une API `castflow` simulée pour développer l'UI.
 */
const listeners = { status: [], devices: [], transfer: [], 'incoming-request': [], 'file-done': [] };
const emit = (ch, p) => listeners[ch]?.forEach((cb) => cb(p));
const reg = (ch) => (cb) => { listeners[ch].push(cb); return () => { listeners[ch] = listeners[ch].filter((x) => x !== cb); }; };

const device = { id: 'demo-desktop', name: 'PC de Elfred', platform: 'windows', kind: 'desktop', fingerprint: 'a1b2c3' };

// QR de démonstration (SVG inline, pas de réseau).
const demoQr = 'data:image/svg+xml;utf8,' + encodeURIComponent(`
<svg xmlns="http://www.w3.org/2000/svg" width="320" height="320" viewBox="0 0 33 33" shape-rendering="crispEdges">
<rect width="33" height="33" fill="#fff"/>
${(() => {
  let s = '';
  const finder = (x, y) => {
    s += `<rect x="${x}" y="${y}" width="7" height="7" fill="#000"/>`;
    s += `<rect x="${x + 1}" y="${y + 1}" width="5" height="5" fill="#fff"/>`;
    s += `<rect x="${x + 2}" y="${y + 2}" width="3" height="3" fill="#000"/>`;
  };
  finder(1, 1); finder(25, 1); finder(1, 25);
  let seed = 7;
  const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  for (let y = 1; y < 32; y++) {
    for (let x = 1; x < 32; x++) {
      const inFinder = (x < 9 && y < 9) || (x > 23 && y < 9) || (x < 9 && y > 23);
      if (!inFinder && rnd() > 0.55) s += `<rect x="${x}" y="${y}" width="1" height="1" fill="#000"/>`;
    }
  }
  return s;
})()}
</svg>`);

const status = {
  device,
  host: '192.168.43.1',
  addresses: [{ iface: 'Wi-Fi', address: '192.168.43.1', netmask: '255.255.255.0' }],
  httpPort: 53317,
  wsPort: 53318,
  running: true,
  pin: '482913',
  settings: { requirePin: true, autoAccept: false, downloadDir: 'C:\\Users\\Elfred\\Downloads\\CastFlow' },
  connectUrl: 'castflow://connect?host=192.168.43.1&http=53317&ws=53318&id=demo-desktop&name=PC%20de%20Elfred&pin=482913',
  qr: demoQr,
};

const devices = [
  { id: 'mob-1', name: 'Pixel 7 de Elfred', platform: 'android', kind: 'mobile', host: '192.168.43.42', httpPort: 53317, wsPort: 53318, requiresPin: false, lastSeen: Date.now(), source: 'udp' },
  { id: 'mob-2', name: 'Galaxy A54', platform: 'android', kind: 'mobile', host: '192.168.43.57', httpPort: 53317, wsPort: 53318, requiresPin: true, lastSeen: Date.now(), source: 'udp' },
];

const transfers = [
  {
    id: 't_demo1', direction: 'receive', state: 'completed',
    peer: devices[0], startedAt: Date.now() - 120000, finishedAt: Date.now() - 90000,
    totalSize: 48234496, transferred: 48234496, bps: 0,
    files: [
      { id: 'a', name: 'vacances-ouidah.mp4', size: 41943040, mime: 'video/mp4', received: 41943040, done: true, hashOk: true, hash: 'fnv1a64:9a3f2b1c4d5e6f70' },
      { id: 'b', name: 'plage.jpg', size: 6291456, mime: 'image/jpeg', received: 6291456, done: true, hashOk: true, hash: 'fnv1a64:1122334455667788' },
    ],
  },
];

function simulateIncoming() {
  const t = {
    id: 't_demo2', direction: 'receive', state: 'pending',
    peer: devices[0], startedAt: Date.now(),
    totalSize: 157286400, transferred: 0, bps: 0,
    files: [
      { id: 'c', name: 'documentaire.mkv', size: 146800640, mime: 'video/x-matroska', received: 0, done: false },
      { id: 'd', name: 'notes.pdf', size: 10485760, mime: 'application/pdf', received: 0, done: false },
    ],
  };
  transfers.unshift(t);
  emit('incoming-request', t);
  emit('transfer', t);

  const accept = () => {
    t.state = 'transferring';
    const timer = setInterval(() => {
      if (t.state !== 'transferring') return clearInterval(timer);
      for (const f of t.files) {
        if (f.received < f.size) {
          f.received = Math.min(f.size, f.received + f.size * 0.06);
          break;
        }
      }
      t.transferred = t.files.reduce((s, f) => s + f.received, 0);
      t.bps = 11.4 * 1024 * 1024;
      t.files.forEach((f) => {
        f.done = f.received >= f.size;
        if (f.done && f.hashOk === undefined) f.hashOk = true; // intégrité vérifiée
      });
      if (t.files.every((f) => f.done)) {
        t.state = 'completed';
        t.finishedAt = Date.now();
        t.bps = 0;
        clearInterval(timer);
      }
      emit('transfer', { ...t, files: t.files.map((f) => ({ ...f })) });
    }, 320);
  };
  return accept;
}

let pendingAccept = null;

export const mockApi = {
  __demo: true,
  getStatus: async () => status,
  getDevices: async () => devices,
  getTransfers: async () => transfers,
  refresh: async () => true,
  accept: async (id) => { pendingAccept?.(); pendingAccept = null; return true; },
  reject: async (id) => {
    const t = transfers.find((x) => x.id === id);
    if (t) { t.state = 'rejected'; emit('transfer', t); }
    pendingAccept = null;
    return true;
  },
  cancel: async (id) => {
    const t = transfers.find((x) => x.id === id);
    if (t) { t.state = 'cancelled'; emit('transfer', { ...t }); }
    return true;
  },
  regenPin: async () => {
    status.pin = String(Math.floor(100000 + Math.random() * 900000));
    emit('status', { ...status });
    return status;
  },
  saveSettings: async (s) => { Object.assign(status.settings, s); emit('status', { ...status }); return status; },
  pickDownloadDir: async () => status,
  pickFiles: async () => [
    { id: 'f_1', name: 'presentation.pptx', size: 8388608, mime: 'application/vnd.openxmlformats-officedocument.presentationml.presentation', path: '/demo/presentation.pptx' },
    { id: 'f_2', name: 'budget-2026.xlsx', size: 524288, mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', path: '/demo/budget.xlsx' },
  ],
  offerFiles: async (files) => ({
    transferId: 't_send1',
    baseUrl: 'http://192.168.43.1:53317',
    files: files.map((f) => ({ ...f, token: 'demo', url: `/download/t_send1/${f.id}` })),
  }),
  offerQr: async () => demoQr,
  openFolder: async () => true,

  onStatus: reg('status'),
  onDevices: reg('devices'),
  onTransfer: reg('transfer'),
  onIncomingRequest: reg('incoming-request'),
  onFileDone: reg('file-done'),
  onPeerConnected: () => () => {},
  onPeerDisconnected: () => () => {},

  /** Bouton de démo dans l'UI. */
  __simulateIncoming: () => { pendingAccept = simulateIncoming(); },
};

export const api = typeof window !== 'undefined' && window.castflow ? window.castflow : mockApi;
