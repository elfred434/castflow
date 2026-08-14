import 'package:castflow/core/constants.dart';
import 'package:castflow/core/models.dart';
import 'package:castflow/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const device = DeviceInfo(
    id: 'desktop-1',
    name: 'PC Élise',
    platform: 'windows',
    kind: 'desktop',
    fingerprint: 'a1b2c3d4',
  );

  group('enveloppe', () {
    test('aller-retour JSON', () {
      final source = Envelope(type: 'HELLO', data: {'device': device.toJson()});
      final decoded = Envelope.decode(source.encode());
      expect(decoded.version, CastFlowProtocol.version);
      expect(decoded.type, 'HELLO');
      expect(decoded.id, source.id);
      expect((decoded.data['device'] as Map)['name'], 'PC Élise');
    });

    test('réponse corrélée', () {
      final source = Envelope(type: 'PING', data: const {});
      final response = source.reply('PONG', const {});
      expect(response.replyTo, source.id);
      expect(response.type, 'PONG');
    });

    test('rejette une enveloppe sans type', () {
      expect(() => Envelope.decode('{"id":"m1"}'), throwsFormatException);
      expect(() => Envelope.decode('pas du json'), throwsFormatException);
    });
  });

  group('QR de connexion', () {
    test('aller-retour complet', () {
      final url = buildConnectUrl(
        host: '192.168.1.12',
        httpPort: 53317,
        wsPort: 53318,
        device: device,
        pin: '482913',
      );
      final parsed = parseConnectUrl(url)!;
      expect(parsed.host, '192.168.1.12');
      expect(parsed.id, device.id);
      expect(parsed.name, device.name);
      expect(parsed.httpPort, 53317);
      expect(parsed.wsPort, 53318);
      expect(parsed.requiresPin, isTrue);
      expect(pinFromConnectUrl(url), '482913');
    });

    test('tolère un préfixe Wi-Fi', () {
      final url = buildConnectUrl(
        host: '10.0.0.1',
        httpPort: 6000,
        wsPort: 6001,
        device: device,
      );
      final parsed = parseConnectUrl('WIFI:S:CastFlow;T:WPA;P:secret;;$url');
      expect(parsed?.host, '10.0.0.1');
      expect(parsed?.requiresPin, isFalse);
    });

    test('rejette les ports et schémas invalides', () {
      expect(parseConnectUrl('https://example.com'), isNull);
      expect(
        parseConnectUrl('castflow://connect?host=1.2.3.4&id=x&http=99999'),
        isNull,
      );
    });
  });

  test('formatage des tailles', () {
    expect(formatBytes(0), '0 o');
    expect(formatBytes(1024), '1.0 Ko');
    expect(formatBytes(5 * 1024 * 1024), '5.0 Mo');
  });
}
