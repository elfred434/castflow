import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'control_frame.dart';
import 'control_protocol.dart';
import 'windows_remote_adapter.dart';

class WindowsControlBackend {
  WindowsControlBackend({WindowsRemoteAdapter? adapter})
    : _adapter = adapter ?? WindowsRemoteAdapter();

  final WindowsRemoteAdapter _adapter;
  ControlCapabilities? _capabilities;

  ControlCapabilities get capabilities {
    final value = _capabilities;
    if (value == null) throw StateError('Backend Windows non initialisé');
    return value;
  }

  Future<bool> initialize() async {
    if (!await _adapter.isAvailable()) return false;
    final native = await _adapter.capabilities();
    if (!native.supports(ControlCapability.screenCapture)) return false;
    _capabilities = ControlCapabilities(
      values: native.values,
      maxWidth: native.maxWidth,
      maxHeight: native.maxHeight,
      maxFps: native.maxFps,
      codecs: const ['jpeg'],
    );
    return true;
  }

  Future<void> inject(RemoteInputEvent event) => _adapter.inject(event);

  Future<ControlFramePayload> captureJpeg(int maxWidth, int maxHeight) async {
    final frame = await _adapter.captureFrame(
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
    final jpeg = await Isolate.run(
      () => Uint8List.fromList(
        image.encodeJpg(
          image.Image.fromBytes(
            width: frame.width,
            height: frame.height,
            bytes: frame.bgra.buffer,
            bytesOffset: frame.bgra.offsetInBytes,
            rowStride: frame.stride,
            order: image.ChannelOrder.bgra,
          ),
          quality: 70,
        ),
      ),
    );
    return ControlFramePayload(
      width: frame.width,
      height: frame.height,
      codec: ControlFrameCodec.jpeg,
      bytes: jpeg,
    );
  }
}
