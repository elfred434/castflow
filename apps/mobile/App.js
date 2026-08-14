import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  View, Text, ScrollView, TouchableOpacity, TextInput, Modal,
  ActivityIndicator, Alert, Platform, StyleSheet, StatusBar,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import * as DocumentPicker from 'expo-document-picker';
import * as ImagePicker from 'expo-image-picker';
import * as FileSystem from 'expo-file-system';
import * as Device from 'expo-device';
import * as Network from 'expo-network';
import { CameraView, useCameraPermissions } from 'expo-camera';
import AsyncStorage from '@react-native-async-storage/async-storage';

import {
  CastFlowClient, parseConnectUrl, parseWifiPayload,
  formatBytes, formatSpeed, formatEta, guessMime, category, uid, DEFAULT_PORTS,
  hashBase64, hashMatches,
} from './src/client';
import { T, catColor, catEmoji } from './src/theme';

/* ================================================================== */

export default function App() {
  return (
    <SafeAreaProvider>
      <StatusBar barStyle="light-content" backgroundColor={T.bg} />
      <Main />
    </SafeAreaProvider>
  );
}

function Main() {
  const [device, setDevice] = useState(null);
  const [screen, setScreen] = useState('home');       // home | scan | pin | send
  const [peer, setPeer] = useState(null);
  const [connecting, setConnecting] = useState(false);
  const [connected, setConnected] = useState(false);
  const [pinPrompt, setPinPrompt] = useState(false);
  const [pinValue, setPinValue] = useState('');
  const [pinError, setPinError] = useState('');
  const [files, setFiles] = useState([]);
  const [progress, setProgress] = useState(null);
  const [history, setHistory] = useState([]);
  const [manualIp, setManualIp] = useState('');
  const [offer, setOffer] = useState(null);          // offre reçue du PC
  const [downloading, setDownloading] = useState(null);
  const [netInfo, setNetInfo] = useState(null);
  const clientRef = useRef(null);

  /* --------- identité persistée --------- */
  useEffect(() => {
    (async () => {
      let saved = await AsyncStorage.getItem('castflow:identity');
      let identity = saved ? JSON.parse(saved) : null;
      if (!identity) {
        identity = {
          id: uid('dev'),
          name: Device.deviceName || `${Device.brand ?? 'Mobile'} ${Device.modelName ?? ''}`.trim() || 'Mon téléphone',
          platform: Platform.OS === 'ios' ? 'ios' : 'android',
          kind: 'mobile',
          fingerprint: uid('fp').slice(-12),
        };
        await AsyncStorage.setItem('castflow:identity', JSON.stringify(identity));
      }
      setDevice(identity);

      const h = await AsyncStorage.getItem('castflow:history');
      if (h) setHistory(JSON.parse(h));

      try {
        const ip = await Network.getIpAddressAsync();
        const state = await Network.getNetworkStateAsync();
        setNetInfo({ ip, type: state.type, connected: state.isConnected });
      } catch { /* ignore */ }
    })();
  }, []);

  const saveHistory = useCallback(async (entry) => {
    const next = [entry, ...history].slice(0, 40);
    setHistory(next);
    await AsyncStorage.setItem('castflow:history', JSON.stringify(next));
  }, [history]);

  /* --------- connexion --------- */

  const connectTo = useCallback(async (target) => {
    if (!device) return;
    setConnecting(true);
    setPeer(target);
    try {
      const client = new CastFlowClient(device, { uploadFile: uploadWithExpo, downloadFile: downloadWithExpo });
      clientRef.current = client;
      client.on('disconnected', () => setConnected(false));
      client.on('OFFER', (data) => setOffer(data)); // le PC propose des fichiers
      const ack = await client.connect(target);

      if (ack.requiresPin) {
        if (target.pin) {
          const r = await client.authenticate(target.pin);
          if (!r.ok) { setPinPrompt(true); setPinError('PIN du QR refusé'); setConnecting(false); return; }
        } else {
          setPinPrompt(true);
          setConnecting(false);
          return;
        }
      }
      setConnected(true);
      setScreen('send');
    } catch (e) {
      Alert.alert('Connexion échouée', e.message);
      setPeer(null);
    } finally {
      setConnecting(false);
    }
  }, [device]);

  const submitPin = async () => {
    const client = clientRef.current;
    if (!client) return;
    const r = await client.authenticate(pinValue);
    if (r.ok) {
      setPinPrompt(false);
      setPinValue('');
      setPinError('');
      setConnected(true);
      setScreen('send');
    } else {
      setPinError(`${r.reason} — ${r.attemptsLeft} essai(s) restant(s)`);
      setPinValue('');
    }
  };

  const onScan = ({ data }) => {
    const target = parseConnectUrl(data);
    if (!target) {
      Alert.alert('QR non reconnu', 'Ce code ne correspond pas à un appareil CastFlow.');
      return;
    }
    const wifi = parseWifiPayload(data);
    setScreen('home');
    if (wifi) {
      Alert.alert(
        'Réseau à rejoindre',
        `Ce PC est sur le réseau « ${wifi.ssid} ». Connectez-vous à ce Wi-Fi puis réessayez si la connexion échoue.`,
        [{ text: 'Continuer', onPress: () => connectTo(target) }],
      );
    } else {
      connectTo(target);
    }
  };

  const connectManual = async () => {
    const [host, port] = manualIp.trim().split(':');
    if (!host) return;
    setConnecting(true);
    const found = await CastFlowClient.probe(host, Number(port) || DEFAULT_PORTS.http);
    setConnecting(false);
    if (!found) return Alert.alert('Introuvable', `Aucun appareil CastFlow à ${manualIp}.`);
    connectTo(found);
  };

  /* --------- sélection de fichiers --------- */

  const pickDocuments = async () => {
    const res = await DocumentPicker.getDocumentAsync({ multiple: true, copyToCacheDirectory: false });
    if (res.canceled) return;
    setFiles((p) => [...p, ...res.assets.map((a) => ({
      id: uid('f'), name: a.name, size: a.size ?? 0,
      mime: a.mimeType || guessMime(a.name), uri: a.uri,
    }))]);
  };

  const pickMedia = async () => {
    const perm = await ImagePicker.requestMediaLibraryPermissionsAsync();
    if (!perm.granted) return Alert.alert('Permission refusée', 'Accès à la galerie nécessaire.');
    const res = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ImagePicker.MediaTypeOptions.All,
      allowsMultipleSelection: true,
      quality: 1,
    });
    if (res.canceled) return;
    const picked = await Promise.all(res.assets.map(async (a) => {
      const name = a.fileName || a.uri.split('/').pop();
      let size = a.fileSize;
      if (!size) {
        const info = await FileSystem.getInfoAsync(a.uri);
        size = info.size ?? 0;
      }
      return { id: uid('f'), name, size, mime: a.mimeType || guessMime(name), uri: a.uri };
    }));
    setFiles((p) => [...p, ...picked]);
  };

  /* --------- envoi --------- */

  const sendAll = async () => {
    const client = clientRef.current;
    if (!client || !files.length) return;
    setProgress({ totalSent: 0, totalSize: files.reduce((s, f) => s + f.size, 0), bps: 0, fileId: null });
    try {
      await client.sendFiles(files, { onProgress: setProgress });
      const entry = {
        id: uid('h'), at: Date.now(), peer: peer?.name,
        count: files.length, size: files.reduce((s, f) => s + f.size, 0),
        names: files.map((f) => f.name), state: 'completed',
      };
      await saveHistory(entry);
      Alert.alert('Envoi terminé', `${files.length} fichier(s) transféré(s) vers ${peer?.name}.`);
      setFiles([]);
    } catch (e) {
      if (e.code === 'REJECTED') Alert.alert('Refusé', e.message);
      else Alert.alert('Échec du transfert', e.message);
    } finally {
      setProgress(null);
    }
  };

  /* --------- réception : télécharger l'offre du PC --------- */

  const acceptOffer = async () => {
    const client = clientRef.current;
    if (!client || !offer) return;
    const files = offer.files;
    setDownloading({ totalReceived: 0, totalSize: offer.totalSize, bps: 0 });
    try {
      // On relit l'offre côté serveur pour récupérer les empreintes,
      // calculées en arrière-plan juste après la publication.
      let detailed = files;
      try {
        const fresh = await client.listOffer(offer.transferId);
        if (fresh?.files?.length) detailed = fresh.files;
      } catch { /* on garde la liste du message OFFER */ }

      const saved = await client.receiveFiles(offer.transferId, detailed, {
        onProgress: setDownloading,
      });

      await saveHistory({
        id: uid('h'), at: Date.now(), peer: peer?.name,
        count: detailed.length, size: offer.totalSize,
        names: detailed.map((f) => f.name), state: 'completed', direction: 'receive',
      });
      Alert.alert(
        'Réception terminée',
        `${saved.length} fichier(s) enregistré(s) dans le dossier CastFlow de l'application.`,
      );
      setOffer(null);
    } catch (e) {
      Alert.alert('Échec de la réception', e.message);
    } finally {
      setDownloading(null);
    }
  };

  const disconnect = () => {
    clientRef.current?.disconnect();
    clientRef.current = null;
    setOffer(null);
    setDownloading(null);
    setConnected(false);
    setPeer(null);
    setScreen('home');
  };

  /* --------- rendu --------- */

  if (!device) {
    return (
      <View style={[s.screen, s.center]}>
        <ActivityIndicator color={T.accent} size="large" />
      </View>
    );
  }

  if (screen === 'scan') {
    return <Scanner onScan={onScan} onCancel={() => setScreen('home')} />;
  }

  return (
    <SafeAreaView style={s.screen} edges={['top', 'bottom']}>
      <Header device={device} netInfo={netInfo} peer={connected ? peer : null} onDisconnect={disconnect} />

      <ScrollView contentContainerStyle={{ padding: 16, paddingBottom: 40 }}>
        {!connected ? (
          <ConnectView
            connecting={connecting}
            manualIp={manualIp}
            setManualIp={setManualIp}
            onScanPress={() => setScreen('scan')}
            onManualConnect={connectManual}
            netInfo={netInfo}
            history={history}
          />
        ) : (
          <SendView
            peer={peer}
            files={files}
            setFiles={setFiles}
            progress={progress}
            onPickDocs={pickDocuments}
            onPickMedia={pickMedia}
            onSend={sendAll}
            onCancel={() => { clientRef.current?.cancel(progress?.transferId); setProgress(null); }}
          />
        )}

        {connected && (offer || downloading) && (
          <IncomingOffer
            offer={offer}
            downloading={downloading}
            peerName={peer?.name}
            onAccept={acceptOffer}
            onReject={() => setOffer(null)}
          />
        )}

        {history.length > 0 && !progress && !downloading && <HistoryList history={history} />}
      </ScrollView>

      <PinModal
        visible={pinPrompt}
        value={pinValue}
        error={pinError}
        peerName={peer?.name}
        onChange={setPinValue}
        onSubmit={submitPin}
        onCancel={() => { setPinPrompt(false); setPinValue(''); setPinError(''); disconnect(); }}
      />
    </SafeAreaView>
  );
}

/* ================================================================== */
/* Upload natif avec progression (expo-file-system)                    */
/* ================================================================== */

/**
 * Téléchargement natif d'un fichier offert par le PC, avec progression,
 * enregistrement dans le stockage de l'app et vérification d'intégrité.
 */
async function downloadWithExpo({ url, file, token, targetDir, onProgress }) {
  const dir = targetDir || `${FileSystem.documentDirectory}CastFlow/`;
  await FileSystem.makeDirectoryAsync(dir, { intermediates: true }).catch(() => {});

  // Évite d'écraser un fichier déjà reçu : photo.jpg → photo (1).jpg
  let dest = `${dir}${file.name}`;
  const dot = file.name.lastIndexOf('.');
  const base = dot > 0 ? file.name.slice(0, dot) : file.name;
  const ext = dot > 0 ? file.name.slice(dot) : '';
  let n = 1;
  while ((await FileSystem.getInfoAsync(dest)).exists) {
    dest = `${dir}${base} (${n++})${ext}`;
  }

  const task = FileSystem.createDownloadResumable(
    url,
    dest,
    { headers: { 'X-CastFlow-Token': token } },
    (p) => onProgress?.(p.totalBytesWritten),
  );

  const result = await task.downloadAsync();
  if (!result || result.status >= 400) {
    throw new Error(`Téléchargement échoué (${result?.status ?? 'réseau'})`);
  }

  // Vérification d'intégrité si le PC a fourni une empreinte.
  if (file.hash) {
    const b64 = await FileSystem.readAsStringAsync(dest, {
      encoding: FileSystem.EncodingType.Base64,
    });
    if (!hashMatches(file.hash, hashBase64(b64))) {
      await FileSystem.deleteAsync(dest, { idempotent: true });
      throw new Error(`Intégrité invalide pour ${file.name}`);
    }
  }

  onProgress?.(file.size);
  return { uri: dest, name: file.name, size: file.size };
}

async function uploadWithExpo({ url, uri, token, offset, onProgress, size }) {
  const task = FileSystem.createUploadTask(
    url,
    uri,
    {
      httpMethod: 'POST',
      uploadType: FileSystem.FileSystemUploadType.BINARY_CONTENT,
      headers: { 'X-CastFlow-Token': token, 'X-Offset': String(offset) },
    },
    (p) => onProgress?.(p.totalBytesSent),
  );
  const res = await task.uploadAsync();
  if (res.status >= 400) {
    let msg = `Erreur ${res.status}`;
    try { msg = JSON.parse(res.body).message ?? msg; } catch { /* ignore */ }
    throw new Error(msg);
  }
  onProgress?.(size);
  return res;
}

/* ================================================================== */
/* Composants                                                          */
/* ================================================================== */

function Header({ device, netInfo, peer, onDisconnect }) {
  return (
    <View style={s.header}>
      <View style={{ flex: 1 }}>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 9 }}>
          <View style={s.logo}><Text style={{ fontSize: 17 }}>⚡</Text></View>
          <View>
            <Text style={s.logoText}>CastFlow</Text>
            <Text style={s.dimSmall}>
              {peer ? `Connecté à ${peer.name}` : (netInfo?.ip ? `${netInfo.ip}` : device.name)}
            </Text>
          </View>
        </View>
      </View>
      {peer && (
        <TouchableOpacity onPress={onDisconnect} style={s.disconnectBtn}>
          <Text style={{ color: T.red, fontWeight: '700', fontSize: 13 }}>Déconnecter</Text>
        </TouchableOpacity>
      )}
    </View>
  );
}

function ConnectView({ connecting, manualIp, setManualIp, onScanPress, onManualConnect, netInfo, history }) {
  return (
    <>
      <View style={s.hero}>
        <Text style={s.heroEmoji}>📡</Text>
        <Text style={s.heroTitle}>Connectez-vous à un ordinateur</Text>
        <Text style={s.heroText}>
          Ouvrez CastFlow sur le PC, allez dans « Recevoir », puis scannez le QR code affiché.
        </Text>
        <TouchableOpacity style={s.primaryBtn} onPress={onScanPress} disabled={connecting}>
          {connecting
            ? <ActivityIndicator color="#fff" />
            : <Text style={s.primaryBtnText}>📷  Scanner le QR code</Text>}
        </TouchableOpacity>
      </View>

      <Card title="Connexion manuelle">
        <Text style={s.cardHint}>
          Saisissez l'adresse affichée sur le PC (onglet Recevoir).
        </Text>
        <View style={{ flexDirection: 'row', gap: 9, marginTop: 11 }}>
          <TextInput
            style={s.input}
            value={manualIp}
            onChangeText={setManualIp}
            placeholder="192.168.43.1:53317"
            placeholderTextColor={T.dim}
            autoCapitalize="none"
            keyboardType="numbers-and-punctuation"
          />
          <TouchableOpacity style={s.smallBtn} onPress={onManualConnect} disabled={connecting}>
            <Text style={s.smallBtnText}>Aller</Text>
          </TouchableOpacity>
        </View>
      </Card>

      <Card title="Pas de Wi-Fi ?">
        <Text style={s.cardHint}>
          Activez le <Text style={{ color: T.text, fontWeight: '700' }}>point d'accès mobile</Text> de ce
          téléphone, connectez-y le PC, puis scannez le QR. Le transfert reste 100 % local — aucune
          donnée ne passe par internet.
        </Text>
        {netInfo && (
          <View style={{ marginTop: 12, gap: 5 }}>
            <Row label="Mon adresse IP" value={netInfo.ip ?? '—'} />
            <Row label="Réseau" value={netInfo.type ?? '—'} />
          </View>
        )}
      </Card>
    </>
  );
}

function SendView({ peer, files, setFiles, progress, onPickDocs, onPickMedia, onSend, onCancel }) {
  const total = files.reduce((s, f) => s + f.size, 0);

  if (progress) {
    const pct = progress.totalSize ? (progress.totalSent / progress.totalSize) * 100 : 0;
    return (
      <Card title="Transfert en cours">
        <Text style={{ color: T.text, fontSize: 15, fontWeight: '700', marginBottom: 12 }}>
          Envoi vers {peer?.name}
        </Text>
        <Bar value={pct} />
        <View style={{ flexDirection: 'row', justifyContent: 'space-between', marginTop: 9 }}>
          <Text style={s.dimSmall}>
            {formatBytes(progress.totalSent)} / {formatBytes(progress.totalSize)} · {Math.round(pct)} %
          </Text>
          <Text style={s.dimSmall}>
            {formatSpeed(progress.bps)} · {formatEta(progress.totalSize - progress.totalSent, progress.bps)}
          </Text>
        </View>
        <TouchableOpacity style={[s.ghostBtn, { marginTop: 16, borderColor: `${T.red}55` }]} onPress={onCancel}>
          <Text style={{ color: T.red, fontWeight: '700' }}>Annuler le transfert</Text>
        </TouchableOpacity>
      </Card>
    );
  }

  return (
    <>
      <View style={{ flexDirection: 'row', gap: 11, marginBottom: 16 }}>
        <TouchableOpacity style={s.tile} onPress={onPickMedia}>
          <Text style={{ fontSize: 26 }}>🖼</Text>
          <Text style={s.tileText}>Photos & vidéos</Text>
        </TouchableOpacity>
        <TouchableOpacity style={s.tile} onPress={onPickDocs}>
          <Text style={{ fontSize: 26 }}>📄</Text>
          <Text style={s.tileText}>Documents</Text>
        </TouchableOpacity>
      </View>

      {files.length === 0 ? (
        <Card>
          <Text style={[s.cardHint, { textAlign: 'center' }]}>
            Choisissez des fichiers à envoyer vers {peer?.name}.
          </Text>
        </Card>
      ) : (
        <>
          <Card title={`${files.length} fichier(s) · ${formatBytes(total)}`}>
            {files.map((f) => (
              <View key={f.id} style={s.fileRow}>
                <View style={[s.fileIcon, { backgroundColor: `${catColor[category(f.mime, f.name)]}22` }]}>
                  <Text style={{ fontSize: 17 }}>{catEmoji[category(f.mime, f.name)]}</Text>
                </View>
                <View style={{ flex: 1, minWidth: 0 }}>
                  <Text numberOfLines={1} style={s.fileName}>{f.name}</Text>
                  <Text style={s.dimSmall}>{formatBytes(f.size)}</Text>
                </View>
                <TouchableOpacity onPress={() => setFiles((p) => p.filter((x) => x.id !== f.id))} hitSlop={10}>
                  <Text style={{ color: T.dim, fontSize: 19 }}>✕</Text>
                </TouchableOpacity>
              </View>
            ))}
          </Card>

          <TouchableOpacity style={[s.primaryBtn, { marginTop: 14 }]} onPress={onSend}>
            <Text style={s.primaryBtnText}>Envoyer {formatBytes(total)} →</Text>
          </TouchableOpacity>
          <TouchableOpacity style={[s.ghostBtn, { marginTop: 9 }]} onPress={() => setFiles([])}>
            <Text style={{ color: T.dim, fontWeight: '600' }}>Tout retirer</Text>
          </TouchableOpacity>
        </>
      )}
    </>
  );
}

function IncomingOffer({ offer, downloading, peerName, onAccept, onReject }) {
  if (downloading) {
    const pct = downloading.totalSize
      ? (downloading.totalReceived / downloading.totalSize) * 100 : 0;
    return (
      <Card title="Réception en cours">
        <Text style={{ color: T.text, fontSize: 15, fontWeight: '700', marginBottom: 12 }}>
          Depuis {peerName}
        </Text>
        <Bar value={pct} />
        <View style={{ flexDirection: 'row', justifyContent: 'space-between', marginTop: 9 }}>
          <Text style={s.dimSmall}>
            {formatBytes(downloading.totalReceived)} / {formatBytes(downloading.totalSize)} · {Math.round(pct)} %
          </Text>
          <Text style={s.dimSmall}>
            {formatSpeed(downloading.bps)} · {formatEta(downloading.totalSize - downloading.totalReceived, downloading.bps)}
          </Text>
        </View>
      </Card>
    );
  }

  if (!offer) return null;

  return (
    <Card title="Fichiers proposés">
      <Text style={{ color: T.text, fontSize: 15, fontWeight: '700', marginBottom: 4 }}>
        {peerName} veut vous envoyer {offer.files.length} fichier(s)
      </Text>
      <Text style={[s.dimSmall, { marginBottom: 12 }]}>Total : {formatBytes(offer.totalSize)}</Text>

      {offer.files.slice(0, 6).map((f) => (
        <View key={f.id} style={s.fileRow}>
          <View style={[s.fileIcon, { backgroundColor: `${catColor[category(f.mime, f.name)]}22` }]}>
            <Text style={{ fontSize: 17 }}>{catEmoji[category(f.mime, f.name)]}</Text>
          </View>
          <View style={{ flex: 1, minWidth: 0 }}>
            <Text numberOfLines={1} style={s.fileName}>{f.name}</Text>
            <Text style={s.dimSmall}>{formatBytes(f.size)}</Text>
          </View>
        </View>
      ))}
      {offer.files.length > 6 && (
        <Text style={[s.dimSmall, { marginTop: 6 }]}>et {offer.files.length - 6} autre(s)…</Text>
      )}

      <View style={{ flexDirection: 'row', gap: 10, marginTop: 14 }}>
        <TouchableOpacity style={[s.ghostBtn, { flex: 1 }]} onPress={onReject}>
          <Text style={{ color: T.dim, fontWeight: '600' }}>Ignorer</Text>
        </TouchableOpacity>
        <TouchableOpacity style={[s.primaryBtn, { flex: 1 }]} onPress={onAccept}>
          <Text style={s.primaryBtnText}>Recevoir</Text>
        </TouchableOpacity>
      </View>
    </Card>
  );
}

function HistoryList({ history }) {
  return (
    <Card title="Historique" style={{ marginTop: 16 }}>
      {history.slice(0, 8).map((h) => (
        <View key={h.id} style={s.fileRow}>
          <View style={[s.fileIcon, { backgroundColor: `${T.green}22` }]}>
            <Text style={{ fontSize: 15 }}>✓</Text>
          </View>
          <View style={{ flex: 1 }}>
            <Text numberOfLines={1} style={s.fileName}>
              {h.count} fichier(s) · {formatBytes(h.size)}
            </Text>
            <Text style={s.dimSmall}>
              {h.peer} · {new Date(h.at).toLocaleString('fr-FR')}
            </Text>
          </View>
        </View>
      ))}
    </Card>
  );
}

function Scanner({ onScan, onCancel }) {
  const [permission, requestPermission] = useCameraPermissions();
  const locked = useRef(false);

  useEffect(() => { if (!permission?.granted) requestPermission(); }, [permission]);

  if (!permission) return <View style={[s.screen, s.center]}><ActivityIndicator color={T.accent} /></View>;

  if (!permission.granted) {
    return (
      <SafeAreaView style={[s.screen, s.center, { padding: 26 }]}>
        <Text style={s.heroEmoji}>📷</Text>
        <Text style={s.heroTitle}>Autorisation caméra</Text>
        <Text style={[s.heroText, { marginBottom: 20 }]}>
          CastFlow a besoin de la caméra pour scanner le QR code affiché sur l'ordinateur.
        </Text>
        <TouchableOpacity style={s.primaryBtn} onPress={requestPermission}>
          <Text style={s.primaryBtnText}>Autoriser</Text>
        </TouchableOpacity>
        <TouchableOpacity style={[s.ghostBtn, { marginTop: 10 }]} onPress={onCancel}>
          <Text style={{ color: T.dim, fontWeight: '600' }}>Retour</Text>
        </TouchableOpacity>
      </SafeAreaView>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: '#000' }}>
      <CameraView
        style={StyleSheet.absoluteFill}
        barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
        onBarcodeScanned={(r) => {
          if (locked.current) return;
          locked.current = true;
          onScan(r);
        }}
      />
      <SafeAreaView style={{ flex: 1, justifyContent: 'space-between', padding: 24 }}>
        <Text style={{ color: '#fff', fontSize: 16, fontWeight: '700', textAlign: 'center', marginTop: 12 }}>
          Visez le QR code affiché sur le PC
        </Text>
        <View style={s.viewfinder} />
        <TouchableOpacity style={[s.ghostBtn, { backgroundColor: '#0009' }]} onPress={onCancel}>
          <Text style={{ color: '#fff', fontWeight: '700' }}>Annuler</Text>
        </TouchableOpacity>
      </SafeAreaView>
    </View>
  );
}

function PinModal({ visible, value, error, peerName, onChange, onSubmit, onCancel }) {
  return (
    <Modal visible={visible} transparent animationType="fade">
      <View style={s.modalBg}>
        <View style={s.modalCard}>
          <Text style={{ fontSize: 18, fontWeight: '800', color: T.text, marginBottom: 6 }}>
            Code PIN requis
          </Text>
          <Text style={[s.cardHint, { marginBottom: 16 }]}>
            Saisissez le code à 6 chiffres affiché sur {peerName ?? 'l\'ordinateur'}.
          </Text>
          <TextInput
            style={[s.input, s.pinInput]}
            value={value}
            onChangeText={(t) => onChange(t.replace(/\D/g, '').slice(0, 6))}
            keyboardType="number-pad"
            maxLength={6}
            placeholder="000000"
            placeholderTextColor={T.border}
            autoFocus
          />
          {!!error && <Text style={{ color: T.red, fontSize: 12.5, marginTop: 9 }}>{error}</Text>}
          <View style={{ flexDirection: 'row', gap: 10, marginTop: 18 }}>
            <TouchableOpacity style={[s.ghostBtn, { flex: 1 }]} onPress={onCancel}>
              <Text style={{ color: T.dim, fontWeight: '600' }}>Annuler</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={[s.primaryBtn, { flex: 1, opacity: value.length === 6 ? 1 : 0.45 }]}
              onPress={onSubmit}
              disabled={value.length !== 6}
            >
              <Text style={s.primaryBtnText}>Valider</Text>
            </TouchableOpacity>
          </View>
        </View>
      </View>
    </Modal>
  );
}

function Card({ title, children, style }) {
  return (
    <View style={[s.card, style]}>
      {!!title && <Text style={s.cardTitle}>{title}</Text>}
      {children}
    </View>
  );
}

function Row({ label, value }) {
  return (
    <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
      <Text style={s.dimSmall}>{label}</Text>
      <Text style={{ color: T.text, fontSize: 12.5, fontVariant: ['tabular-nums'] }}>{value}</Text>
    </View>
  );
}

function Bar({ value }) {
  return (
    <View style={s.barTrack}>
      <View style={[s.barFill, { width: `${Math.max(0, Math.min(100, value))}%` }]} />
    </View>
  );
}

/* ================================================================== */

const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: T.bg },
  center: { alignItems: 'center', justifyContent: 'center' },

  header: {
    flexDirection: 'row', alignItems: 'center',
    paddingHorizontal: 16, paddingVertical: 13,
    borderBottomWidth: 1, borderBottomColor: T.border,
  },
  logo: {
    width: 34, height: 34, borderRadius: 10, backgroundColor: `${T.accent}22`,
    alignItems: 'center', justifyContent: 'center',
  },
  logoText: { color: T.text, fontSize: 16.5, fontWeight: '800', letterSpacing: -0.2 },
  dimSmall: { color: T.dim, fontSize: 11.5 },
  disconnectBtn: {
    paddingHorizontal: 12, paddingVertical: 7, borderRadius: 9,
    borderWidth: 1, borderColor: `${T.red}44`,
  },

  hero: { alignItems: 'center', paddingVertical: 26, paddingHorizontal: 6 },
  heroEmoji: { fontSize: 48, marginBottom: 14 },
  heroTitle: { color: T.text, fontSize: 20, fontWeight: '800', marginBottom: 8, textAlign: 'center' },
  heroText: { color: T.dim, fontSize: 13.5, textAlign: 'center', lineHeight: 20, marginBottom: 22, paddingHorizontal: 12 },

  card: {
    backgroundColor: T.panel, borderWidth: 1, borderColor: T.border,
    borderRadius: 16, padding: 16, marginBottom: 13,
  },
  cardTitle: {
    color: T.dim, fontSize: 11.5, fontWeight: '800',
    letterSpacing: 1, textTransform: 'uppercase', marginBottom: 11,
  },
  cardHint: { color: T.dim, fontSize: 13, lineHeight: 20 },

  primaryBtn: {
    backgroundColor: T.accent, paddingVertical: 14, paddingHorizontal: 22,
    borderRadius: 12, alignItems: 'center', justifyContent: 'center',
  },
  primaryBtnText: { color: '#fff', fontWeight: '700', fontSize: 15 },
  ghostBtn: {
    borderWidth: 1, borderColor: T.border, paddingVertical: 13,
    borderRadius: 12, alignItems: 'center',
  },
  smallBtn: {
    backgroundColor: T.accent, paddingHorizontal: 18, borderRadius: 10,
    alignItems: 'center', justifyContent: 'center',
  },
  smallBtnText: { color: '#fff', fontWeight: '700', fontSize: 14 },

  input: {
    flex: 1, backgroundColor: '#0a1526', borderWidth: 1, borderColor: T.border,
    borderRadius: 10, paddingHorizontal: 13, paddingVertical: 11,
    color: T.text, fontSize: 14.5,
  },
  pinInput: {
    textAlign: 'center', fontSize: 30, fontWeight: '800',
    letterSpacing: 9, paddingVertical: 14, color: T.accent2,
  },

  tile: {
    flex: 1, backgroundColor: T.panel, borderWidth: 1, borderColor: T.border,
    borderRadius: 16, paddingVertical: 22, alignItems: 'center', gap: 8,
  },
  tileText: { color: T.text, fontSize: 13, fontWeight: '600' },

  fileRow: { flexDirection: 'row', alignItems: 'center', gap: 11, paddingVertical: 7 },
  fileIcon: { width: 36, height: 36, borderRadius: 10, alignItems: 'center', justifyContent: 'center' },
  fileName: { color: T.text, fontSize: 13.5, fontWeight: '600' },

  barTrack: { height: 8, backgroundColor: '#0a1526', borderRadius: 8, overflow: 'hidden' },
  barFill: { height: '100%', backgroundColor: T.accent, borderRadius: 8 },

  viewfinder: {
    alignSelf: 'center', width: 235, height: 235,
    borderWidth: 3, borderColor: T.accent2, borderRadius: 24,
  },

  modalBg: { flex: 1, backgroundColor: '#020617dd', justifyContent: 'center', padding: 26 },
  modalCard: {
    backgroundColor: T.panel, borderWidth: 1, borderColor: T.border,
    borderRadius: 18, padding: 22,
  },
});
