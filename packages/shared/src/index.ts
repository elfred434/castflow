/**
 * CastFlow — protocole partagé entre le desktop (Electron) et le mobile (React Native).
 * Aucune dépendance Node ou RN ici : uniquement du TypeScript portable.
 */

export const PROTOCOL_VERSION = 1;

export const DEFAULT_PORTS = {
  http: 53317,
  ws: 53318,
  discovery: 54545,
} as const;

export const DISCOVERY = {
  announceIntervalMs: 2000,
  deviceTtlMs: 6000,
  broadcastAddress: '255.255.255.255',
} as const;

export const LIMITS = {
  maxParallelUploads: 3,
  chunkSize: 64 * 1024,
  rtcChunkSize: 16 * 1024,
  progressThrottleMs: 200,
  tokenTtlMs: 10 * 60 * 1000,
  pingIntervalMs: 15000,
  maxPinAttempts: 3,
  pinLockoutMs: 60000,
} as const;

/* ------------------------------------------------------------------ */
/* Appareils                                                           */
/* ------------------------------------------------------------------ */

export type Platform = 'windows' | 'macos' | 'linux' | 'android' | 'ios';
export type DeviceKind = 'desktop' | 'mobile';

export interface DeviceInfo {
  id: string;
  name: string;
  platform: Platform;
  kind: DeviceKind;
  /** Empreinte courte de la clé/du certificat, pour l'épinglage. */
  fingerprint?: string;
}

export interface RemoteDevice extends DeviceInfo {
  host: string;
  httpPort: number;
  wsPort: number;
  secure: boolean;
  requiresPin: boolean;
  /** Dernière fois que l'appareil a été vu (ms epoch). */
  lastSeen: number;
  source: 'udp' | 'qr' | 'manual' | 'pin';
}

/* ------------------------------------------------------------------ */
/* Découverte UDP                                                      */
/* ------------------------------------------------------------------ */

export interface AnnouncePacket {
  v: number;
  type: 'ANNOUNCE' | 'DISCOVER' | 'BYE';
  device: DeviceInfo;
  http: number;
  ws: number;
  secure: boolean;
  requiresPin: boolean;
  t: number;
}

/* ------------------------------------------------------------------ */
/* Fichiers et transferts                                              */
/* ------------------------------------------------------------------ */

export interface FileMeta {
  id: string;
  name: string;
  size: number;
  mime: string;
  /** Chemin relatif quand on envoie une arborescence. */
  relPath?: string;
  hash?: string;
  modifiedAt?: number;
  /** URI local (RN) ou chemin absolu (desktop) — jamais transmis sur le réseau. */
  uri?: string;
}

export type TransferState =
  | 'idle'
  | 'pending'
  | 'transferring'
  | 'paused'
  | 'completed'
  | 'rejected'
  | 'cancelled'
  | 'failed';

export type TransferDirection = 'send' | 'receive';

export interface TransferProgress {
  fileId: string;
  received: number;
  total: number;
  bps: number;
}

export interface Transfer {
  id: string;
  direction: TransferDirection;
  peer: DeviceInfo;
  files: FileMeta[];
  totalSize: number;
  transferred: number;
  state: TransferState;
  startedAt: number;
  finishedAt?: number;
  error?: string;
  progress: Record<string, TransferProgress>;
}

/* ------------------------------------------------------------------ */
/* Messages WebSocket                                                  */
/* ------------------------------------------------------------------ */

export type MessageType =
  | 'HELLO'
  | 'HELLO_ACK'
  | 'AUTH'
  | 'AUTH_OK'
  | 'AUTH_FAIL'
  | 'TRANSFER_REQUEST'
  | 'TRANSFER_ACCEPT'
  | 'TRANSFER_REJECT'
  | 'PROGRESS'
  | 'FILE_DONE'
  | 'TRANSFER_COMPLETE'
  | 'OFFER'
  | 'TRANSFER_CANCEL'
  | 'PING'
  | 'PONG'
  | 'ERROR'
  | 'RTC_OFFER'
  | 'RTC_ANSWER'
  | 'RTC_ICE';

export interface Envelope<T = unknown> {
  v: number;
  type: MessageType;
  id: string;
  ts: number;
  /** id du message auquel on répond. */
  re?: string;
  data: T;
}

export interface HelloData { device: DeviceInfo }
export interface HelloAckData {
  device: DeviceInfo;
  nonce: string;
  requiresPin: boolean;
  trusted: boolean;
}
export interface AuthData { proof: string }
export interface AuthOkData { sessionToken: string }
export interface AuthFailData { reason: string; attemptsLeft: number }

export interface TransferRequestData {
  transferId: string;
  files: FileMeta[];
  totalSize: number;
}
export interface TransferAcceptData {
  transferId: string;
  tokens: Record<string, string>;
}
export interface TransferRejectData { transferId: string; reason: string }
export interface ProgressData extends TransferProgress { transferId: string }
export interface FileDoneData { transferId: string; fileId: string; hashOk: boolean }
export interface OfferData {
  transferId: string;
  totalSize: number;
  files: Array<{ id: string; name: string; size: number; mime: string; token: string }>;
}

export interface TransferCompleteData {
  transferId: string;
  files: string[];
  durationMs: number;
}
export interface TransferCancelData { transferId: string; reason: string }
export interface ErrorData { code: ErrorCode; message: string }

export type ErrorCode =
  | 'NO_TOKEN'
  | 'BAD_TOKEN'
  | 'NOT_ACCEPTED'
  | 'UNKNOWN_FILE'
  | 'OFFSET_MISMATCH'
  | 'TOO_LARGE'
  | 'NO_SPACE'
  | 'VERSION_MISMATCH'
  | 'AUTH_REQUIRED'
  | 'HASH_MISMATCH'
  | 'INTERNAL';

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

export function uid(prefix = ''): string {
  const s = Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
  return prefix ? `${prefix}_${s}` : s;
}

export function envelope<T>(type: MessageType, data: T, re?: string): Envelope<T> {
  return { v: PROTOCOL_VERSION, type, id: uid('m'), ts: Date.now(), re, data };
}

export function parseEnvelope(raw: string): Envelope | null {
  try {
    const msg = JSON.parse(raw);
    if (typeof msg !== 'object' || msg === null) return null;
    if (typeof msg.type !== 'string') return null;
    return msg as Envelope;
  } catch {
    return null;
  }
}

/** URL de connexion encodée dans le QR code. */
export function buildConnectUrl(opts: {
  host: string;
  httpPort: number;
  wsPort: number;
  device: DeviceInfo;
  pin?: string;
}): string {
  const p = new URLSearchParams({
    host: opts.host,
    http: String(opts.httpPort),
    ws: String(opts.wsPort),
    id: opts.device.id,
    name: opts.device.name,
    kind: opts.device.kind,
    platform: opts.device.platform,
  });
  if (opts.pin) p.set('pin', opts.pin);
  if (opts.device.fingerprint) p.set('fp', opts.device.fingerprint);
  return `castflow://connect?${p.toString()}`;
}

export function parseConnectUrl(url: string): RemoteDevice | null {
  // Tolère un préfixe WIFI:...;; devant l'URL castflow://
  const idx = url.indexOf('castflow://');
  if (idx === -1) return null;
  const q = url.slice(idx).split('?')[1];
  if (!q) return null;
  const p = new URLSearchParams(q);
  const host = p.get('host');
  const id = p.get('id');
  if (!host || !id) return null;
  return {
    id,
    name: p.get('name') ?? host,
    platform: (p.get('platform') as Platform) ?? 'linux',
    kind: (p.get('kind') as DeviceKind) ?? 'desktop',
    fingerprint: p.get('fp') ?? undefined,
    host,
    httpPort: Number(p.get('http') ?? DEFAULT_PORTS.http),
    wsPort: Number(p.get('ws') ?? DEFAULT_PORTS.ws),
    secure: p.get('secure') === '1',
    requiresPin: p.has('pin'),
    lastSeen: Date.now(),
    source: 'qr',
  };
}

/** Extrait le SSID/mot de passe d'un QR combiné Wi-Fi + CastFlow. */
export function parseWifiPayload(raw: string): { ssid: string; password: string } | null {
  const m = /WIFI:S:([^;]*);(?:T:([^;]*);)?(?:P:([^;]*);)?/.exec(raw);
  if (!m) return null;
  return { ssid: m[1], password: m[3] ?? '' };
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} o`;
  const units = ['Ko', 'Mo', 'Go', 'To'];
  let i = -1;
  let v = n;
  do { v /= 1024; i++; } while (v >= 1024 && i < units.length - 1);
  return `${v.toFixed(v < 10 ? 1 : 0)} ${units[i]}`;
}

export function formatSpeed(bps: number): string {
  return `${formatBytes(bps)}/s`;
}

export function etaSeconds(remaining: number, bps: number): number | null {
  if (bps <= 0) return null;
  return Math.round(remaining / bps);
}

export function formatDuration(sec: number): string {
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  if (m < 60) return `${m}m ${s.toString().padStart(2, '0')}s`;
  return `${Math.floor(m / 60)}h ${(m % 60).toString().padStart(2, '0')}m`;
}

export function generatePin(): string {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

export function guessMime(name: string): string {
  const ext = name.split('.').pop()?.toLowerCase() ?? '';
  const map: Record<string, string> = {
    jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif',
    webp: 'image/webp', heic: 'image/heic', svg: 'image/svg+xml',
    mp4: 'video/mp4', mkv: 'video/x-matroska', mov: 'video/quicktime', avi: 'video/x-msvideo',
    mp3: 'audio/mpeg', wav: 'audio/wav', flac: 'audio/flac', m4a: 'audio/mp4', ogg: 'audio/ogg',
    pdf: 'application/pdf', zip: 'application/zip', rar: 'application/vnd.rar',
    apk: 'application/vnd.android.package-archive',
    txt: 'text/plain', md: 'text/markdown', json: 'application/json',
    doc: 'application/msword',
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  };
  return map[ext] ?? 'application/octet-stream';
}

export type FileCategory = 'image' | 'video' | 'audio' | 'document' | 'archive' | 'app' | 'other';

export function categorize(mime: string, name = ''): FileCategory {
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return 'audio';
  if (mime.includes('android.package')) return 'app';
  if (/zip|rar|7z|tar|gzip/.test(mime)) return 'archive';
  if (/pdf|word|excel|powerpoint|text|opendocument|officedocument/.test(mime)) return 'document';
  if (/\.(apk|exe|dmg|deb)$/i.test(name)) return 'app';
  return 'other';
}
