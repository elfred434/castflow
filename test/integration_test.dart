import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:castflow/core/models.dart';
import 'package:castflow/network/castflow_client.dart';
import 'package:castflow/network/castflow_server.dart';
import 'package:castflow/remote/control_protocol.dart';
import 'package:castflow/remote/transport_identity.dart';
import 'package:castflow/remote/trusted_peer_store.dart';
import 'package:castflow/security/security.dart';
import 'package:flutter_test/flutter_test.dart';

const desktop = DeviceInfo(
  id: 'desktop-test',
  name: 'PC Test',
  platform: 'windows',
  kind: 'desktop',
  fingerprint: 'desktop-fp',
);

class IntegrationSecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

const mobile = DeviceInfo(
  id: 'mobile-test',
  name: 'Pixel Test',
  platform: 'android',
  kind: 'mobile',
  fingerprint: 'mobile-fp',
);

RemoteDevice remoteFor(CastFlowServer server, {bool requiresPin = false}) =>
    RemoteDevice(
      id: server.device.id,
      name: server.device.name,
      platform: server.device.platform,
      kind: server.device.kind,
      fingerprint: server.device.fingerprint,
      host: '127.0.0.1',
      httpPort: server.httpPort!,
      wsPort: server.wsPort!,
      requiresPin: requiresPin,
      secure: server.secureTransport,
    );

Future<(CastFlowServer, Directory)> startServer({
  String? pin,
  bool autoAccept = true,
  ControlCapabilities controlCapabilities = const ControlCapabilities(
    values: {},
  ),
  DeviceInfo device = desktop,
  TransportIdentity? transportIdentity,
  TrustedPeerStore? trustedPeers,
}) async {
  final directory = await Directory.systemTemp.createTemp('castflow-server-');
  final server = CastFlowServer(
    device: device,
    downloadDirectory: directory.path,
    pin: pin,
    autoAccept: autoAccept,
    controlCapabilities: controlCapabilities,
    transportIdentity: transportIdentity,
    trustedPeers: trustedPeers,
  );
  await server.start(preferredHttpPort: 0, preferredWsPort: 0);
  return (server, directory);
}

void main() {
  test('GET /info et probe exposent les ports réels', () async {
    final (server, directory) = await startServer();
    addTearDown(() async {
      await server.dispose();
      await directory.delete(recursive: true);
    });

    final found = await CastFlowClient.probe(
      '127.0.0.1',
      port: server.httpPort!,
    );
    expect(found, isNotNull);
    expect(found!.name, desktop.name);
    expect(found.httpPort, server.httpPort);
    expect(found.wsPort, server.wsPort);
  });

  test('handshake sans PIN crée une session HTTP', () async {
    final (server, directory) = await startServer();
    final client = CastFlowClient(mobile);
    addTearDown(() async {
      await client.dispose();
      await server.dispose();
      await directory.delete(recursive: true);
    });

    expect(await client.connect(remoteFor(server)), isTrue);
    expect(client.authenticated, isTrue);
    expect(client.sessionToken, startsWith('session_'));
  });

  test('handshake WebSocket TLS avec empreinte épinglée', () async {
    final tls = await TransportIdentityStore(IntegrationSecretStore())
        .loadOrCreate(desktop.id);
    final secureDesktop = DeviceInfo(
      id: desktop.id,
      name: desktop.name,
      platform: desktop.platform,
      kind: desktop.kind,
      fingerprint: tls.fingerprint,
    );
    final (server, directory) = await startServer(
      device: secureDesktop,
      transportIdentity: tls,
    );
    final client = CastFlowClient(mobile);
    addTearDown(() async {
      await client.dispose();
      await server.dispose();
      await directory.delete(recursive: true);
    });

    final found = await CastFlowClient.probe(
      '127.0.0.1',
      port: server.httpPort!,
    );
    expect(found?.secure, isTrue);
    expect(found?.fingerprint, tls.fingerprint);
    expect(await client.connect(remoteFor(server)), isTrue);
    expect(client.authenticated, isTrue);
  });

  test('refuse un serveur TLS dont l’empreinte est différente', () async {
    final tls = await TransportIdentityStore(IntegrationSecretStore())
        .loadOrCreate(desktop.id);
    final secureDesktop = DeviceInfo(
      id: desktop.id,
      name: desktop.name,
      platform: desktop.platform,
      kind: desktop.kind,
      fingerprint: tls.fingerprint,
    );
    final (server, directory) = await startServer(
      device: secureDesktop,
      transportIdentity: tls,
    );
    final client = CastFlowClient(mobile);
    addTearDown(() async {
      await client.dispose();
      await server.dispose();
      await directory.delete(recursive: true);
    });
    final target = remoteFor(server);
    final forged = RemoteDevice(
      id: target.id,
      name: target.name,
      platform: target.platform,
      kind: target.kind,
      fingerprint: List.filled(64, '0').join(),
      host: target.host,
      httpPort: target.httpPort,
      wsPort: target.wsPort,
      requiresPin: target.requiresPin,
      secure: true,
    );

    await expectLater(client.connect(forged), throwsA(isA<Exception>()));
    expect(client.authenticated, isFalse);
  });

  test(
    'appaire explicitement puis reconnecte par preuve de confiance',
    () async {
      const capabilities = ControlCapabilities(
        values: {ControlCapability.screenCapture, ControlCapability.pointer},
      );
      final tls = await TransportIdentityStore(IntegrationSecretStore())
          .loadOrCreate(desktop.id);
      final secureDesktop = DeviceInfo(
        id: desktop.id,
        name: desktop.name,
        platform: desktop.platform,
        kind: desktop.kind,
        fingerprint: tls.fingerprint,
      );
      final serverTrust = TrustedPeerStore(IntegrationSecretStore());
      final clientTrust = TrustedPeerStore(IntegrationSecretStore());
      final (server, directory) = await startServer(
        pin: '482913',
        device: secureDesktop,
        transportIdentity: tls,
        trustedPeers: serverTrust,
        controlCapabilities: capabilities,
      );
      final firstClient = CastFlowClient(
        mobile,
        controlCapabilities: capabilities,
        trustedPeers: clientTrust,
      );
      CastFlowClient? reconnectingClient;
      addTearDown(() async {
        await reconnectingClient?.dispose();
        await firstClient.dispose();
        await server.dispose();
        await directory.delete(recursive: true);
      });

      final target = remoteFor(server);
      expect(await firstClient.connect(target, pin: '482913'), isTrue);
      final incomingRequest = server.trustRequests.first;
      final approval = firstClient.requestTrust();
      final request = await incomingRequest;
      expect(request.device.id, mobile.id);
      await server.approveTrust(
        request.id,
        capabilities: request.requestedCapabilities,
      );
      final trusted = await approval;
      expect(trusted.deviceId, desktop.id);
      expect(await serverTrust.credential(mobile.id), isNotNull);
      expect(await clientTrust.credential(desktop.id), isNotNull);

      await firstClient.disconnect();
      reconnectingClient = CastFlowClient(
        mobile,
        controlCapabilities: capabilities,
        trustedPeers: clientTrust,
      );
      final tamperedDiscovery = RemoteDevice(
        id: target.id,
        name: target.name,
        platform: target.platform,
        kind: target.kind,
        fingerprint: List.filled(64, '0').join(),
        host: target.host,
        httpPort: target.httpPort,
        wsPort: target.wsPort,
        requiresPin: true,
        secure: true,
      );
      expect(await reconnectingClient.connect(tamperedDiscovery), isTrue);
      expect(reconnectingClient.authenticated, isTrue);
      await reconnectingClient.disconnect();

      final downgraded = RemoteDevice(
        id: target.id,
        name: target.name,
        platform: target.platform,
        kind: target.kind,
        fingerprint: target.fingerprint,
        host: target.host,
        httpPort: target.httpPort,
        wsPort: target.wsPort,
        requiresPin: true,
        secure: false,
      );
      await expectLater(
        reconnectingClient.connect(downgraded),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('négocie les capacités de contrôle dans les deux sens', () async {
    const serverCapabilities = ControlCapabilities(
      values: {
        ControlCapability.screenCapture,
        ControlCapability.pointer,
        ControlCapability.keyboard,
      },
      maxWidth: 1920,
      maxHeight: 1080,
      maxFps: 30,
    );
    const clientCapabilities = ControlCapabilities(
      values: {
        ControlCapability.screenCapture,
        ControlCapability.pointer,
        ControlCapability.systemNavigation,
      },
      maxWidth: 1280,
      maxHeight: 720,
      maxFps: 15,
    );
    final (server, directory) = await startServer(
      controlCapabilities: serverCapabilities,
    );
    final client = CastFlowClient(
      mobile,
      controlCapabilities: clientCapabilities,
    );
    addTearDown(() async {
      await client.dispose();
      await server.dispose();
      await directory.delete(recursive: true);
    });

    expect(await client.connect(remoteFor(server)), isTrue);
    expect(client.remoteControlCapabilities.values, serverCapabilities.values);
    expect(client.remoteControlCapabilities.maxFps, 30);
    expect(
      server.controlCapabilitiesFor(mobile.id)?.values,
      clientCapabilities.values,
    );

    final refreshed = await client.refreshControlCapabilities();
    expect(refreshed.maxWidth, 1920);
    expect(refreshed.supports(ControlCapability.keyboard), isTrue);
  });

  test('mauvais PIN refusé puis bon PIN accepté', () async {
    final (server, directory) = await startServer(pin: '482913');
    final client = CastFlowClient(mobile);
    addTearDown(() async {
      await client.dispose();
      await server.dispose();
      await directory.delete(recursive: true);
    });

    expect(await client.connect(remoteFor(server, requiresPin: true)), isFalse);
    expect(await client.authenticate('000000'), isFalse);
    expect(await client.authenticate('482913'), isTrue);
    expect(client.authenticated, isTrue);
  });

  test('mobile vers desktop avec hash et progression', () async {
    final (server, directory) = await startServer();
    final client = CastFlowClient(mobile);
    final sourceDirectory = await Directory.systemTemp.createTemp(
      'castflow-source-',
    );
    addTearDown(() async {
      await client.dispose();
      await server.dispose();
      await directory.delete(recursive: true);
      await sourceDirectory.delete(recursive: true);
    });
    await client.connect(remoteFor(server));

    final bytes = Uint8List.fromList(
      List.generate(300000, (index) => index % 251),
    );
    final source = File('${sourceDirectory.path}/photo.bin');
    await source.writeAsBytes(bytes);
    var lastProgress = 0;
    await client.sendFiles([
      LocalFile(
        id: secureId('f'),
        name: 'photo.bin',
        path: source.path,
        size: bytes.length,
        mime: 'application/octet-stream',
      ),
    ], onProgress: (sent, _) => lastProgress = sent);

    final output = File('${directory.path}/photo.bin');
    expect(await output.exists(), isTrue);
    expect(await output.readAsBytes(), bytes);
    expect(lastProgress, bytes.length);
    expect(server.transferHistory.first.state, TransferState.completed);
  });

  test('manifest en attente peut être accepté par le desktop', () async {
    final (server, directory) = await startServer(autoAccept: false);
    final client = CastFlowClient(mobile);
    final sourceDirectory = await Directory.systemTemp.createTemp(
      'castflow-manual-',
    );
    addTearDown(() async {
      await client.dispose();
      await server.dispose();
      await directory.delete(recursive: true);
      await sourceDirectory.delete(recursive: true);
    });
    await client.connect(remoteFor(server));
    final source = File('${sourceDirectory.path}/note.txt')
      ..writeAsStringSync('bonjour');

    final incoming = server.incomingTransfers.first;
    final sending = client.sendFiles([
      LocalFile(
        id: 'f_note',
        name: 'note.txt',
        path: source.path,
        size: await source.length(),
        mime: 'text/plain',
      ),
    ]);
    final request = await incoming;
    expect(request.state, TransferState.pending);
    server.acceptTransfer(request.id);
    await sending;
    expect(await File('${directory.path}/note.txt').readAsString(), 'bonjour');
  });

  test('desktop vers mobile avec offre authentifiée', () async {
    final (server, directory) = await startServer();
    final client = CastFlowClient(mobile);
    final destination = await Directory.systemTemp.createTemp(
      'castflow-destination-',
    );
    addTearDown(() async {
      await client.dispose();
      await server.dispose();
      await directory.delete(recursive: true);
      await destination.delete(recursive: true);
    });
    await client.connect(remoteFor(server));

    final bytes = Uint8List.fromList(
      List.generate(180000, (index) => (index * 7) % 256),
    );
    final source = File('${directory.path}/film.bin');
    await source.writeAsBytes(bytes);
    final offerEvent = client.offers.first;
    final transferId = await server.offerFiles([
      LocalFile(
        id: 'offre_1',
        name: 'film.bin',
        path: source.path,
        size: bytes.length,
        mime: 'application/octet-stream',
      ),
    ]);
    final summary = await offerEvent;
    expect(summary.transferId, transferId);
    expect(summary.files.single.token, isEmpty);

    final saved = await client.receiveOffer(summary, destination.path);
    expect(saved, hasLength(1));
    expect(await File(saved.single).readAsBytes(), bytes);
    expect(server.transferHistory.first.state, TransferState.completed);
  });

  test('GET /offer sans session est refusé', () async {
    final (server, directory) = await startServer();
    final client = CastFlowClient(mobile);
    addTearDown(() async {
      await client.dispose();
      await server.dispose();
      await directory.delete(recursive: true);
    });
    await client.connect(remoteFor(server));
    final source = File('${directory.path}/private.txt')
      ..writeAsStringSync('secret');
    final transferId = await server.offerFiles([
      LocalFile(
        id: 'private_1',
        name: 'private.txt',
        path: source.path,
        size: await source.length(),
        mime: 'text/plain',
      ),
    ]);

    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final response = await (await http.getUrl(
      Uri.parse('http://127.0.0.1:${server.httpPort}/offer/$transferId'),
    )).close();
    expect(response.statusCode, 401);
    final body = jsonDecode(await utf8.decodeStream(response)) as Map;
    expect(body['code'], 'AUTH_REQUIRED');
  });

  test('plage HTTP hors fichier retourne 416', () async {
    final (server, directory) = await startServer();
    final client = CastFlowClient(mobile);
    addTearDown(() async {
      await client.dispose();
      await server.dispose();
      await directory.delete(recursive: true);
    });
    await client.connect(remoteFor(server));
    final source = File('${directory.path}/range.bin')
      ..writeAsBytesSync(List.filled(100, 7));
    final transferId = await server.offerFiles([
      LocalFile(
        id: 'range_1',
        name: 'range.bin',
        path: source.path,
        size: 100,
        mime: 'application/octet-stream',
      ),
    ]);
    final offer = await client.loadOffer(transferId);

    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final request = await http.getUrl(
      Uri.parse(
        'http://127.0.0.1:${server.httpPort}/download/$transferId/range_1',
      ),
    );
    request.headers
      ..set('X-CastFlow-Token', offer.files.single.token)
      ..set('X-CastFlow-Session', client.sessionToken)
      ..set(HttpHeaders.rangeHeader, 'bytes=999-1000');
    final response = await request.close();
    expect(response.statusCode, 416);
  });
}
