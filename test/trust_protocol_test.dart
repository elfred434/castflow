import 'package:castflow/remote/trust_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const requester = 'dev_android_1';
  const target = 'dev_windows_1';
  final start = DateTime.utc(2026, 9, 22, 12);

  group('preuve de confiance', () {
    test('accepte le secret correspondant avant expiration', () {
      final registry = TrustChallengeRegistry();
      final secret = generateTrustSecret();
      final challenge = registry.issue(
        requesterDeviceId: requester,
        targetDeviceId: target,
        now: start,
      );
      final proof = createTrustProof(secret, challenge);

      expect(
        registry.consume(
          challengeId: challenge.id,
          requesterDeviceId: requester,
          targetDeviceId: target,
          secret: secret,
          proof: proof,
          now: start.add(const Duration(seconds: 10)),
        ),
        isTrue,
      );
      expect(registry.pendingCount, 0);
    });

    test('refuse un mauvais secret et consomme le challenge', () {
      final registry = TrustChallengeRegistry();
      final challenge = registry.issue(
        requesterDeviceId: requester,
        targetDeviceId: target,
        now: start,
      );
      final proof = createTrustProof(generateTrustSecret(), challenge);

      expect(
        registry.consume(
          challengeId: challenge.id,
          requesterDeviceId: requester,
          targetDeviceId: target,
          secret: generateTrustSecret(),
          proof: proof,
          now: start,
        ),
        isFalse,
      );
      expect(registry.pendingCount, 0);
    });

    test('refuse un challenge expiré', () {
      final registry = TrustChallengeRegistry();
      final secret = generateTrustSecret();
      final challenge = registry.issue(
        requesterDeviceId: requester,
        targetDeviceId: target,
        now: start,
      );

      expect(
        registry.consume(
          challengeId: challenge.id,
          requesterDeviceId: requester,
          targetDeviceId: target,
          secret: secret,
          proof: createTrustProof(secret, challenge),
          now: start.add(trustChallengeTtl),
        ),
        isFalse,
      );
    });

    test('refuse la réutilisation d’une preuve valide', () {
      final registry = TrustChallengeRegistry();
      final secret = generateTrustSecret();
      final challenge = registry.issue(
        requesterDeviceId: requester,
        targetDeviceId: target,
        now: start,
      );
      final proof = createTrustProof(secret, challenge);

      bool consume() => registry.consume(
        challengeId: challenge.id,
        requesterDeviceId: requester,
        targetDeviceId: target,
        secret: secret,
        proof: proof,
        now: start,
      );

      expect(consume(), isTrue);
      expect(consume(), isFalse);
    });

    test('lie la preuve aux deux identités', () {
      final registry = TrustChallengeRegistry();
      final secret = generateTrustSecret();
      final challenge = registry.issue(
        requesterDeviceId: requester,
        targetDeviceId: target,
        now: start,
      );

      expect(
        registry.consume(
          challengeId: challenge.id,
          requesterDeviceId: 'dev_android_2',
          targetDeviceId: target,
          secret: secret,
          proof: createTrustProof(secret, challenge),
          now: start,
        ),
        isFalse,
      );
    });
  });

  group('validation du challenge', () {
    test('rejette les identifiants invalides', () {
      expect(
        () => TrustChallengeRegistry().issue(
          requesterDeviceId: '../android',
          targetDeviceId: target,
          now: start,
        ),
        throwsFormatException,
      );
    });

    test('sérialise puis relit un challenge', () {
      final challenge = TrustChallengeRegistry().issue(
        requesterDeviceId: requester,
        targetDeviceId: target,
        now: start,
      );
      final decoded = TrustChallenge.fromJson(challenge.toJson());

      expect(decoded.id, challenge.id);
      expect(decoded.nonce, challenge.nonce);
      expect(decoded.requesterDeviceId, requester);
      expect(decoded.targetDeviceId, target);
      expect(decoded.expiresAt, challenge.expiresAt);
    });
  });
}
