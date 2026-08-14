// Pont sécurisé entre le renderer React et le process principal.
const { contextBridge, ipcRenderer } = require('electron');

const invoke = (ch, ...args) => ipcRenderer.invoke(ch, ...args);

const on = (ch, cb) => {
  const handler = (_e, payload) => cb(payload);
  ipcRenderer.on(ch, handler);
  return () => ipcRenderer.removeListener(ch, handler);
};

contextBridge.exposeInMainWorld('castflow', {
  getStatus: () => invoke('status'),
  getDevices: () => invoke('devices'),
  getTransfers: () => invoke('transfers'),
  refresh: () => invoke('refresh'),

  accept: (id) => invoke('accept', id),
  reject: (id) => invoke('reject', id),
  cancel: (id) => invoke('cancel', id),

  regenPin: () => invoke('regen-pin'),
  saveSettings: (s) => invoke('save-settings', s),
  pickDownloadDir: () => invoke('pick-download-dir'),
  pickFiles: () => invoke('pick-files'),
  offerFiles: (files) => invoke('offer-files', files),
  offerQr: (transferId) => invoke('offer-qr', transferId),
  openFolder: (p) => invoke('open-folder', p),

  onStatus: (cb) => on('status', cb),
  onDevices: (cb) => on('devices', cb),
  onTransfer: (cb) => on('transfer', cb),
  onIncomingRequest: (cb) => on('incoming-request', cb),
  onFileDone: (cb) => on('file-done', cb),
  onPeerConnected: (cb) => on('peer-connected', cb),
  onPeerDisconnected: (cb) => on('peer-disconnected', cb),
});
