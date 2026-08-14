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
  image: '#a855f7',
  video: '#ef4444',
  audio: '#f59e0b',
  document: '#3b82f6',
  archive: '#84cc16',
  app: '#22d3ee',
  other: '#64748b',
};

export const catEmoji = {
  image: '🖼', video: '🎬', audio: '🎵',
  document: '📄', archive: '🗜', app: '📦', other: '📁',
};

export const stateLabel = {
  pending: ['En attente', T.amber],
  transferring: ['En cours', T.accent2],
  completed: ['Terminé', T.green],
  rejected: ['Refusé', T.red],
  cancelled: ['Annulé', T.dim],
  failed: ['Échec', T.red],
  idle: ['Prêt', T.dim],
};
