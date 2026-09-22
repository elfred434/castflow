import 'dart:convert';

enum ControlCapability {
  screenCapture,
  pointer,
  keyboard,
  textInput,
  systemNavigation,
  clipboard,
  wakeDevice,
}

enum ControlSessionState {
  idle,
  requesting,
  awaitingLocalApproval,
  active,
  paused,
  stopped,
  denied,
  failed,
}

enum RemoteInputKind {
  pointerDown,
  pointerMove,
  pointerUp,
  scroll,
  keyDown,
  keyUp,
  text,
  back,
  home,
  recentApps,
}

abstract final class ControlMessageType {
  static const capabilities = 'CONTROL_CAPABILITIES';
  static const request = 'CONTROL_REQUEST';
  static const accept = 'CONTROL_ACCEPT';
  static const deny = 'CONTROL_DENY';
  static const ready = 'CONTROL_READY';
  static const stop = 'CONTROL_STOP';
  static const pause = 'CONTROL_PAUSE';
  static const resume = 'CONTROL_RESUME';
  static const input = 'CONTROL_INPUT';
  static const frameInfo = 'CONTROL_FRAME_INFO';
  static const error = 'CONTROL_ERROR';
  static const trustChallenge = 'TRUST_CHALLENGE';
  static const trustProof = 'TRUST_PROOF';
  static const trustRevoke = 'TRUST_REVOKE';
}

class ControlCapabilities {
  const ControlCapabilities({
    required this.values,
    this.maxWidth = 1280,
    this.maxHeight = 720,
    this.maxFps = 15,
    this.codecs = const ['jpeg'],
  });

  final Set<ControlCapability> values;
  final int maxWidth;
  final int maxHeight;
  final int maxFps;
  final List<String> codecs;

  bool supports(ControlCapability capability) => values.contains(capability);

  Map<String, Object?> toJson() => {
    'values': values.map((value) => value.name).toList(growable: false),
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
    'maxFps': maxFps,
    'codecs': codecs,
  };

  factory ControlCapabilities.fromJson(Map<String, Object?> json) {
    final rawValues = json['values'];
    final values = <ControlCapability>{};
    if (rawValues is List) {
      for (final raw in rawValues) {
        for (final capability in ControlCapability.values) {
          if (capability.name == raw?.toString()) values.add(capability);
        }
      }
    }
    final width = (json['maxWidth'] as num?)?.toInt() ?? 1280;
    final height = (json['maxHeight'] as num?)?.toInt() ?? 720;
    final fps = (json['maxFps'] as num?)?.toInt() ?? 15;
    final rawCodecs = json['codecs'];
    return ControlCapabilities(
      values: values,
      maxWidth: width.clamp(320, 3840).toInt(),
      maxHeight: height.clamp(240, 2160).toInt(),
      maxFps: fps.clamp(1, 60).toInt(),
      codecs: rawCodecs is List && rawCodecs.isNotEmpty
          ? rawCodecs.map((value) => value.toString()).toList(growable: false)
          : const ['jpeg'],
    );
  }
}

class ControlRequest {
  const ControlRequest({
    required this.sessionId,
    required this.requested,
    this.width = 1280,
    this.height = 720,
    this.fps = 15,
    this.codec = 'jpeg',
  });

  final String sessionId;
  final Set<ControlCapability> requested;
  final int width;
  final int height;
  final int fps;
  final String codec;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'requested': requested.map((value) => value.name).toList(growable: false),
    'width': width,
    'height': height,
    'fps': fps,
    'codec': codec,
  };

  factory ControlRequest.fromJson(Map<String, Object?> json) {
    final id = json['sessionId']?.toString() ?? '';
    if (!_validId(id))
      throw const FormatException('Session de contrôle invalide');
    final capabilities = ControlCapabilities.fromJson({
      'values': json['requested'],
      'maxWidth': json['width'],
      'maxHeight': json['height'],
      'maxFps': json['fps'],
      'codecs': [json['codec']?.toString() ?? 'jpeg'],
    });
    return ControlRequest(
      sessionId: id,
      requested: capabilities.values,
      width: capabilities.maxWidth,
      height: capabilities.maxHeight,
      fps: capabilities.maxFps,
      codec: capabilities.codecs.first,
    );
  }
}

class RemoteInputEvent {
  const RemoteInputEvent({
    required this.kind,
    required this.sequence,
    this.x,
    this.y,
    this.deltaX,
    this.deltaY,
    this.key,
    this.text,
    this.buttons = 0,
  });

  final RemoteInputKind kind;
  final int sequence;
  final double? x;
  final double? y;
  final double? deltaX;
  final double? deltaY;
  final String? key;
  final String? text;
  final int buttons;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'sequence': sequence,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    if (deltaX != null) 'deltaX': deltaX,
    if (deltaY != null) 'deltaY': deltaY,
    if (key != null) 'key': key,
    if (text != null) 'text': text,
    'buttons': buttons,
  };

  String encode() => jsonEncode(toJson());

  factory RemoteInputEvent.decode(Object? raw) {
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map)
      throw const FormatException('Événement distant invalide');
    final json = decoded.cast<String, Object?>();
    final kindName = json['kind']?.toString();
    final kind = RemoteInputKind.values
        .where((value) => value.name == kindName)
        .firstOrNull;
    if (kind == null)
      throw const FormatException('Type d’entrée distant invalide');
    final sequence = (json['sequence'] as num?)?.toInt() ?? -1;
    if (sequence < 0) throw const FormatException('Séquence distante invalide');
    final event = RemoteInputEvent(
      kind: kind,
      sequence: sequence,
      x: (json['x'] as num?)?.toDouble(),
      y: (json['y'] as num?)?.toDouble(),
      deltaX: (json['deltaX'] as num?)?.toDouble(),
      deltaY: (json['deltaY'] as num?)?.toDouble(),
      key: json['key']?.toString(),
      text: json['text']?.toString(),
      buttons: (json['buttons'] as num?)?.toInt() ?? 0,
    );
    event.validate();
    return event;
  }

  void validate() {
    if (buttons < 0 || buttons > 31) {
      throw const FormatException('Boutons de pointeur invalides');
    }
    if (_isPointer(kind)) {
      if (x == null || y == null || x! < 0 || x! > 1 || y! < 0 || y! > 1) {
        throw const FormatException('Coordonnées distantes invalides');
      }
    }
    if ((kind == RemoteInputKind.keyDown || kind == RemoteInputKind.keyUp) &&
        (key == null || key!.isEmpty || key!.length > 64)) {
      throw const FormatException('Touche distante invalide');
    }
    if (kind == RemoteInputKind.text &&
        (text == null || text!.isEmpty || text!.length > 4096)) {
      throw const FormatException('Texte distant invalide');
    }
  }

  static bool _isPointer(RemoteInputKind kind) =>
      kind == RemoteInputKind.pointerDown ||
      kind == RemoteInputKind.pointerMove ||
      kind == RemoteInputKind.pointerUp;
}

bool _validId(String value) =>
    value.isNotEmpty &&
    value.length <= 100 &&
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
