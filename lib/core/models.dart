import 'dart:io';

import '../security/security.dart';

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.kind,
    required this.fingerprint,
  });

  final String id;
  final String name;
  final String platform;
  final String kind;
  final String fingerprint;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    'kind': kind,
    'fingerprint': fingerprint,
  };

  factory DeviceInfo.fromJson(Map<String, Object?> json) => DeviceInfo(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? 'Appareil CastFlow',
    platform: json['platform']?.toString() ?? 'unknown',
    kind: json['kind']?.toString() ?? 'mobile',
    fingerprint: json['fingerprint']?.toString() ?? '',
  );

  static DeviceInfo ephemeral({String? name}) => DeviceInfo(
    id: secureId('dev'),
    name: name ?? Platform.localHostname,
    platform: Platform.isWindows
        ? 'windows'
        : Platform.isAndroid
        ? 'android'
        : Platform.operatingSystem,
    kind: Platform.isAndroid || Platform.isIOS ? 'mobile' : 'desktop',
    fingerprint: secureId().substring(0, 16),
  );
}

class RemoteDevice extends DeviceInfo {
  const RemoteDevice({
    required super.id,
    required super.name,
    required super.platform,
    required super.kind,
    required super.fingerprint,
    required this.host,
    required this.httpPort,
    required this.wsPort,
    required this.requiresPin,
    this.secure = false,
    this.source = 'manual',
    this.lastSeen,
  });

  final String host;
  final int httpPort;
  final int wsPort;
  final bool requiresPin;
  final bool secure;
  final String source;
  final DateTime? lastSeen;

  RemoteDevice copyWith({DateTime? lastSeen}) => RemoteDevice(
    id: id,
    name: name,
    platform: platform,
    kind: kind,
    fingerprint: fingerprint,
    host: host,
    httpPort: httpPort,
    wsPort: wsPort,
    requiresPin: requiresPin,
    secure: secure,
    source: source,
    lastSeen: lastSeen ?? this.lastSeen,
  );
}

class LocalFile {
  const LocalFile({
    required this.id,
    required this.name,
    required this.path,
    required this.size,
    required this.mime,
    this.hash,
  });

  final String id;
  final String name;
  final String path;
  final int size;
  final String mime;
  final String? hash;

  LocalFile copyWith({String? hash}) => LocalFile(
    id: id,
    name: name,
    path: path,
    size: size,
    mime: mime,
    hash: hash ?? this.hash,
  );

  Map<String, Object?> toManifest() => {
    'id': id,
    'name': name,
    'size': size,
    'mime': mime,
    if (hash != null) 'hash': hash,
  };
}

class IncomingOffer {
  const IncomingOffer({
    required this.transferId,
    required this.totalSize,
    required this.files,
  });

  final String transferId;
  final int totalSize;
  final List<OfferedFile> files;
}

class OfferedFile {
  const OfferedFile({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.token,
    this.hash,
  });

  final String id;
  final String name;
  final int size;
  final String mime;
  final String token;
  final String? hash;

  factory OfferedFile.fromJson(Map<String, Object?> json) => OfferedFile(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? 'fichier',
    size: (json['size'] as num?)?.toInt() ?? 0,
    mime: json['mime']?.toString() ?? 'application/octet-stream',
    token: json['token']?.toString() ?? '',
    hash: json['hash']?.toString(),
  );

  Map<String, Object?> toJson({bool includeToken = true}) => {
    'id': id,
    'name': name,
    'size': size,
    'mime': mime,
    if (includeToken) 'token': token,
    if (hash != null) 'hash': hash,
  };
}

enum TransferDirection { send, receive }

enum TransferState {
  pending,
  transferring,
  completed,
  rejected,
  cancelled,
  failed,
}

class TransferSnapshot {
  const TransferSnapshot({
    required this.id,
    required this.direction,
    required this.state,
    required this.peerName,
    required this.totalBytes,
    required this.transferredBytes,
    required this.fileCount,
    required this.startedAt,
    this.error,
  });

  final String id;
  final TransferDirection direction;
  final TransferState state;
  final String peerName;
  final int totalBytes;
  final int transferredBytes;
  final int fileCount;
  final DateTime startedAt;
  final String? error;

  double get progress => totalBytes == 0
      ? (state == TransferState.completed ? 1 : 0)
      : (transferredBytes / totalBytes).clamp(0, 1);
}

String guessMime(String name) {
  final extension = name.contains('.')
      ? name.split('.').last.toLowerCase()
      : '';
  return const {
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'png': 'image/png',
        'gif': 'image/gif',
        'webp': 'image/webp',
        'mp4': 'video/mp4',
        'mkv': 'video/x-matroska',
        'mov': 'video/quicktime',
        'mp3': 'audio/mpeg',
        'wav': 'audio/wav',
        'pdf': 'application/pdf',
        'zip': 'application/zip',
        'apk': 'application/vnd.android.package-archive',
        'txt': 'text/plain',
        'json': 'application/json',
        'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      }[extension] ??
      'application/octet-stream';
}

String formatBytes(num bytes) {
  if (bytes < 1024) return '${bytes.round()} o';
  const units = ['Ko', 'Mo', 'Go', 'To'];
  var value = bytes.toDouble();
  var unit = -1;
  do {
    value /= 1024;
    unit++;
  } while (value >= 1024 && unit < units.length - 1);
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}
