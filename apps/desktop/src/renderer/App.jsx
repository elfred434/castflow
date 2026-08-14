import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { api, mockApi } from './mock';
import {
  T, Card, Button, Progress, Badge, Icon, FileIcon,
  formatBytes, formatSpeed, formatEta, stateLabel, catColor, category,
} from './ui';

/* ================================================================== */

export default function App() {
  const [tab, setTab] = useState('devices');
  const [status, setStatus] = useState(null);
  const [devices, setDevices] = useState([]);
  const [transfers, setTransfers] = useState([]);
  const [incoming, setIncoming] = useState(null);
  const [outbox, setOutbox] = useState([]);
  const [offer, setOffer] = useState(null);
  const [toast, setToast] = useState(null);

  const notify = useCallback((msg) => {
    setToast(msg);
    setTimeout(() => setToast(null), 3000);
  }, []);

  useEffect(() => {
    api.getStatus().then(setStatus);
    api.getDevices().then(setDevices);
    api.getTransfers().then(setTransfers);

    const offs = [
      api.onStatus(setStatus),
      api.onDevices(setDevices),
      api.onTransfer((t) => setTransfers((prev) => {
        const i = prev.findIndex((x) => x.id === t.id);
        if (i === -1) return [t, ...prev];
        const next = [...prev]; next[i] = t; return next;
      })),
      api.onIncomingRequest((t) => setIncoming(t)),
      api.onFileDone((f) => notify(`Reçu : ${f.name}`)),
    ];
    return () => offs.forEach((f) => f && f());
  }, [notify]);

  const active = transfers.filter((t) => t.state === 'transferring' || t.state === 'pending');
  const done = transfers.filter((t) => !['transferring', 'pending'].includes(t.state));

  const accept = async (id) => { await api.accept(id); setIncoming(null); };
  const reject = async (id) => { await api.reject(id); setIncoming(null); notify('Transfert refusé'); };

  const pickFiles = async () => {
    const files = await api.pickFiles();
    if (files.length) {
      setOutbox((p) => [...p, ...files]);
      setTab('send');
    }
  };

  const publish = async () => {
    if (!outbox.length) return;
    const res = await api.offerFiles(outbox);
    const qr = await api.offerQr(res.transferId);
    setOffer({ ...res, qr });
    notify('Fichiers publiés — scannez le QR depuis le mobile');
  };

  return (
    <div style={{
      display: 'flex', height: '100vh', background: T.bg, color: T.text,
      fontFamily: 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
      overflow: 'hidden',
    }}>
      <Sidebar tab={tab} setTab={setTab} status={status} active={active.length} />

      <main style={{ flex: 1, overflowY: 'auto', padding: '28px 32px' }}>
        <Header status={status} onRefresh={() => { api.refresh(); notify('Recherche en cours…'); }} onPick={pickFiles} />

        {active.length > 0 && (
          <section style={{ marginBottom: 26 }}>
            <SectionTitle>Transferts en cours</SectionTitle>
            <div style={{ display: 'grid', gap: 12 }}>
              {active.map((t) => (
                <TransferCard key={t.id} t={t} onCancel={() => api.cancel(t.id)} onAccept={() => accept(t.id)} onReject={() => reject(t.id)} />
              ))}
            </div>
          </section>
        )}

        {tab === 'devices' && <DevicesTab devices={devices} status={status} onSend={pickFiles} />}
        {tab === 'send' && <SendTab outbox={outbox} setOutbox={setOutbox} onPick={pickFiles} onPublish={publish} offer={offer} />}
        {tab === 'receive' && <ReceiveTab status={status} onRegen={() => api.regenPin().then(setStatus)} />}
        {tab === 'history' && <HistoryTab transfers={done} onOpen={(p) => api.openFolder(p)} />}
        {tab === 'settings' && <SettingsTab status={status} onSave={(s) => api.saveSettings(s).then(setStatus)} onPickDir={() => api.pickDownloadDir().then((s) => s && setStatus(s))} />}
      </main>

      {incoming && <IncomingModal t={incoming} onAccept={() => accept(incoming.id)} onReject={() => reject(incoming.id)} />}
      {toast && <Toast>{toast}</Toast>}
    </div>
  );
}

/* ---------------------------- Layout ---------------------------- */

function SectionTitle({ children, right }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
      <h2 style={{ fontSize: 13, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase', color: T.dim, margin: 0 }}>{children}</h2>
      {right}
    </div>
  );
}

function Sidebar({ tab, setTab, status, active }) {
  const items = [
    ['devices', 'Appareils', 'devices'],
    ['send', 'Envoyer', 'send'],
    ['receive', 'Recevoir', 'receive'],
    ['history', 'Historique', 'history'],
    ['settings', 'Réglages', 'settings'],
  ];
  return (
    <aside style={{
      width: 232, flexShrink: 0, background: '#0a1424',
      borderRight: `1px solid ${T.border}`, padding: '22px 14px',
      display: 'flex', flexDirection: 'column',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '0 8px 22px' }}>
        <div style={{
          width: 34, height: 34, borderRadius: 10,
          background: `linear-gradient(135deg, ${T.accent}, ${T.accent2})`,
          display: 'grid', placeItems: 'center', color: '#fff',
        }}>
          <Icon name="wifi" size={19} />
        </div>
        <div>
          <div style={{ fontWeight: 800, fontSize: 17, letterSpacing: -0.3 }}>CastFlow</div>
          <div style={{ fontSize: 10.5, color: T.dim }}>Transfert local</div>
        </div>
      </div>

      <nav style={{ display: 'grid', gap: 3 }}>
        {items.map(([id, label, icon]) => (
          <button key={id} onClick={() => setTab(id)} style={{
            display: 'flex', alignItems: 'center', gap: 11, width: '100%',
            padding: '10px 12px', borderRadius: 10, cursor: 'pointer',
            fontSize: 14, fontWeight: 600, fontFamily: 'inherit', textAlign: 'left',
            border: '1px solid transparent',
            background: tab === id ? `${T.accent}22` : 'transparent',
            color: tab === id ? '#fff' : T.dim,
            borderColor: tab === id ? `${T.accent}44` : 'transparent',
          }}>
            <Icon name={icon} size={18} />
            <span style={{ flex: 1 }}>{label}</span>
            {id === 'send' && active > 0 && <Badge color={T.accent2}>{active}</Badge>}
          </button>
        ))}
      </nav>

      <div style={{ marginTop: 'auto', padding: '14px 10px 0', borderTop: `1px solid ${T.border}` }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
          <span style={{
            width: 8, height: 8, borderRadius: 999,
            background: status?.running ? T.green : T.red,
            boxShadow: status?.running ? `0 0 8px ${T.green}` : 'none',
          }} />
          <span style={{ fontSize: 12, color: status?.running ? T.green : T.red, fontWeight: 600 }}>
            {status?.running ? 'En ligne' : 'Hors ligne'}
          </span>
        </div>
        <div style={{ fontSize: 11, color: T.dim, fontFamily: 'ui-monospace, monospace', wordBreak: 'break-all' }}>
          {status ? `${status.host}:${status.httpPort ?? '—'}` : '…'}
        </div>
      </div>
    </aside>
  );
}

function Header({ status, onRefresh, onPick }) {
  return (
    <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', marginBottom: 26, gap: 16 }}>
      <div>
        <h1 style={{ fontSize: 25, fontWeight: 800, margin: 0, letterSpacing: -0.5 }}>
          {status?.device?.name ?? 'CastFlow'}
        </h1>
        <p style={{ color: T.dim, fontSize: 13.5, margin: '5px 0 0' }}>
          Partagez vos fichiers en Wi-Fi local, sans internet ni câble.
        </p>
      </div>
      <div style={{ display: 'flex', gap: 9 }}>
        <Button variant="ghost" icon="refresh" onClick={onRefresh}>Actualiser</Button>
        <Button icon="plus" onClick={onPick}>Ajouter des fichiers</Button>
      </div>
    </div>
  );
}

/* ---------------------------- Onglets ---------------------------- */

function DevicesTab({ devices, status, onSend }) {
  return (
    <>
      <SectionTitle right={<span style={{ fontSize: 12, color: T.dim }}>{devices.length} détecté{devices.length > 1 ? 's' : ''}</span>}>
        Appareils sur le réseau
      </SectionTitle>

      {devices.length === 0 ? (
        <Card style={{ textAlign: 'center', padding: '46px 20px' }}>
          <div style={{ color: T.dim, marginBottom: 14, display: 'grid', placeItems: 'center' }}>
            <Icon name="wifi" size={44} />
          </div>
          <div style={{ fontWeight: 700, marginBottom: 6 }}>Aucun appareil détecté</div>
          <div style={{ color: T.dim, fontSize: 13, maxWidth: 420, margin: '0 auto', lineHeight: 1.6 }}>
            Vérifiez que le téléphone est sur le même Wi-Fi (ou connecté au point d'accès),
            puis ouvrez CastFlow sur celui-ci. Sinon, allez dans <b>Recevoir</b> pour scanner le QR code.
          </div>
        </Card>
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(260px, 1fr))', gap: 13 }}>
          {devices.map((d) => (
            <Card key={d.id} style={{ padding: 16 }}>
              <div style={{ display: 'flex', gap: 12, alignItems: 'center', marginBottom: 13 }}>
                <div style={{
                  width: 42, height: 42, borderRadius: 12,
                  background: `${T.accent}1f`, color: T.accent,
                  display: 'grid', placeItems: 'center',
                }}>
                  <Icon name={d.kind === 'mobile' ? 'phone' : 'desktop'} size={21} />
                </div>
                <div style={{ minWidth: 0, flex: 1 }}>
                  <div style={{ fontWeight: 700, fontSize: 14.5, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{d.name}</div>
                  <div style={{ fontSize: 11.5, color: T.dim, fontFamily: 'ui-monospace, monospace' }}>{d.host}</div>
                </div>
              </div>
              <div style={{ display: 'flex', gap: 6, marginBottom: 13, flexWrap: 'wrap' }}>
                <Badge color={T.accent2}>{d.platform}</Badge>
                {d.requiresPin && <Badge color={T.amber}>PIN</Badge>}
                <Badge color={T.green}>{d.source === 'udp' ? 'auto' : d.source}</Badge>
              </div>
              <Button icon="send" style={{ width: '100%', justifyContent: 'center' }} onClick={onSend}>
                Envoyer vers cet appareil
              </Button>
            </Card>
          ))}
        </div>
      )}
    </>
  );
}

function SendTab({ outbox, setOutbox, onPick, onPublish, offer }) {
  const total = outbox.reduce((s, f) => s + f.size, 0);
  return (
    <>
      <SectionTitle right={outbox.length > 0 && (
        <span style={{ fontSize: 12, color: T.dim }}>{outbox.length} fichier(s) — {formatBytes(total)}</span>
      )}>
        Fichiers à envoyer
      </SectionTitle>

      <div
        onDragOver={(e) => e.preventDefault()}
        onDrop={(e) => {
          e.preventDefault();
          const files = [...e.dataTransfer.files].map((f, i) => ({
            id: `drop_${Date.now()}_${i}`, name: f.name, size: f.size,
            mime: f.type || 'application/octet-stream', path: f.path,
          }));
          setOutbox((p) => [...p, ...files]);
        }}
        style={{
          border: `2px dashed ${T.border}`, borderRadius: 16, padding: '30px 20px',
          textAlign: 'center', marginBottom: 16, background: `${T.panel}88`,
        }}
      >
        <div style={{ color: T.dim, marginBottom: 10, display: 'grid', placeItems: 'center' }}>
          <Icon name="plus" size={32} />
        </div>
        <div style={{ fontWeight: 600, marginBottom: 4 }}>Glissez vos fichiers ici</div>
        <div style={{ fontSize: 12.5, color: T.dim, marginBottom: 14 }}>ou parcourez votre ordinateur</div>
        <Button variant="ghost" icon="folder" onClick={onPick}>Parcourir</Button>
      </div>

      {outbox.length > 0 && (
        <>
          <Card style={{ padding: 8, marginBottom: 16 }}>
            {outbox.map((f) => (
              <div key={f.id} style={{
                display: 'flex', alignItems: 'center', gap: 12, padding: '9px 11px',
                borderRadius: 10,
              }}>
                <FileIcon mime={f.mime} name={f.name} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 13.5, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{f.name}</div>
                  <div style={{ fontSize: 11.5, color: T.dim }}>{formatBytes(f.size)}</div>
                </div>
                <button
                  onClick={() => setOutbox((p) => p.filter((x) => x.id !== f.id))}
                  style={{ background: 'none', border: 'none', color: T.dim, cursor: 'pointer', padding: 6 }}
                  title="Retirer"
                >
                  <Icon name="x" size={16} />
                </button>
              </div>
            ))}
          </Card>

          <div style={{ display: 'flex', gap: 10, marginBottom: 22 }}>
            <Button icon="qr" onClick={onPublish}>Publier et afficher le QR</Button>
            <Button variant="ghost" onClick={() => setOutbox([])}>Tout retirer</Button>
          </div>
        </>
      )}

      {offer && (
        <Card>
          <SectionTitle>Prêt à recevoir sur le mobile</SectionTitle>
          <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'center' }}>
            <img src={offer.qr} alt="QR de téléchargement" width={190} height={190}
              style={{ borderRadius: 12, background: '#fff', padding: 8 }} />
            <div style={{ flex: 1, minWidth: 240 }}>
              <p style={{ color: T.dim, fontSize: 13.5, lineHeight: 1.7, marginTop: 0 }}>
                Scannez ce code depuis l'application mobile CastFlow. Le téléphone téléchargera
                directement les {offer.files.length} fichier(s) depuis ce PC.
              </p>
              <div style={{
                fontFamily: 'ui-monospace, monospace', fontSize: 12, color: T.accent2,
                background: '#0a1526', padding: '10px 12px', borderRadius: 8, wordBreak: 'break-all',
              }}>
                {offer.baseUrl}/download/{offer.transferId}/…
              </div>
            </div>
          </div>
        </Card>
      )}
    </>
  );
}

function ReceiveTab({ status, onRegen }) {
  if (!status) return null;
  return (
    <>
      <SectionTitle>Connexion du mobile</SectionTitle>
      <div style={{ display: 'grid', gridTemplateColumns: 'minmax(240px, 300px) 1fr', gap: 18, alignItems: 'start' }}>
        <Card style={{ textAlign: 'center' }}>
          <img src={status.qr} alt="QR de connexion" width={220} height={220}
            style={{ borderRadius: 12, background: '#fff', padding: 10, maxWidth: '100%' }} />
          <div style={{ fontSize: 12.5, color: T.dim, marginTop: 12 }}>
            Scannez avec CastFlow Mobile
          </div>
        </Card>

        <div style={{ display: 'grid', gap: 14 }}>
          {status.pin && (
            <Card>
              <SectionTitle right={<Button variant="ghost" icon="refresh" style={{ padding: '6px 11px', fontSize: 12.5 }} onClick={onRegen}>Nouveau</Button>}>
                Code PIN
              </SectionTitle>
              <div style={{ display: 'flex', gap: 9 }}>
                {status.pin.split('').map((c, i) => (
                  <div key={i} style={{
                    flex: 1, textAlign: 'center', padding: '13px 0',
                    background: '#0a1526', border: `1px solid ${T.border}`, borderRadius: 10,
                    fontSize: 25, fontWeight: 800, fontFamily: 'ui-monospace, monospace',
                    color: T.accent2, letterSpacing: 1,
                  }}>{c}</div>
                ))}
              </div>
              <p style={{ fontSize: 12.5, color: T.dim, margin: '12px 0 0', lineHeight: 1.6 }}>
                <Icon name="shield" size={13} style={{ verticalAlign: -2, marginRight: 5 }} />
                Saisissez ce code sur le téléphone pour autoriser la connexion.
              </p>
            </Card>
          )}

          <Card>
            <SectionTitle>Connexion manuelle</SectionTitle>
            <div style={{ display: 'grid', gap: 10 }}>
              <Row label="Adresse" value={`${status.host}:${status.httpPort}`} mono />
              <Row label="Signalisation" value={`ws://${status.host}:${status.wsPort}`} mono />
              <Row label="Réception dans" value={status.settings?.downloadDir} mono />
            </div>
            {status.addresses?.length > 1 && (
              <p style={{ fontSize: 12, color: T.dim, marginBottom: 0, marginTop: 12 }}>
                Autres interfaces : {status.addresses.slice(1).map((a) => `${a.address} (${a.iface})`).join(', ')}
              </p>
            )}
          </Card>

          <Card>
            <SectionTitle>Pas de Wi-Fi à proximité ?</SectionTitle>
            <ol style={{ color: T.dim, fontSize: 13, lineHeight: 1.85, margin: 0, paddingLeft: 19 }}>
              <li>Activez le <b style={{ color: T.text }}>point d'accès mobile</b> sur le téléphone.</li>
              <li>Connectez ce PC à ce réseau Wi-Fi.</li>
              <li>Revenez ici : l'adresse passe en <code style={{ color: T.accent2 }}>192.168.43.x</code>.</li>
              <li>Scannez le QR ci-contre depuis le mobile.</li>
            </ol>
          </Card>
        </div>
      </div>
    </>
  );
}

function Row({ label, value, mono }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 14, alignItems: 'baseline' }}>
      <span style={{ fontSize: 13, color: T.dim, flexShrink: 0 }}>{label}</span>
      <span style={{
        fontSize: 12.5, fontFamily: mono ? 'ui-monospace, monospace' : 'inherit',
        color: T.text, textAlign: 'right', wordBreak: 'break-all',
      }}>{value ?? '—'}</span>
    </div>
  );
}

function HistoryTab({ transfers, onOpen }) {
  if (!transfers.length) {
    return (
      <Card style={{ textAlign: 'center', padding: '46px 20px', color: T.dim }}>
        <Icon name="history" size={40} />
        <div style={{ marginTop: 12, fontSize: 13.5 }}>Aucun transfert terminé pour le moment.</div>
      </Card>
    );
  }
  return (
    <>
      <SectionTitle>Historique</SectionTitle>
      <div style={{ display: 'grid', gap: 11 }}>
        {transfers.map((t) => {
          const [label, color] = stateLabel[t.state] ?? ['—', T.dim];
          return (
            <Card key={t.id} style={{ padding: 15 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 13 }}>
                <div style={{
                  width: 38, height: 38, borderRadius: 10, flexShrink: 0,
                  background: `${color}1f`, color,
                  display: 'grid', placeItems: 'center',
                }}>
                  <Icon name={t.direction === 'receive' ? 'receive' : 'send'} size={19} />
                </div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontWeight: 650, fontSize: 14 }}>
                    {t.files.length} fichier{t.files.length > 1 ? 's' : ''} · {formatBytes(t.totalSize)}
                  </div>
                  <div style={{ fontSize: 12, color: T.dim, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {t.direction === 'receive' ? 'De' : 'Vers'} {t.peer?.name} · {new Date(t.startedAt).toLocaleString('fr-FR')}
                  </div>
                </div>
                <Badge color={color}>{label}</Badge>
                {t.state === 'completed' && (
                  <Button variant="ghost" icon="folder" style={{ padding: '7px 12px', fontSize: 12.5 }}
                    onClick={() => onOpen(t.files[0]?.path)}>Ouvrir</Button>
                )}
              </div>
            </Card>
          );
        })}
      </div>
    </>
  );
}

function SettingsTab({ status, onSave, onPickDir }) {
  if (!status) return null;
  const s = status.settings ?? {};
  return (
    <>
      <SectionTitle>Réglages</SectionTitle>
      <div style={{ display: 'grid', gap: 14, maxWidth: 640 }}>
        <Card>
          <Toggle
            label="Exiger un code PIN"
            hint="Les nouveaux appareils doivent saisir le PIN affiché avant de pouvoir envoyer."
            checked={!!s.requirePin}
            onChange={(v) => onSave({ requirePin: v })}
          />
          <div style={{ height: 1, background: T.border, margin: '15px 0' }} />
          <Toggle
            label="Accepter automatiquement"
            hint="Reçoit les fichiers sans demander de confirmation. Pratique, mais moins sûr."
            checked={!!s.autoAccept}
            onChange={(v) => onSave({ autoAccept: v })}
          />
        </Card>

        <Card>
          <SectionTitle>Dossier de réception</SectionTitle>
          <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
            <div style={{
              flex: 1, padding: '10px 12px', background: '#0a1526',
              border: `1px solid ${T.border}`, borderRadius: 9,
              fontFamily: 'ui-monospace, monospace', fontSize: 12, wordBreak: 'break-all',
            }}>{s.downloadDir}</div>
            <Button variant="ghost" icon="folder" onClick={onPickDir}>Changer</Button>
          </div>
        </Card>

        <Card>
          <SectionTitle>À propos de cet appareil</SectionTitle>
          <div style={{ display: 'grid', gap: 9 }}>
            <Row label="Nom" value={status.device?.name} />
            <Row label="Plateforme" value={status.device?.platform} />
            <Row label="Identifiant" value={status.device?.id} mono />
            <Row label="Empreinte" value={status.device?.fingerprint} mono />
            <Row label="Ports" value={`HTTP ${status.httpPort} · WS ${status.wsPort} · UDP 54545`} mono />
          </div>
        </Card>

        {api.__demo && (
          <Card style={{ borderColor: `${T.amber}55` }}>
            <SectionTitle>Mode démonstration</SectionTitle>
            <p style={{ color: T.dim, fontSize: 13, lineHeight: 1.6, marginTop: 0 }}>
              L'application tourne hors d'Electron : les données sont simulées.
              Lancez <code style={{ color: T.accent2 }}>npm run dev:desktop</code> pour le vrai serveur réseau.
            </p>
            <Button variant="ghost" icon="receive" onClick={() => mockApi.__simulateIncoming()}>
              Simuler une réception
            </Button>
          </Card>
        )}
      </div>
    </>
  );
}

function Toggle({ label, hint, checked, onChange }) {
  return (
    <div style={{ display: 'flex', gap: 16, alignItems: 'flex-start' }}>
      <div style={{ flex: 1 }}>
        <div style={{ fontWeight: 650, fontSize: 14, marginBottom: 3 }}>{label}</div>
        <div style={{ fontSize: 12.5, color: T.dim, lineHeight: 1.55 }}>{hint}</div>
      </div>
      <button onClick={() => onChange(!checked)} style={{
        width: 46, height: 26, borderRadius: 999, flexShrink: 0, cursor: 'pointer',
        border: `1px solid ${checked ? T.accent : T.border}`,
        background: checked ? T.accent : '#0a1526',
        position: 'relative', transition: 'background .2s',
      }}>
        <span style={{
          position: 'absolute', top: 2, left: checked ? 22 : 2,
          width: 20, height: 20, borderRadius: 999, background: '#fff',
          transition: 'left .2s',
        }} />
      </button>
    </div>
  );
}

/* ---------------------------- Transferts ---------------------------- */

function TransferCard({ t, onCancel, onAccept, onReject }) {
  const [label, color] = stateLabel[t.state] ?? ['—', T.dim];
  const pct = t.totalSize ? (t.transferred / t.totalSize) * 100 : 0;
  const remaining = t.totalSize - t.transferred;

  return (
    <Card style={{ padding: 16 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 13 }}>
        <div style={{
          width: 38, height: 38, borderRadius: 10, flexShrink: 0,
          background: `${color}1f`, color, display: 'grid', placeItems: 'center',
        }}>
          <Icon name={t.direction === 'receive' ? 'receive' : 'send'} size={19} />
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 14.5 }}>
            {t.direction === 'receive' ? 'Réception de' : 'Envoi vers'} {t.peer?.name}
          </div>
          <div style={{ fontSize: 12, color: T.dim }}>
            {t.files.length} fichier{t.files.length > 1 ? 's' : ''} · {formatBytes(t.totalSize)}
          </div>
        </div>
        <Badge color={color}>{label}</Badge>
        {t.state === 'pending' ? (
          <div style={{ display: 'flex', gap: 7 }}>
            <Button variant="success" icon="check" style={{ padding: '8px 13px', fontSize: 13 }} onClick={onAccept}>Accepter</Button>
            <Button variant="danger" icon="x" style={{ padding: '8px 13px', fontSize: 13 }} onClick={onReject}>Refuser</Button>
          </div>
        ) : t.state === 'transferring' && (
          <Button variant="danger" icon="x" style={{ padding: '8px 13px', fontSize: 13 }} onClick={onCancel}>Annuler</Button>
        )}
      </div>

      {t.state === 'transferring' && (
        <>
          <Progress value={pct} color={color} />
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, color: T.dim, marginTop: 7 }}>
            <span>{formatBytes(t.transferred)} / {formatBytes(t.totalSize)} · {Math.round(pct)} %</span>
            <span>{formatSpeed(t.bps || 0)} · reste {formatEta(remaining, t.bps)}</span>
          </div>
        </>
      )}

      <div style={{ marginTop: 12, display: 'grid', gap: 7 }}>
        {t.files.map((f) => {
          const fp = f.size ? (f.received / f.size) * 100 : 0;
          return (
            <div key={f.id} style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
              <FileIcon mime={f.mime} name={f.name} size={30} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, marginBottom: 4 }}>
                  <span style={{ fontSize: 12.5, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{f.name}</span>
                  <span style={{ fontSize: 11.5, color: f.done ? T.green : T.dim, flexShrink: 0 }}>
                    {f.done ? '✓ terminé' : `${formatBytes(f.received)} / ${formatBytes(f.size)}`}
                  </span>
                </div>
                <Progress value={fp} height={3} color={f.done ? T.green : catColor[category(f.mime, f.name)]} />
              </div>
            </div>
          );
        })}
      </div>
    </Card>
  );
}

function IncomingModal({ t, onAccept, onReject }) {
  return (
    <div style={{
      position: 'fixed', inset: 0, background: '#020617cc', backdropFilter: 'blur(4px)',
      display: 'grid', placeItems: 'center', zIndex: 50, padding: 20,
    }}>
      <Card style={{ width: 'min(480px, 100%)', boxShadow: '0 24px 60px #0009' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 13, marginBottom: 16 }}>
          <div style={{
            width: 46, height: 46, borderRadius: 13,
            background: `${T.accent}22`, color: T.accent,
            display: 'grid', placeItems: 'center',
          }}>
            <Icon name="receive" size={23} />
          </div>
          <div>
            <div style={{ fontWeight: 800, fontSize: 17 }}>Fichiers entrants</div>
            <div style={{ fontSize: 13, color: T.dim }}>
              {t.peer?.name} souhaite vous envoyer {t.files.length} fichier{t.files.length > 1 ? 's' : ''}
            </div>
          </div>
        </div>

        <div style={{ background: '#0a1526', borderRadius: 11, padding: 10, marginBottom: 16, maxHeight: 220, overflowY: 'auto' }}>
          {t.files.map((f) => (
            <div key={f.id} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '7px 5px' }}>
              <FileIcon mime={f.mime} name={f.name} size={32} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 13, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{f.name}</div>
                <div style={{ fontSize: 11.5, color: T.dim }}>{formatBytes(f.size)}</div>
              </div>
            </div>
          ))}
        </div>

        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 12 }}>
          <span style={{ fontSize: 13, color: T.dim }}>Total : <b style={{ color: T.text }}>{formatBytes(t.totalSize)}</b></span>
          <div style={{ display: 'flex', gap: 9 }}>
            <Button variant="ghost" onClick={onReject}>Refuser</Button>
            <Button variant="success" icon="check" onClick={onAccept}>Accepter</Button>
          </div>
        </div>
      </Card>
    </div>
  );
}

function Toast({ children }) {
  return (
    <div style={{
      position: 'fixed', bottom: 24, left: '50%', transform: 'translateX(-50%)',
      background: T.panel2, border: `1px solid ${T.border}`, color: T.text,
      padding: '12px 20px', borderRadius: 11, fontSize: 13.5, fontWeight: 600,
      boxShadow: '0 12px 34px #0008', zIndex: 60,
    }}>{children}</div>
  );
}
