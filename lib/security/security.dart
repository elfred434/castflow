import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final Random _secureRandom = Random.secure();

String secureId([String prefix = '']) {
  final bytes = Uint8List.fromList(
    List<int>.generate(16, (_) => _secureRandom.nextInt(256)),
  );
  final value = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return prefix.isEmpty ? value : '${prefix}_$value';
}

String generatePin() => (100000 + _secureRandom.nextInt(900000)).toString();

String pinProof(String pin, String nonce, String deviceId) {
  final hmac = Hmac(sha256, utf8.encode(pin));
  return base64Encode(hmac.convert(utf8.encode('$nonce$deviceId')).bytes);
}

bool constantTimeEquals(String left, String right) {
  final a = utf8.encode(left);
  final b = utf8.encode(right);
  var difference = a.length ^ b.length;
  final length = max(a.length, b.length);
  for (var index = 0; index < length; index++) {
    difference |=
        (index < a.length ? a[index] : 0) ^ (index < b.length ? b[index] : 0);
  }
  return difference == 0;
}

String sanitizeFileName(Object? value) {
  var name = (value?.toString() ?? '')
      .replaceAll(RegExp(r'[/\\]'), '_')
      .replaceAll(RegExp(r'\.{2,}'), '_')
      .replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_')
      .replaceFirst(RegExp(r'^[.\s]+'), '')
      .replaceFirst(RegExp(r'[.\s]+$'), '')
      .trim();
  if (name.length > 200) name = name.substring(0, 200);
  if (RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  return name.isEmpty ? 'fichier' : name;
}

String sanitizeId(Object? value) {
  final id = value?.toString() ?? '';
  if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id)) {
    throw const FormatException('Identifiant de fichier invalide');
  }
  return id;
}
