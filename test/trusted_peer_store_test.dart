import 'package:castflow/remote/control_protocol.dart';
import 'package:castflow/remote/trust_protocol.dart';
import 'package:castflow/remote/trusted_peer_store.dart';
import 'package:flutter_test/flutter_test.dart';

class MemorySecretStore implements SecretStore {
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
  final approvedAt = DateTime.utc(2026, 9, 22, 12);

  TrustedPeer peer(
    String id, {
    DateTime? lastSeenAt,
    Set<ControlCapability>? capabilities,
  }) => TrustedPeer(
    deviceId: id,
    name: 'Appareil $id',
    fingerprint: 'sha256:$id',
    approvedAt: approvedAt,
    lastSeenAt: lastSeenAt ?? approvedAt,
    capabilities:
        capabilities ??
        {ControlCapability.screenCapture, ControlCapability.pointer},
  );

  group('TrustedPeerStore', () {
    test('enregistre puis relit un secret dans le coffre injecté', () async {
      final memory = MemorySecretStore();
      final store = TrustedPeerStore(memory);
      final secret = generateTrustSecret();

      await store.approve(peer: peer('dev_windows_1'), secret: secret);
      final credential = await store.credential('dev_windows_1');

      expect(credential?.peer.deviceId, 'dev_windows_1');
      expect(credential?.secret, secret);
      expect(memory.values.keys, contains('castflow.trust.peer.dev_windows_1'));
    });

    test('classe les appareils par dernière activité', () async {
      final store = TrustedPeerStore(MemorySecretStore());
      await store.approve(
        peer: peer('dev_old', lastSeenAt: approvedAt),
        secret: generateTrustSecret(),
      );
      await store.approve(
        peer: peer(
          'dev_recent',
          lastSeenAt: approvedAt.add(const Duration(minutes: 2)),
        ),
        secret: generateTrustSecret(),
      );

      expect((await store.list()).map((value) => value.deviceId), [
        'dev_recent',
        'dev_old',
      ]);
    });

    test('met à jour la dernière activité sans changer le secret', () async {
      final store = TrustedPeerStore(MemorySecretStore());
      final secret = generateTrustSecret();
      final nextSeen = approvedAt.add(const Duration(hours: 1));
      await store.approve(peer: peer('dev_android_1'), secret: secret);

      await store.updateLastSeen('dev_android_1', nextSeen);
      final credential = await store.credential('dev_android_1');

      expect(credential?.peer.lastSeenAt, nextSeen);
      expect(credential?.secret, secret);
    });

    test('révoque un seul appareil', () async {
      final store = TrustedPeerStore(MemorySecretStore());
      await store.approve(
        peer: peer('dev_windows_1'),
        secret: generateTrustSecret(),
      );
      await store.approve(
        peer: peer('dev_android_1'),
        secret: generateTrustSecret(),
      );

      await store.revoke('dev_windows_1');

      expect(await store.credential('dev_windows_1'), isNull);
      expect((await store.list()).single.deviceId, 'dev_android_1');
    });

    test('révoque tous les appareils et secrets', () async {
      final memory = MemorySecretStore();
      final store = TrustedPeerStore(memory);
      await store.approve(
        peer: peer('dev_windows_1'),
        secret: generateTrustSecret(),
      );
      await store.approve(
        peer: peer('dev_android_1'),
        secret: generateTrustSecret(),
      );

      await store.revokeAll();

      expect(await store.list(), isEmpty);
      expect(memory.values, isEmpty);
    });

    test('refuse un secret trop court', () async {
      final store = TrustedPeerStore(MemorySecretStore());

      expect(
        () => store.approve(peer: peer('dev_windows_1'), secret: 'court'),
        throwsFormatException,
      );
    });

    test('refuse un enregistrement corrompu', () async {
      final memory = MemorySecretStore();
      final store = TrustedPeerStore(memory);
      memory.values['castflow.trust.peer.dev_windows_1'] = '{invalide';

      expect(
        () => store.credential('dev_windows_1'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
