import 'dart:convert';
import 'dart:io';

import 'package:castflow/remote/transport_identity.dart';
import 'package:castflow/remote/trusted_peer_store.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryTransportSecretStore implements SecretStore {
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

void main() {
  late MemoryTransportSecretStore memory;
  late TransportIdentityStore store;
  late TransportIdentity identity;

  setUpAll(() async {
    memory = MemoryTransportSecretStore();
    store = TransportIdentityStore(memory);
    identity = await store.loadOrCreate('dev_windows_1');
  });

  test('génère une identité TLS persistante et cohérente', () async {
    expect(identity.deviceId, 'dev_windows_1');
    expect(identity.certificatePem, contains('BEGIN CERTIFICATE'));
    expect(identity.privateKeyPem, contains('BEGIN PRIVATE KEY'));
    expect(identity.fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(
      certificateFingerprintFromPem(identity.certificatePem),
      identity.fingerprint,
    );
    expect(memory.values, hasLength(4));

    final loaded = await store.loadOrCreate('dev_windows_1');
    expect(loaded.certificatePem, identity.certificatePem);
    expect(loaded.privateKeyPem, identity.privateKeyPem);
    expect(loaded.fingerprint, identity.fingerprint);
  });

  test('refuse une identité TLS associée à un autre appareil', () async {
    expect(
      () => store.loadOrCreate('dev_windows_2'),
      throwsA(isA<StateError>()),
    );
  });

  test('refuse une empreinte stockée incohérente', () async {
    final altered = MemoryTransportSecretStore()
      ..values.addAll(memory.values)
      ..values['castflow.transport.fingerprint'] = List.filled(64, '0').join();

    expect(
      () => TransportIdentityStore(altered).loadOrCreate('dev_windows_1'),
      throwsFormatException,
    );
  });

  test('établit une connexion TLS seulement avec empreinte épinglée', () async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      identity.createServerContext(),
    );
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..write('castflow-secure');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (certificate, _, _) =>
          certificateMatchesFingerprint(certificate, identity.fingerprint);
    addTearDown(() => client.close(force: true));

    final response = await (await client.getUrl(
      Uri.parse('https://127.0.0.1:${server.port}/'),
    )).close();
    expect(response.statusCode, HttpStatus.ok);
    expect(await utf8.decodeStream(response), 'castflow-secure');
  });
}
