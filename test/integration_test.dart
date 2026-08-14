import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:castflow/core/models.dart';
import 'package:castflow/network/castflow_client.dart';
import 'package:castflow/network/castflow_server.dart';
import 'package:castflow/security/security.dart';
import 'package:flutter_test/flutter_test.dart';

const desktop = DeviceInfo(
  id: 'desktop-test',
  name: 'PC Test',
  platform: 'windows',
  kind: 'desktop',
  fingerprint: 'desktop-fp',
);

const mobile = DeviceInfo(
  id: 'mobile-test',
  name: 'Pixel Test',
  platform: 'android',
  kind: 'mobile',
  fingerprint: 'mobile-fp',
);

RemoteDevice remoteFor(CastFlowServer server, {bool requiresPin = false}) =>
    RemoteDevice(
      id: desktop.id,
      name: desktop.name,
      platform: desktop.platform,
      kind: desktop.kind,
      fingerprint: desktop.fingerprint,
      host: '127.0.0.1',
      httpPort: server.httpPort!,
      wsPort: server.wsPort!,
      requiresPin: requiresPin,
    );

Future<(CastFlowServer, Directory)> startServer({
  String? pin,
  bool autoAccept = true,
}) async {
  final directory = await Directory.systemTemp.createTemp('castflow-server-');
  final server = CastFlowServer(
    device: desktop,
    downloadDirectory: directory.path,
    pin: pin,
    autoAccept: autoAccept,
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
