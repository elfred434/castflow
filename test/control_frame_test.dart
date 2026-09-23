import 'dart:typed_data';

import 'package:castflow/remote/control_frame.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sérialise une trame JPEG binaire et la relit', () {
    final source = ControlVideoFrame(
      sessionId: 'ctrl_123',
      sequence: 42,
      capturedAt: DateTime.utc(2026, 9, 23, 14, 30),
      width: 1280,
      height: 720,
      codec: ControlFrameCodec.jpeg,
      bytes: Uint8List.fromList([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]),
    );

    final decoded = ControlVideoFrame.decode(source.encode());

    expect(decoded.sessionId, source.sessionId);
    expect(decoded.sequence, 42);
    expect(decoded.capturedAt, source.capturedAt);
    expect(decoded.width, 1280);
    expect(decoded.height, 720);
    expect(decoded.codec, ControlFrameCodec.jpeg);
    expect(decoded.bytes, source.bytes);
  });

  test('refuse une trame tronquée ou avec une longueur falsifiée', () {
    final frame = ControlVideoFrame(
      sessionId: 'ctrl_1',
      sequence: 0,
      capturedAt: DateTime.now(),
      width: 320,
      height: 240,
      codec: ControlFrameCodec.jpeg,
      bytes: Uint8List.fromList([1, 2, 3]),
    ).encode();

    expect(
      () => ControlVideoFrame.decode(frame.sublist(0, 20)),
      throwsFormatException,
    );
    frame[27] = 20;
    expect(() => ControlVideoFrame.decode(frame), throwsFormatException);
  });

  test('refuse un identifiant et une charge utile invalides', () {
    expect(
      () => ControlVideoFrame(
        sessionId: '../session',
        sequence: 0,
        capturedAt: DateTime.now(),
        width: 320,
        height: 240,
        codec: ControlFrameCodec.jpeg,
        bytes: Uint8List.fromList([1]),
      ).encode(),
      throwsFormatException,
    );
    expect(
      () => ControlFramePayload(
        width: 320,
        height: 240,
        codec: ControlFrameCodec.jpeg,
        bytes: Uint8List(0),
      ).validate(),
      throwsFormatException,
    );
  });
}
