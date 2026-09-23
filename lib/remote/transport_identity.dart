import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

import '../security/security.dart';
import 'trusted_peer_store.dart';

class TransportIdentity {
  const TransportIdentity({
    required this.deviceId,
    required this.certificatePem,
    required this.privateKeyPem,
    required this.fingerprint,
  });

  final String deviceId;
  final String certificatePem;
  final String privateKeyPem;
  final String fingerprint;

  SecurityContext createServerContext() {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(certificatePem))
      ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
    return context;
  }
}

class TransportIdentityStore {
  TransportIdentityStore(this._storage);

  static const _certificateKey = 'castflow.transport.certificate';
  static const _privateKeyKey = 'castflow.transport.privateKey';
  static const _fingerprintKey = 'castflow.transport.fingerprint';
  static const _deviceIdKey = 'castflow.transport.deviceId';

  final SecretStore _storage;
  Future<TransportIdentity>? _loading;

  Future<TransportIdentity> loadOrCreate(String deviceId) {
    final validatedId = sanitizeId(deviceId);
    return _loading ??= _loadOrCreate(validatedId).whenComplete(() {
      _loading = null;
    });
  }

  Future<TransportIdentity> _loadOrCreate(String deviceId) async {
    final certificate = await _storage.read(_certificateKey);
    final privateKey = await _storage.read(_privateKeyKey);
    final fingerprint = await _storage.read(_fingerprintKey);
    final storedDeviceId = await _storage.read(_deviceIdKey);
    final present = [
      certificate,
      privateKey,
      fingerprint,
      storedDeviceId,
    ].whereType<String>().length;

    if (present == 4) {
      if (storedDeviceId != deviceId) {
        throw StateError(
          'L’identité TLS appartient à un autre identifiant d’appareil',
        );
      }
      final computed = certificateFingerprintFromPem(certificate!);
      if (!constantTimeEquals(computed, fingerprint!)) {
        throw const FormatException('Empreinte du certificat TLS incohérente');
      }
      final identity = TransportIdentity(
        deviceId: deviceId,
        certificatePem: certificate,
        privateKeyPem: privateKey!,
        fingerprint: fingerprint,
      );
      identity.createServerContext();
      return identity;
    }
    if (present != 0) {
      throw const FormatException('Identité TLS incomplète dans le coffre');
    }

    final generated = await Isolate.run(() => _generateIdentity(deviceId));
    generated.createServerContext();
    await _storage.write(_certificateKey, generated.certificatePem);
    await _storage.write(_privateKeyKey, generated.privateKeyPem);
    await _storage.write(_fingerprintKey, generated.fingerprint);
    await _storage.write(_deviceIdKey, generated.deviceId);
    return generated;
  }

  Future<void> delete() async {
    await _storage.delete(_certificateKey);
    await _storage.delete(_privateKeyKey);
    await _storage.delete(_fingerprintKey);
    await _storage.delete(_deviceIdKey);
  }
}

TransportIdentity _generateIdentity(String deviceId) {
  final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final privateKey = pair.privateKey as RSAPrivateKey;
  final publicKey = pair.publicKey as RSAPublicKey;
  final csr = X509Utils.generateRsaCsrPem(
    {'CN': 'CastFlow $deviceId', 'O': 'CastFlow'},
    privateKey,
    publicKey,
    san: const ['localhost'],
  );
  final now = DateTime.now().toUtc();
  final certificate = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csr,
    3650,
    sans: const ['localhost'],
    serialNumber: now.microsecondsSinceEpoch.toString(),
    notBefore: now.subtract(const Duration(minutes: 5)),
  );
  final privateKeyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
  return TransportIdentity(
    deviceId: deviceId,
    certificatePem: certificate,
    privateKeyPem: privateKeyPem,
    fingerprint: certificateFingerprintFromPem(certificate),
  );
}

String certificateFingerprintFromPem(String certificatePem) {
  final der = CryptoUtils.getBytesFromPEMString(certificatePem);
  if (der.isEmpty) throw const FormatException('Certificat TLS vide');
  return sha256.convert(der).toString();
}

String certificateFingerprint(X509Certificate certificate) =>
    sha256.convert(certificate.der).toString();

bool certificateMatchesFingerprint(
  X509Certificate certificate,
  String expectedFingerprint,
) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedFingerprint)) return false;
  return constantTimeEquals(
    certificateFingerprint(certificate),
    expectedFingerprint,
  );
}
