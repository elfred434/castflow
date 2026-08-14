// Process principal Electron : orchestre serveur, découverte et fenêtre.
const { app, BrowserWindow, ipcMain, dialog, shell, Notification } = require('electron');
const path = require('node:path');
const fsp = require('node:fs/promises');
const QRCode = require('qrcode');

const { CastFlowServer } = require('./core/server');
const { Discovery } = require('./core/discovery');
const { loadIdentity, saveIdentity, localAddresses, primaryAddress } = require('./core/device');
const { generatePin, buildConnectUrl, guessMime, uid, DEFAULT_PORTS } = require('./core/protocol');

let win = null;
let server = null;
let discovery = null;
let identity = null;
let pin = generatePin();
let settings = { requirePin: true, autoAccept: false, downloadDir: '' };

const dataDir = () => app.getPath('userData');

function send(channel, payload) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}

async function currentStatus() {
  const host = primaryAddress();
  const connectUrl = buildConnectUrl({
    host,
    httpPort: server?.httpPort ?? DEFAULT_PORTS.http,
    wsPort: server?.wsPort ?? DEFAULT_PORTS.ws,
    device: identity,
    pin: settings.requirePin ? pin : undefined,
  });
  return {
    device: identity,
    host,
    addresses: localAddresses(),
    httpPort: server?.httpPort ?? null,
    wsPort: server?.wsPort ?? null,
    running: !!server?.httpPort,
    pin: settings.requirePin ? pin : null,
    settings,
    connectUrl,
    qr: await QRCode.toDataURL(connectUrl, { margin: 1, width: 320 }),
  };
}

async function startServices() {
  identity = loadIdentity(dataDir());
  if (!settings.downloadDir) {
    settings.downloadDir = path.join(app.getPath('downloads'), 'CastFlow');
  }
  await fsp.mkdir(settings.downloadDir, { recursive: true });

  server = new CastFlowServer({
    device: identity,
    downloadDir: settings.downloadDir,
    pin: settings.requirePin ? pin : null,
    autoAccept: settings.autoAccept,
  });

  server.on('transfer', (t) => send('transfer', t));
  server.on('peer-connected', (d) => send('peer-connected', d));
  server.on('peer-disconnected', (d) => send('peer-disconnected', d));
  server.on('file-done', ({ file }) => {
    new Notification({ title: 'Fichier reçu', body: file.name }).show();
    send('file-done', file);
  });
  server.on('incoming-request', ({ transfer }) => {
    send('incoming-request', transfer);
    if (win) { win.show(); win.focus(); }
  });

  const ports = await server.start();

  discovery = new Discovery({
    device: identity,
    httpPort: ports.httpPort,
    wsPort: ports.wsPort,
    requiresPin: settings.requirePin,
  });
  discovery.on('devices', (list) => send('devices', list));
  await discovery.start();

  send('status', await currentStatus());
}

async function stopServices() {
  discovery?.stop();
  await server?.stop();
  discovery = null;
  server = null;
}

function createWindow() {
  win = new BrowserWindow({
    width: 1120,
    height: 760,
    minWidth: 900,
    minHeight: 620,
    backgroundColor: '#0b1120',
    title: 'CastFlow',
    webPreferences: { preload: path.join(__dirname, '..', 'preload', 'index.js') },
  });

  const devUrl = process.env.VITE_DEV_SERVER_URL || 'http://localhost:5173';
  if (!app.isPackaged) win.loadURL(devUrl);
  else win.loadFile(path.join(__dirname, '..', '..', 'dist', 'index.html'));
}

/* ---------------------------- IPC ---------------------------- */

ipcMain.handle('status', () => currentStatus());
ipcMain.handle('devices', () => discovery?.list() ?? []);
ipcMain.handle('transfers', () => server?.listTransfers() ?? []);
ipcMain.handle('refresh', () => { discovery?.refresh(); return true; });

ipcMain.handle('accept', (_e, id) => { server?.acceptTransfer(id); return true; });
ipcMain.handle('reject', (_e, id) => { server?.rejectTransfer(id); return true; });
ipcMain.handle('cancel', (_e, id) => { server?.cancelTransfer(id); return true; });

ipcMain.handle('regen-pin', async () => {
  pin = generatePin();
  server?.setPin(settings.requirePin ? pin : null);
  return currentStatus();
});

ipcMain.handle('save-settings', async (_e, next) => {
  settings = { ...settings, ...next };
  server?.setAutoAccept(settings.autoAccept);
  server?.setPin(settings.requirePin ? pin : null);
  if (next.downloadDir) {
    await fsp.mkdir(next.downloadDir, { recursive: true });
    server?.setDownloadDir(next.downloadDir);
  }
  return currentStatus();
});

ipcMain.handle('pick-download-dir', async () => {
  const r = await dialog.showOpenDialog(win, { properties: ['openDirectory', 'createDirectory'] });
  if (r.canceled || !r.filePaths[0]) return null;
  settings.downloadDir = r.filePaths[0];
  server?.setDownloadDir(settings.downloadDir);
  return currentStatus();
});

ipcMain.handle('pick-files', async () => {
  const r = await dialog.showOpenDialog(win, { properties: ['openFile', 'multiSelections'] });
  if (r.canceled) return [];
  return Promise.all(r.filePaths.map(async (p) => {
    const st = await fsp.stat(p);
    return { id: uid('f'), name: path.basename(p), size: st.size, mime: guessMime(p), path: p };
  }));
});

/** Prépare des fichiers locaux : renvoie les URLs que le mobile viendra chercher. */
ipcMain.handle('offer-files', (_e, files) => {
  if (!server) return null;
  const offer = server.offerFiles(files);
  const host = primaryAddress();
  return {
    ...offer,
    baseUrl: `http://${host}:${server.httpPort}`,
    qrPromise: null,
  };
});

ipcMain.handle('offer-qr', async (_e, transferId) => {
  const host = primaryAddress();
  const url = `castflow://download?host=${host}&http=${server.httpPort}&t=${transferId}`;
  return QRCode.toDataURL(url, { margin: 1, width: 320 });
});

ipcMain.handle('open-folder', (_e, p) => {
  if (p) shell.showItemInFolder(p);
  else shell.openPath(settings.downloadDir);
  return true;
});

/* --------------------------- Cycle de vie --------------------------- */

app.whenReady().then(async () => {
  createWindow();
  try { await startServices(); }
  catch (e) { dialog.showErrorBox('CastFlow', `Impossible de démarrer les services réseau :\n${e.message}`); }

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', async () => {
  await stopServices();
  if (process.platform !== 'darwin') app.quit();
});

app.on('before-quit', () => { discovery?.stop(); });
