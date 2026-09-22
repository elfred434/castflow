import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../security/security.dart';

const _trustDomain = 'castflow-trust-v1';
const trustChallengeTtl = Duration(seconds: 30);
const _minimumSecretBytes = 32;

final Random _trustRandom = Random.secure();

/// Secret d'appairage de 256 bits. Il doit être placé dans un coffre natif et
/// ne doit jamais être écrit dans SharedPreferences ou dans les journaux.
String generateTrustSecret() => _randomBase64Url(_minimumSecretBytes);

class TrustChallenge {
  const TrustChallenge({
    required this.id,
    required this.nonce,
    required this.requesterDeviceId,
    required this.targetDeviceId,
    required this.expiresAt,
  });

  final String id;
  final String nonce;
  final String requesterDeviceId;
  final String targetDeviceId;
  final DateTime expiresAt;

  bool isExpired(DateTime now) => !now.toUtc().isBefore(expiresAt.toUtc());

  Map<String, Object?> toJson() => {
    'id': id,
    'nonce': nonce,
    'requesterDeviceId': requesterDeviceId,
    'targetDeviceId': targetDeviceId,
    'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch,
  };

  factory TrustChallenge.fromJson(Map<String, Object?> json) {
    final id = json['id']?.toString() ?? '';
    final nonce = json['nonce']?.toString() ?? '';
    final requester = json['requesterDeviceId']?.toString() ?? '';
    final target = json['targetDeviceId']?.toString() ?? '';
    final expires = (json['expiresAt'] as num?)?.toInt() ?? 0;

    _validateIdentifier(id, 'challenge');
    _validateIdentifier(requester, 'appareil demandeur');
    _validateIdentifier(target, 'appareil cible');
    _decodeBase64Url(nonce, minimumBytes: 24, label: 'nonce');
    if (requester == target) {
      throw const FormatException(
        'Les appareils demandeur et cible doivent être différents',
      );
    }
    if (expires <= 0) {
      throw const FormatException("Expiration du challenge invalide");
    }

    return TrustChallenge(
      id: id,
      nonce: nonce,
      requesterDeviceId: requester,
      targetDeviceId: target,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true),
    );
  }

  String canonicalMessage() => [
    _trustDomain,
    id,
    nonce,
    requesterDeviceId,
    targetDeviceId,
    expiresAt.toUtc().millisecondsSinceEpoch.toString(),
  ].join('\n');
}

String createTrustProof(String secret, TrustChallenge challenge) {
  final secretBytes = _decodeBase64Url(
    secret,
    minimumBytes: _minimumSecretBytes,
    label: 'secret de confiance',
  );
  final digest = Hmac(
    sha256,
    secretBytes,
  ).convert(utf8.encode(challenge.canonicalMessage()));
  return base64UrlEncode(digest.bytes).replaceAll('=', '');
}

bool verifyTrustProof({
  required String secret,
  required TrustChallenge challenge,
  required String proof,
  DateTime? now,
}) {
  final clock = (now ?? DateTime.now()).toUtc();
  if (challenge.isExpired(clock)) return false;
  try {
    _decodeBase64Url(proof, minimumBytes: 32, label: 'preuve');
    final expected = createTrustProof(secret, challenge);
    return constantTimeEquals(expected, proof);
  } on FormatException {
    return false;
  }
}

/// Registre mémoire des challenges émis par l'hôte.
///
/// Un challenge est supprimé dès la première tentative de consommation,
/// réussie ou non. Cette règle empêche sa réutilisation et limite les essais
/// en ligne. Le registre ne persiste aucun secret d'appairage.
class TrustChallengeRegistry {
  final Map<String, TrustChallenge> _pending = {};

  int get pendingCount => _pending.length;

  TrustChallenge issue({
    required String requesterDeviceId,
    required String targetDeviceId,
    DateTime? now,
  }) {
    _validateIdentifier(requesterDeviceId, 'appareil demandeur');
    _validateIdentifier(targetDeviceId, 'appareil cible');
    if (requesterDeviceId == targetDeviceId) {
      throw const FormatException(
        'Les appareils demandeur et cible doivent être différents',
      );
    }
    final clock = (now ?? DateTime.now()).toUtc();
    purgeExpired(clock);
    final challenge = TrustChallenge(
      id: secureId('trust'),
      nonce: _randomBase64Url(32),
      requesterDeviceId: requesterDeviceId,
      targetDeviceId: targetDeviceId,
      expiresAt: clock.add(trustChallengeTtl),
    );
    _pending[challenge.id] = challenge;
    return challenge;
  }

  bool consume({
    required String challengeId,
    required String requesterDeviceId,
    required String targetDeviceId,
    required String secret,
    required String proof,
    DateTime? now,
  }) {
    final challenge = _pending.remove(challengeId);
    if (challenge == null) return false;
    if (challenge.requesterDeviceId != requesterDeviceId ||
        challenge.targetDeviceId != targetDeviceId) {
      return false;
    }
    return verifyTrustProof(
      secret: secret,
      challenge: challenge,
      proof: proof,
      now: now,
    );
  }

  void purgeExpired([DateTime? now]) {
    final clock = (now ?? DateTime.now()).toUtc();
    _pending.removeWhere((_, challenge) => challenge.isExpired(clock));
  }

  void clear() => _pending.clear();
}

String _randomBase64Url(int byteLength) {
  final bytes = Uint8List.fromList(
    List<int>.generate(byteLength, (_) => _trustRandom.nextInt(256)),
  );
  return base64UrlEncode(bytes).replaceAll('=', '');
}

Uint8List _decodeBase64Url(
  String value, {
  required int minimumBytes,
  required String label,
}) {
  if (value.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw FormatException('$label invalide');
  }
  try {
    final normalized = base64Url.normalize(value);
    final decoded = base64Url.decode(normalized);
    if (decoded.length < minimumBytes) {
      throw FormatException('$label trop court');
    }
    return Uint8List.fromList(decoded);
  } on FormatException {
    throw FormatException('$label invalide');
  }
}

void _validateIdentifier(String value, String label) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(value)) {
    throw FormatException('Identifiant $label invalide');
  }
}
