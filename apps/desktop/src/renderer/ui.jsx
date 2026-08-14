import React from 'react';

/* ---------------------------- helpers ---------------------------- */

export function formatBytes(n) {
  if (!n) return '0 o';
  if (n < 1024) return `${Math.round(n)} o`;
  const units = ['Ko', 'Mo', 'Go', 'To'];
  let i = -1; let v = n;
  do { v /= 1024; i++; } while (v >= 1024 && i < units.length - 1);
  return `${v.toFixed(v < 10 ? 1 : 0)} ${units[i]}`;
}

export const formatSpeed = (bps) => `${formatBytes(bps)}/s`;

export function formatEta(remaining, bps) {
  if (!bps || bps <= 0) return '—';
  const s = Math.round(remaining / bps);
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  return m < 60 ? `${m} min ${String(s % 60).padStart(2, '0')}` : `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, '0')}`;
}

export function category(mime = '', name = '') {
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return 'audio';
  if (mime.includes('android.package') || /\.(apk|exe|dmg|deb)$/i.test(name)) return 'app';
  if (/zip|rar|7z|tar|gzip/.test(mime)) return 'archive';
  if (/pdf|word|excel|powerpoint|text|presentation|sheet|document/.test(mime)) return 'document';
  return 'other';
}

/* ---------------------------- icônes ---------------------------- */

const strokeProps = { fill: 'none', stroke: 'currentColor', strokeWidth: 1.7, strokeLinecap: 'round', strokeLinejoin: 'round' };

export function Icon({ name, size = 20, style }) {
  const paths = {
    send: <><path d="M4 12h13M12 5l7 7-7 7" /></>,
    receive: <><path d="M20 12H7M12 19l-7-7 7-7" /></>,
    devices: <><rect x="2" y="4" width="13" height="10" rx="1.5" /><path d="M6 18h6" /><rect x="17" y="9" width="5" height="11" rx="1.5" /></>,
    history: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>,
    settings: <><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-2.7 1.1v.2a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-2.8-1.1l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A1.6 1.6 0 0 0 3.5 15H3a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.1-2.7l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 2.7 1.1l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z" /></>,
    qr: <><rect x="3" y="3" width="7" height="7" rx="1" /><rect x="14" y="3" width="7" height="7" rx="1" /><rect x="3" y="14" width="7" height="7" rx="1" /><path d="M14 14h3v3h-3zM19 14h2M14 19h3M19 17v4" /></>,
    plus: <><path d="M12 5v14M5 12h14" /></>,
    folder: <><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" /></>,
    refresh: <><path d="M21 12a9 9 0 1 1-3-6.7M21 4v5h-5" /></>,
    check: <><path d="M20 6 9 17l-5-5" /></>,
    x: <><path d="M18 6 6 18M6 6l12 12" /></>,
    image: <><rect x="3" y="4" width="18" height="16" rx="2" /><circle cx="8.5" cy="9.5" r="1.5" /><path d="m21 16-5-5-9 9" /></>,
    video: <><rect x="2" y="5" width="14" height="14" rx="2" /><path d="m22 8-6 4 6 4z" /></>,
    audio: <><path d="M9 18V6l10-2v12" /><circle cx="6.5" cy="18" r="2.5" /><circle cx="16.5" cy="16" r="2.5" /></>,
    document: <><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" /><path d="M14 3v5h5M9 13h6M9 17h4" /></>,
    archive: <><rect x="3" y="4" width="18" height="5" rx="1" /><path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9M10 13h4" /></>,
    app: <><rect x="4" y="2" width="16" height="20" rx="3" /><path d="M10 18h4" /></>,
    other: <><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" /><path d="M14 3v5h5" /></>,
    phone: <><rect x="6" y="2" width="12" height="20" rx="3" /><path d="M10 18h4" /></>,
    desktop: <><rect x="2" y="4" width="20" height="13" rx="2" /><path d="M8 21h8M12 17v4" /></>,
    wifi: <><path d="M2 8.8a16 16 0 0 1 20 0M5 12.5a11 11 0 0 1 14 0M8.5 16a6 6 0 0 1 7 0" /><circle cx="12" cy="19.5" r="1" fill="currentColor" /></>,
    link: <><path d="M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1" /><path d="M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1" /></>,
    shield: <><path d="M12 3 4 6v6c0 5 3.4 8.4 8 9 4.6-.6 8-4 8-9V6z" /><path d="m9 12 2 2 4-4" /></>,
  };
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={style} {...strokeProps}>
      {paths[name] ?? paths.other}
    </svg>
  );
}

/* ---------------------------- styles ---------------------------- */

export const T = {
  bg: '#0b1120',
  panel: '#111c31',
  panel2: '#16233c',
  border: '#1f3252',
  text: '#e8eefc',
  dim: '#8ea3c7',
  accent: '#3b82f6',
  accent2: '#22d3ee',
  green: '#22c55e',
  red: '#ef4444',
  amber: '#f59e0b',
};

export const catColor = {
  image: '#a855f7', video: '#ef4444', audio: '#f59e0b',
  document: '#3b82f6', archive: '#84cc16', app: '#22d3ee', other: '#64748b',
};

export function Card({ children, style, ...rest }) {
  return (
    <div style={{
      background: T.panel,
      border: `1px solid ${T.border}`,
      borderRadius: 16,
      padding: 20,
      ...style,
    }} {...rest}>{children}</div>
  );
}

export function Button({ children, variant = 'primary', icon, style, ...rest }) {
  const variants = {
    primary: { background: T.accent, color: '#fff', border: '1px solid transparent' },
    ghost: { background: 'transparent', color: T.dim, border: `1px solid ${T.border}` },
    success: { background: T.green, color: '#052e16', border: '1px solid transparent' },
    danger: { background: 'transparent', color: T.red, border: `1px solid ${T.red}44` },
  };
  return (
    <button
      style={{
        display: 'inline-flex', alignItems: 'center', gap: 8,
        padding: '10px 16px', borderRadius: 10, cursor: 'pointer',
        fontSize: 14, fontWeight: 600, fontFamily: 'inherit',
        transition: 'filter .15s, transform .05s',
        ...variants[variant], ...style,
      }}
      onMouseDown={(e) => { e.currentTarget.style.transform = 'scale(0.98)'; }}
      onMouseUp={(e) => { e.currentTarget.style.transform = 'scale(1)'; }}
      onMouseLeave={(e) => { e.currentTarget.style.transform = 'scale(1)'; }}
      {...rest}
    >
      {icon && <Icon name={icon} size={17} />}
      {children}
    </button>
  );
}

export function Progress({ value, color = T.accent, height = 6 }) {
  return (
    <div style={{ height, background: '#0a1526', borderRadius: height, overflow: 'hidden' }}>
      <div style={{
        width: `${Math.max(0, Math.min(100, value))}%`,
        height: '100%',
        background: `linear-gradient(90deg, ${color}, ${T.accent2})`,
        borderRadius: height,
        transition: 'width .3s ease',
      }} />
    </div>
  );
}

export function Badge({ children, color = T.dim }) {
  return (
    <span style={{
      fontSize: 11, fontWeight: 700, letterSpacing: .3, textTransform: 'uppercase',
      color, background: `${color}1a`, border: `1px solid ${color}33`,
      padding: '3px 8px', borderRadius: 999, whiteSpace: 'nowrap',
    }}>{children}</span>
  );
}

export const stateLabel = {
  pending: ['En attente', T.amber],
  transferring: ['En cours', T.accent2],
  completed: ['Terminé', T.green],
  rejected: ['Refusé', T.red],
  cancelled: ['Annulé', T.dim],
  failed: ['Échec', T.red],
  paused: ['En pause', T.amber],
  idle: ['Prêt', T.dim],
};

export function FileIcon({ mime, name, size = 38 }) {
  const c = category(mime, name);
  return (
    <div style={{
      width: size, height: size, borderRadius: 10, flexShrink: 0,
      background: `${catColor[c]}1f`, color: catColor[c],
      display: 'grid', placeItems: 'center',
    }}>
      <Icon name={c} size={size * 0.5} />
    </div>
  );
}
