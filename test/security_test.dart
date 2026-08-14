import 'dart:io';
import 'dart:typed_data';

import 'package:castflow/security/file_hash.dart';
import 'package:castflow/security/security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sécurité', () {
    test('HMAC PIN compatible avec Node', () {
      expect(
        pinProof('482913', 'bm9uY2U=', 'mobile-1'),
        'u8Ky3YozwmFcz5k9crKH5S6gGQS09CEd0sqQiUmp3VE=',
      );
    });

    test('comparaison constante accepte seulement les valeurs identiques', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abc0'), isFalse);
    });

    test('noms dangereux neutralisés', () {
      expect(sanitizeFileName('../../../etc/passwd'), '______etc_passwd');
      expect(sanitizeFileName('CON.txt'), '_CON.txt');
      expect(sanitizeFileName('  ...  '), '_');
      expect(sanitizeFileName('photo?.jpg'), 'photo_.jpg');
    });

    test('identifiants de fichiers stricts', () {
      expect(sanitizeId('f_123-abc'), 'f_123-abc');
      expect(() => sanitizeId('../../secret'), throwsFormatException);
      expect(() => sanitizeId(''), throwsFormatException);
    });

    test('identifiants aléatoires distincts', () {
      final values = List.generate(100, (_) => secureId('t')).toSet();
      expect(values, hasLength(100));
      expect(values.every((value) => value.startsWith('t_')), isTrue);
    });
  });

  group('FNV-1a 64', () {
    test('vecteurs officiels', () {
      expect(hashBytes(const []), 'fnv1a64:cbf29ce484222325');
      expect(hashBytes('a'.codeUnits), 'fnv1a64:af63dc4c8601ec8c');
      expect(hashBytes('foobar'.codeUnits), 'fnv1a64:85944171f73967e8');
    });

    test('hash fichier identique au hash mémoire', () async {
      final directory = await Directory.systemTemp.createTemp('castflow-hash-');
      addTearDown(() => directory.delete(recursive: true));
      final bytes = Uint8List.fromList(
        List.generate(100000, (index) => index % 251),
      );
      final file = File('${directory.path}/data.bin');
      await file.writeAsBytes(bytes);
      expect(await hashFile(file.path), hashBytes(bytes));
    });

    test('détecte un octet modifié', () {
      final left = Uint8List.fromList(
        List.generate(1000, (index) => index % 256),
      );
      final right = Uint8List.fromList(left)..[500] ^= 1;
      expect(hashBytes(left), isNot(hashBytes(right)));
    });
  });
}
