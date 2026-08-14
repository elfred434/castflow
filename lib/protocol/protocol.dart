import 'dart:convert';

import '../core/constants.dart';
import '../core/models.dart';
import '../security/security.dart';

class Envelope {
  Envelope({
    required this.type,
    required this.data,
    String? id,
    this.replyTo,
    this.version = CastFlowProtocol.version,
    DateTime? timestamp,
  }) : id = id ?? secureId('m'),
       timestamp = timestamp ?? DateTime.now();

  final int version;
  final String type;
  final String id;
  final String? replyTo;
  final DateTime timestamp;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
    'v': version,
    'type': type,
    'id': id,
    'ts': timestamp.millisecondsSinceEpoch,
    if (replyTo != null) 're': replyTo,
    'data': data,
  };

  String encode() => jsonEncode(toJson());

  factory Envelope.decode(Object? raw) {
    final Object? decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map) throw const FormatException('Enveloppe invalide');
    final json = decoded.cast<String, Object?>();
    final type = json['type'];
    final id = json['id'];
    if (type is! String || type.isEmpty || id is! String || id.isEmpty) {
      throw const FormatException('Type ou identifiant manquant');
    }
    final rawData = json['data'];
    return Envelope(
      version: (json['v'] as num?)?.toInt() ?? 0,
      type: type,
      id: id,
      replyTo: json['re']?.toString(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (json['ts'] as num?)?.toInt() ?? 0,
      ),
      data: rawData is Map
          ? rawData.cast<String, Object?>()
          : const <String, Object?>{},
    );
  }

  Envelope reply(String replyType, Map<String, Object?> replyData) =>
      Envelope(type: replyType, data: replyData, replyTo: id);
}

String buildConnectUrl({
  required String host,
  required int httpPort,
  required int wsPort,
  required DeviceInfo device,
  String? pin,
}) {
  return Uri(
    scheme: 'castflow',
    host: 'connect',
    queryParameters: {
      'host': host,
      'http': '$httpPort',
      'ws': '$wsPort',
      'id': device.id,
      'name': device.name,
      'kind': device.kind,
      'platform': device.platform,
      'pin': ?pin,
      if (device.fingerprint.isNotEmpty) 'fp': device.fingerprint,
    },
  ).toString();
}

RemoteDevice? parseConnectUrl(String raw) {
  final start = raw.indexOf('castflow://');
  if (start < 0) return null;
  final uri = Uri.tryParse(raw.substring(start));
  if (uri == null || uri.host != 'connect') return null;
  final query = uri.queryParameters;
  final host = query['host'];
  final id = query['id'];
  final http =
      int.tryParse(query['http'] ?? '') ?? CastFlowProtocol.defaultHttpPort;
  final ws = int.tryParse(query['ws'] ?? '') ?? CastFlowProtocol.defaultWsPort;
  if (host == null || host.isEmpty || id == null || id.isEmpty) return null;
  if (http < 1 || http > 65535 || ws < 1 || ws > 65535) return null;
  return RemoteDevice(
    id: id,
    name: query['name'] ?? host,
    platform: query['platform'] ?? 'unknown',
    kind: query['kind'] ?? 'desktop',
    fingerprint: query['fp'] ?? '',
    host: host,
    httpPort: http,
    wsPort: ws,
    requiresPin: query.containsKey('pin'),
    source: 'qr',
  );
}

String? pinFromConnectUrl(String raw) {
  final start = raw.indexOf('castflow://');
  if (start < 0) return null;
  return Uri.tryParse(raw.substring(start))?.queryParameters['pin'];
}
