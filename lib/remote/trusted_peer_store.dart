import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../security/security.dart';
import 'control_protocol.dart';
import 'trust_protocol.dart';

abstract interface class SecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<Map<String, String>> readAll();
}

class FlutterSecretStore implements SecretStore {
  const FlutterSecretStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}

class TrustedPeer {
  const TrustedPeer({
    required this.deviceId,
    required this.name,
    required this.fingerprint,
    required this.approvedAt,
    required this.lastSeenAt,
    required this.capabilities,
  });

  final String deviceId;
  final String name;
  final String fingerprint;
  final DateTime approvedAt;
  final DateTime lastSeenAt;
  final Set<ControlCapability> capabilities;

  TrustedPeer copyWith({
    String? name,
    String? fingerprint,
    DateTime? lastSeenAt,
    Set<ControlCapability>? capabilities,
  }) => TrustedPeer(
    deviceId: deviceId,
    name: name ?? this.name,
    fingerprint: fingerprint ?? this.fingerprint,
    approvedAt: approvedAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    capabilities: capabilities ?? this.capabilities,
  );

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'name': name,
    'fingerprint': fingerprint,
    'approvedAt': approvedAt.toUtc().millisecondsSinceEpoch,
    'lastSeenAt': lastSeenAt.toUtc().millisecondsSinceEpoch,
    'capabilities': capabilities
        .map((capability) => capability.name)
        .toList(growable: false),
  };

  factory TrustedPeer.fromJson(Map<String, Object?> json) {
    final deviceId = sanitizeId(json['deviceId']);
    final name = json['name']?.toString().trim() ?? '';
    final fingerprint = json['fingerprint']?.toString().trim() ?? '';
    final approvedAt = (json['approvedAt'] as num?)?.toInt() ?? 0;
    final lastSeenAt = (json['lastSeenAt'] as num?)?.toInt() ?? 0;
    final rawCapabilities = json['capabilities'];

    if (name.isEmpty || name.length > 100) {
      throw const FormatException("Nom d'appareil approuvé invalide");
    }
    if (fingerprint.isEmpty || fingerprint.length > 256) {
      throw const FormatException("Empreinte d'appareil approuvé invalide");
    }
    if (approvedAt <= 0 || lastSeenAt <= 0) {
      throw const FormatException("Date d'appareil approuvé invalide");
    }
    final capabilities = <ControlCapability>{};
    if (rawCapabilities is List) {
      for (final raw in rawCapabilities) {
        for (final capability in ControlCapability.values) {
          if (capability.name == raw?.toString()) {
            capabilities.add(capability);
          }
        }
      }
    }
    if (capabilities.isEmpty) {
      throw const FormatException('Aucune capacité approuvée');
    }

    return TrustedPeer(
      deviceId: deviceId,
      name: name,
      fingerprint: fingerprint,
      approvedAt: DateTime.fromMillisecondsSinceEpoch(approvedAt, isUtc: true),
      lastSeenAt: DateTime.fromMillisecondsSinceEpoch(lastSeenAt, isUtc: true),
      capabilities: capabilities,
    );
  }
}

class TrustedPeerCredential {
  const TrustedPeerCredential({required this.peer, required this.secret});

  final TrustedPeer peer;
  final String secret;

  Map<String, Object?> toJson() => {'peer': peer.toJson(), 'secret': secret};

  factory TrustedPeerCredential.fromJson(Map<String, Object?> json) {
    final rawPeer = json['peer'];
    final secret = json['secret']?.toString() ?? '';
    if (rawPeer is! Map) {
      throw const FormatException("Métadonnées d'appareil approuvé invalides");
    }
    if (!isValidTrustSecret(secret)) {
      throw const FormatException('Secret de confiance invalide');
    }
    return TrustedPeerCredential(
      peer: TrustedPeer.fromJson(rawPeer.cast<String, Object?>()),
      secret: secret,
    );
  }
}

class TrustedPeerStore {
  TrustedPeerStore(this._storage);

  static const _prefix = 'castflow.trust.peer.';
  static const _indexKey = 'castflow.trust.index';

  final SecretStore _storage;
  Future<void> _tail = Future<void>.value();

  Future<List<TrustedPeer>> list() => _locked(() async {
    final ids = await _readIndex();
    final peers = <TrustedPeer>[];
    for (final id in ids) {
      final credential = await _readCredential(id);
      if (credential != null) peers.add(credential.peer);
    }
    peers.sort((left, right) => right.lastSeenAt.compareTo(left.lastSeenAt));
    return peers;
  });

  Future<TrustedPeerCredential?> credential(String deviceId) =>
      _locked(() async => _readCredential(sanitizeId(deviceId)));

  Future<void> approve({required TrustedPeer peer, required String secret}) =>
      _locked(() async {
        if (!isValidTrustSecret(secret)) {
          throw const FormatException('Secret de confiance invalide');
        }
        final normalized = TrustedPeer.fromJson(peer.toJson());
        final credential = TrustedPeerCredential(
          peer: normalized,
          secret: secret,
        );
        await _storage.write(
          _peerKey(normalized.deviceId),
          jsonEncode(credential.toJson()),
        );
        final ids = await _readIndex();
        if (ids.add(normalized.deviceId)) await _writeIndex(ids);
      });

  Future<void> updateLastSeen(String deviceId, DateTime value) =>
      _locked(() async {
        final id = sanitizeId(deviceId);
        final credential = await _readCredential(id);
        if (credential == null) return;
        final updated = TrustedPeerCredential(
          peer: credential.peer.copyWith(lastSeenAt: value.toUtc()),
          secret: credential.secret,
        );
        await _storage.write(_peerKey(id), jsonEncode(updated.toJson()));
      });

  Future<void> revoke(String deviceId) => _locked(() async {
    final id = sanitizeId(deviceId);
    await _storage.delete(_peerKey(id));
    final ids = await _readIndex();
    if (ids.remove(id)) await _writeIndex(ids);
  });

  Future<void> revokeAll() => _locked(() async {
    final values = await _storage.readAll();
    for (final key in values.keys.where((key) => key.startsWith(_prefix))) {
      await _storage.delete(key);
    }
    await _storage.delete(_indexKey);
  });

  Future<TrustedPeerCredential?> _readCredential(String deviceId) async {
    final raw = await _storage.read(_peerKey(deviceId));
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException(
        "Enregistrement d'appareil approuvé invalide",
      );
    }
    final credential = TrustedPeerCredential.fromJson(
      decoded.cast<String, Object?>(),
    );
    if (credential.peer.deviceId != deviceId) {
      throw const FormatException("Identité d'appareil approuvé incohérente");
    }
    return credential;
  }

  Future<Set<String>> _readIndex() async {
    final raw = await _storage.read(_indexKey);
    if (raw == null) return <String>{};
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException("Index d'appareils approuvés invalide");
    }
    return decoded.map((value) => sanitizeId(value)).toSet();
  }

  Future<void> _writeIndex(Set<String> ids) => _storage.write(
    _indexKey,
    jsonEncode(ids.toList(growable: false)..sort()),
  );

  String _peerKey(String deviceId) => '$_prefix$deviceId';

  Future<T> _locked<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
