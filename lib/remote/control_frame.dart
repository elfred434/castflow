import 'dart:convert';
import 'dart:typed_data';

const _frameMagic = 0x43464631; // CFF1
const _frameVersion = 1;
const _frameHeaderLength = 28;
const maxControlFramePayload = 8 * 1024 * 1024;

enum ControlFrameCodec { jpeg }

class ControlFramePayload {
  const ControlFramePayload({
    required this.width,
    required this.height,
    required this.codec,
    required this.bytes,
  });

  final int width;
  final int height;
  final ControlFrameCodec codec;
  final Uint8List bytes;

  void validate() {
    if (width < 1 || width > 3840 || height < 1 || height > 2160) {
      throw const FormatException('Dimensions de trame invalides');
    }
    if (bytes.isEmpty || bytes.length > maxControlFramePayload) {
      throw const FormatException('Taille de trame invalide');
    }
  }
}

class ControlVideoFrame extends ControlFramePayload {
  const ControlVideoFrame({
    required this.sessionId,
    required this.sequence,
    required this.capturedAt,
    required super.width,
    required super.height,
    required super.codec,
    required super.bytes,
  });

  final String sessionId;
  final int sequence;
  final DateTime capturedAt;

  Uint8List encode() {
    validate();
    if (!_validId(sessionId) || sequence < 0 || sequence > 0xffffffff) {
      throw const FormatException('Métadonnées de trame invalides');
    }
    final sessionBytes = utf8.encode(sessionId);
    if (sessionBytes.isEmpty || sessionBytes.length > 100) {
      throw const FormatException('Identifiant de session vidéo invalide');
    }
    final output = Uint8List(
      _frameHeaderLength + sessionBytes.length + bytes.length,
    );
    final data = ByteData.sublistView(output);
    data
      ..setUint32(0, _frameMagic)
      ..setUint8(4, _frameVersion)
      ..setUint8(5, codec.index)
      ..setUint8(6, sessionBytes.length)
      ..setUint8(7, 0)
      ..setUint32(8, sequence)
      ..setInt64(12, capturedAt.toUtc().microsecondsSinceEpoch)
      ..setUint16(20, width)
      ..setUint16(22, height)
      ..setUint32(24, bytes.length);
    output.setRange(
      _frameHeaderLength,
      _frameHeaderLength + sessionBytes.length,
      sessionBytes,
    );
    output.setRange(
      _frameHeaderLength + sessionBytes.length,
      output.length,
      bytes,
    );
    return output;
  }

  factory ControlVideoFrame.decode(List<int> raw) {
    if (raw.length < _frameHeaderLength) {
      throw const FormatException('Trame vidéo tronquée');
    }
    final input = raw is Uint8List ? raw : Uint8List.fromList(raw);
    final data = ByteData.sublistView(input);
    if (data.getUint32(0) != _frameMagic || data.getUint8(4) != _frameVersion) {
      throw const FormatException('Format de trame vidéo inconnu');
    }
    final codecIndex = data.getUint8(5);
    if (codecIndex >= ControlFrameCodec.values.length) {
      throw const FormatException('Codec vidéo inconnu');
    }
    final sessionLength = data.getUint8(6);
    final payloadLength = data.getUint32(24);
    final expectedLength = _frameHeaderLength + sessionLength + payloadLength;
    if (sessionLength == 0 ||
        sessionLength > 100 ||
        payloadLength == 0 ||
        payloadLength > maxControlFramePayload ||
        expectedLength != input.length) {
      throw const FormatException('Longueur de trame vidéo invalide');
    }
    final sessionId = utf8.decode(
      input.sublist(_frameHeaderLength, _frameHeaderLength + sessionLength),
    );
    if (!_validId(sessionId)) {
      throw const FormatException('Session vidéo invalide');
    }
    final frame = ControlVideoFrame(
      sessionId: sessionId,
      sequence: data.getUint32(8),
      capturedAt: DateTime.fromMicrosecondsSinceEpoch(
        data.getInt64(12),
        isUtc: true,
      ),
      width: data.getUint16(20),
      height: data.getUint16(22),
      codec: ControlFrameCodec.values[codecIndex],
      bytes: Uint8List.sublistView(input, _frameHeaderLength + sessionLength),
    );
    frame.validate();
    return frame;
  }
}

bool _validId(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(value);
