import 'package:castflow/remote/control_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ControlCapabilities', () {
    test('sérialise et borne les paramètres vidéo', () {
      final decoded = ControlCapabilities.fromJson({
        'values': ['screenCapture', 'pointer', 'inconnue'],
        'maxWidth': 9000,
        'maxHeight': 100,
        'maxFps': 120,
        'codecs': ['jpeg'],
      });

      expect(decoded.supports(ControlCapability.screenCapture), isTrue);
      expect(decoded.supports(ControlCapability.pointer), isTrue);
      expect(decoded.values.length, 2);
      expect(decoded.maxWidth, 3840);
      expect(decoded.maxHeight, 240);
      expect(decoded.maxFps, 60);
    });
  });

  group('ControlRequest', () {
    test('refuse un identifiant de session dangereux', () {
      expect(
        () => ControlRequest.fromJson({
          'sessionId': '../session',
          'requested': ['screenCapture'],
        }),
        throwsFormatException,
      );
    });

    test('conserve les capacités demandées', () {
      final request = ControlRequest.fromJson({
        'sessionId': 'ctrl_123',
        'requested': ['screenCapture', 'keyboard'],
        'width': 1280,
        'height': 720,
        'fps': 15,
        'codec': 'jpeg',
      });

      expect(request.requested, {
        ControlCapability.screenCapture,
        ControlCapability.keyboard,
      });
      expect(request.toJson()['codec'], 'jpeg');
    });
  });

  group('RemoteInputEvent', () {
    test('accepte des coordonnées normalisées', () {
      final event = RemoteInputEvent.decode({
        'kind': 'pointerMove',
        'sequence': 42,
        'x': 0.25,
        'y': 0.75,
        'buttons': 1,
      });

      expect(event.kind, RemoteInputKind.pointerMove);
      expect(event.x, 0.25);
      expect(event.y, 0.75);
    });

    test('refuse les coordonnées hors écran', () {
      expect(
        () => RemoteInputEvent.decode({
          'kind': 'pointerDown',
          'sequence': 1,
          'x': 1.01,
          'y': 0.5,
        }),
        throwsFormatException,
      );
    });

    test('limite la taille du texte injecté', () {
      expect(
        () => RemoteInputEvent.decode({
          'kind': 'text',
          'sequence': 2,
          'text': List.filled(4097, 'x').join(),
        }),
        throwsFormatException,
      );
    });
  });
}
