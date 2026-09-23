import 'package:castflow/remote/control_protocol.dart';
import 'package:castflow/remote/windows_remote_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('castflow/windows_remote.test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('lit les capacités réellement retournées par Windows', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getCapabilities');
      return {
        'values': ['screenCapture', 'pointer', 'keyboard', 'textInput'],
        'maxWidth': 1280,
        'maxHeight': 720,
        'maxFps': 15,
        'codecs': ['bgra'],
      };
    });

    final capabilities = await WindowsRemoteAdapter(channel: channel)
        .capabilities();

    expect(capabilities.supports(ControlCapability.screenCapture), isTrue);
    expect(capabilities.supports(ControlCapability.pointer), isTrue);
    expect(capabilities.maxWidth, 1280);
    expect(capabilities.codecs, ['bgra']);
  });

  test('valide les dimensions et la taille d’une capture BGRA', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'captureFrame');
      expect(call.arguments, {'maxWidth': 1280, 'maxHeight': 720});
      return {'width': 2, 'height': 2, 'stride': 8, 'pixels': Uint8List(16)};
    });

    final frame = await WindowsRemoteAdapter(channel: channel).captureFrame();

    expect(frame.width, 2);
    expect(frame.height, 2);
    expect(frame.bgra.length, 16);
  });

  test('refuse une capture native tronquée', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      return {'width': 2, 'height': 2, 'stride': 8, 'pixels': Uint8List(15)};
    });

    await expectLater(
      WindowsRemoteAdapter(channel: channel).captureFrame(),
      throwsFormatException,
    );
  });

  test('transmet seulement une entrée déjà validée', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return true;
    });
    const event = RemoteInputEvent(
      kind: RemoteInputKind.pointerMove,
      sequence: 8,
      x: 0.25,
      y: 0.75,
      buttons: 1,
    );

    await WindowsRemoteAdapter(channel: channel).inject(event);

    expect(received?.method, 'injectInput');
    expect((received?.arguments as Map)['sequence'], 8);
  });

  test('ne contacte pas Windows pour une entrée invalide', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return true;
    });
    const event = RemoteInputEvent(
      kind: RemoteInputKind.pointerMove,
      sequence: 1,
      x: -0.1,
      y: 0.5,
    );

    await expectLater(
      WindowsRemoteAdapter(channel: channel).inject(event),
      throwsFormatException,
    );
    expect(calls, 0);
  });
}
