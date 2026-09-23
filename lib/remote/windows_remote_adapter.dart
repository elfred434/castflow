import 'package:flutter/services.dart';

import 'control_protocol.dart';

class WindowsCapturedFrame {
  WindowsCapturedFrame({
    required this.width,
    required this.height,
    required this.stride,
    required this.bgra,
  }) {
    if (width <= 0 || height <= 0 || stride != width * 4) {
      throw const FormatException('Dimensions de capture Windows invalides');
    }
    if (bgra.length != stride * height) {
      throw const FormatException('Taille de capture Windows invalide');
    }
  }

  final int width;
  final int height;
  final int stride;
  final Uint8List bgra;
}

class WindowsRemoteAdapter {
  WindowsRemoteAdapter({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'castflow/windows_remote';
  final MethodChannel _channel;

  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') == true;
    } on MissingPluginException {
      return false;
    }
  }

  Future<ControlCapabilities> capabilities() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'getCapabilities',
    );
    if (raw == null) {
      throw StateError('Capacités Windows indisponibles');
    }
    return ControlCapabilities.fromJson(raw);
  }

  Future<WindowsCapturedFrame> captureFrame({
    int maxWidth = 1280,
    int maxHeight = 720,
  }) async {
    if (maxWidth < 320 || maxWidth > 3840) {
      throw RangeError.range(maxWidth, 320, 3840, 'maxWidth');
    }
    if (maxHeight < 240 || maxHeight > 2160) {
      throw RangeError.range(maxHeight, 240, 2160, 'maxHeight');
    }
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'captureFrame',
      {'maxWidth': maxWidth, 'maxHeight': maxHeight},
    );
    if (raw == null) throw StateError('Capture Windows vide');
    final pixels = raw['pixels'];
    if (pixels is! Uint8List) {
      throw const FormatException('Pixels de capture Windows absents');
    }
    return WindowsCapturedFrame(
      width: (raw['width'] as num?)?.toInt() ?? 0,
      height: (raw['height'] as num?)?.toInt() ?? 0,
      stride: (raw['stride'] as num?)?.toInt() ?? 0,
      bgra: pixels,
    );
  }

  Future<void> inject(RemoteInputEvent event) async {
    event.validate();
    final accepted = await _channel.invokeMethod<bool>(
      'injectInput',
      event.toJson(),
    );
    if (accepted != true) {
      throw StateError('Entrée Windows non injectée');
    }
  }
}
