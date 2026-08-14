import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';
import '../core/models.dart';
import '../protocol/protocol.dart';
import '../security/file_hash.dart';
import '../security/security.dart';

class CastFlowClient {
  CastFlowClient(this.device);

  final DeviceInfo device;
  RemoteDevice? peer;
  WebSocket? _socket;
  String _sessionToken = '';
  String _nonce = '';
  final Map<String, Completer<Envelope>> _pending = {};
  final StreamController<IncomingOffer> _offerController =
      StreamController<IncomingOffer>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  Stream<IncomingOffer> get offers => _offerController.stream;
  Stream<bool> get connectionChanges => _connectionController.stream;
  bool get connected => _socket?.readyState == WebSocket.open;
  bool get authenticated => connected && _sessionToken.isNotEmpty;
  String get sessionToken => _sessionToken;

  static Future<RemoteDevice?> probe(
    String host, {
    int port = CastFlowProtocol.defaultHttpPort,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse('http://$host:$port/info'));
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      final json = jsonDecode(await utf8.decodeStream(response));
      if (json is! Map || json['device'] is! Map) return null;
      final device = DeviceInfo.fromJson(
        (json['device'] as Map).cast<String, Object?>(),
      );
      return RemoteDevice(
        id: device.id,
        name: device.name,
        platform: device.platform,
        kind: device.kind,
        fingerprint: device.fingerprint,
        host: host,
        httpPort: (json['http'] as num?)?.toInt() ?? port,
        wsPort: (json['ws'] as num?)?.toInt() ?? CastFlowProtocol.defaultWsPort,
        requiresPin: json['requiresPin'] == true,
        secure: json['secure'] == true,
        source: 'manual',
      );
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> connect(
    RemoteDevice target, {
    String? pin,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    await disconnect();
    peer = target;
    final socket = await WebSocket.connect(
      'ws://${target.host}:${target.wsPort}',
    ).timeout(timeout);
    _socket = socket;
    socket.listen(
      _handleMessage,
      onDone: _handleClosed,
      onError: (_) => _handleClosed(),
      cancelOnError: true,
    );
    final hello = await request(
      Envelope(type: 'HELLO', data: {'device': device.toJson()}),
      timeout: timeout,
    );
    if (hello.type != 'HELLO_ACK') throw StateError('Handshake invalide');
    _nonce = hello.data['nonce']?.toString() ?? '';
    final session = hello.data['sessionToken']?.toString();
    if (session != null && session.isNotEmpty) _sessionToken = session;
    final requiresPin = hello.data['requiresPin'] == true;
    if (requiresPin && pin != null) {
      return authenticate(pin, hello.data['nonce']?.toString() ?? '');
    }
    _connectionController.add(true);
    return !requiresPin;
  }

  Future<bool> authenticate(String pin, [String? nonce]) async {
    final challenge = (nonce == null || nonce.isEmpty) ? _nonce : nonce;
    if (challenge.isEmpty) {
      throw StateError('Challenge PIN absent; reconnectez-vous');
    }
    final response = await request(
      Envelope(
        type: 'AUTH',
        data: {'proof': pinProof(pin, challenge, device.id)},
      ),
    );
    if (response.type != 'AUTH_OK') return false;
    _sessionToken = response.data['sessionToken']?.toString() ?? '';
    _connectionController.add(true);
    return _sessionToken.isNotEmpty;
  }

  Future<Envelope> request(
    Envelope message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw StateError('Client non connecté');
    }
    final completer = Completer<Envelope>();
    _pending[message.id] = completer;
    socket.add(message.encode());
    try {
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(message.id);
    }
  }

  void _handleMessage(Object? raw) {
    if (raw is! String) return;
    Envelope message;
    try {
      message = Envelope.decode(raw);
    } on FormatException {
      return;
    }
    final replyTo = message.replyTo;
    if (replyTo != null) {
      _pending[replyTo]?.complete(message);
    }
    if (message.type == 'OFFER') {
      final rawFiles = message.data['files'];
      if (rawFiles is List) {
        final files = rawFiles
            .whereType<Map>()
            .map((item) => OfferedFile.fromJson(item.cast<String, Object?>()))
            .toList();
        _offerController.add(
          IncomingOffer(
            transferId: message.data['transferId']?.toString() ?? '',
            totalSize: (message.data['totalSize'] as num?)?.toInt() ?? 0,
            files: files,
          ),
        );
      }
    }
  }

  void _handleClosed() {
    _sessionToken = '';
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Connexion interrompue'));
      }
    }
    _pending.clear();
    if (!_connectionController.isClosed) _connectionController.add(false);
  }

  Future<String> sendFiles(
    List<LocalFile> input, {
    void Function(int sent, int total)? onProgress,
  }) async {
    if (!authenticated) throw StateError('Authentification requise');
    if (input.isEmpty) throw ArgumentError('Aucun fichier sélectionné');
    final files = <LocalFile>[];
    for (final file in input) {
      files.add(
        file.hash == null
            ? file.copyWith(hash: await hashFile(file.path))
            : file,
      );
    }
    final transferId = secureId('t');
    final response = await request(
      Envelope(
        type: 'TRANSFER_REQUEST',
        data: {
          'transferId': transferId,
          'files': files.map((file) => file.toManifest()).toList(),
          'totalSize': files.fold<int>(0, (sum, file) => sum + file.size),
        },
      ),
      timeout: const Duration(minutes: 2),
    );
    if (response.type == 'TRANSFER_REJECT') {
      throw StateError(
        response.data['reason']?.toString() ?? 'Transfert refusé',
      );
    }
    if (response.type != 'TRANSFER_ACCEPT') {
      throw StateError(
        response.data['message']?.toString() ?? 'Réponse inattendue',
      );
    }
    final rawTokens = response.data['tokens'];
    if (rawTokens is! Map) throw StateError('Jetons de transfert absents');
    final tokens = rawTokens.cast<String, Object?>();
    final total = files.fold<int>(0, (sum, file) => sum + file.size);
    var completed = 0;
    for (final file in files) {
      final token = tokens[file.id]?.toString();
      if (token == null) throw StateError('Jeton absent pour ${file.name}');
      await _uploadFile(
        transferId,
        file,
        token,
        onProgress: (sent) => onProgress?.call(completed + sent, total),
      );
      completed += file.size;
    }
    onProgress?.call(total, total);
    return transferId;
  }

  Future<void> _uploadFile(
    String transferId,
    LocalFile file,
    String token, {
    void Function(int sent)? onProgress,
  }) async {
    final target = peer!;
    final uri = Uri.parse(
      'http://${target.host}:${target.httpPort}/upload/$transferId/${file.id}',
    );
    var offset = 0;
    final headClient = HttpClient();
    try {
      final head = await headClient.openUrl('HEAD', uri);
      head.headers.set('X-CastFlow-Token', token);
      final response = await head.close();
      if (response.statusCode == 200) {
        offset =
            int.tryParse(response.headers.value('X-Received-Bytes') ?? '') ?? 0;
      }
      await response.drain<void>();
    } on Object {
      offset = 0;
    } finally {
      headClient.close(force: true);
    }
    if (offset < 0 || offset > file.size) offset = 0;

    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers
        ..set('X-CastFlow-Token', token)
        ..set('X-Offset', offset)
        ..contentLength = file.size - offset;
      var sent = offset;
      await request.addStream(
        File(file.path).openRead(offset).map((chunk) {
          sent += chunk.length;
          onProgress?.call(sent);
          return chunk;
        }),
      );
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      if (response.statusCode >= 400) {
        String message = 'Envoi échoué (${response.statusCode})';
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map && decoded['message'] != null) {
            message = decoded['message'].toString();
          }
        } on FormatException {
          // Conserver le message HTTP générique.
        }
        throw StateError(message);
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<IncomingOffer> loadOffer(String transferId) async {
    final target = peer!;
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://${target.host}:${target.httpPort}/offer/$transferId'),
      );
      request.headers.set('X-CastFlow-Session', _sessionToken);
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      if (response.statusCode != 200) {
        throw StateError('Offre introuvable (${response.statusCode})');
      }
      final json = jsonDecode(body) as Map<String, Object?>;
      final files = (json['files'] as List)
          .whereType<Map>()
          .map((item) => OfferedFile.fromJson(item.cast<String, Object?>()))
          .toList();
      return IncomingOffer(
        transferId: transferId,
        totalSize: (json['totalSize'] as num?)?.toInt() ?? 0,
        files: files,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<String>> receiveOffer(
    IncomingOffer summary,
    String targetDirectory, {
    void Function(int received, int total)? onProgress,
  }) async {
    final offer = await loadOffer(summary.transferId);
    await Directory(targetDirectory).create(recursive: true);
    final saved = <String>[];
    var completed = 0;
    for (final file in offer.files) {
      final destination = await _uniquePath(
        targetDirectory,
        sanitizeFileName(file.name),
      );
      await _downloadFile(
        offer.transferId,
        file,
        destination,
        onProgress: (received) =>
            onProgress?.call(completed + received, offer.totalSize),
      );
      completed += file.size;
      saved.add(destination);
    }
    return saved;
  }

  Future<void> _downloadFile(
    String transferId,
    OfferedFile file,
    String destination, {
    void Function(int received)? onProgress,
  }) async {
    final target = peer!;
    final temporary = '$destination.cfpart';
    final partial = File(temporary);
    final offset = await partial.exists() ? await partial.length() : 0;
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse(
          'http://${target.host}:${target.httpPort}/download/$transferId/${file.id}',
        ),
      );
      request.headers
        ..set('X-CastFlow-Token', file.token)
        ..set('X-CastFlow-Session', _sessionToken);
      if (offset > 0 && offset < file.size) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      }
      final response = await request.close();
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.drain<void>();
        throw StateError('Téléchargement échoué (${response.statusCode})');
      }
      final output = partial.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      var received = offset;
      await for (final chunk in response) {
        output.add(chunk);
        received += chunk.length;
        onProgress?.call(received);
      }
      await output.flush();
      await output.close();
      if (received != file.size) throw StateError('Téléchargement incomplet');
      final actualHash = await hashFile(temporary);
      if (!hashMatches(file.hash, actualHash)) {
        await partial.delete();
        throw StateError('Intégrité invalide pour ${file.name}');
      }
      await partial.rename(destination);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _uniquePath(String directory, String name) async {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    var index = 0;
    while (true) {
      final candidateName = index == 0 ? name : '$base ($index)$extension';
      final candidate = '$directory${Platform.pathSeparator}$candidateName';
      if (!await File(candidate).exists() &&
          !await File('$candidate.cfpart').exists()) {
        return candidate;
      }
      index++;
    }
  }

  Future<void> cancel(String transferId) async {
    if (!authenticated) return;
    final target = peer!;
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse(
          'http://${target.host}:${target.httpPort}/cancel/$transferId',
        ),
      );
      request.headers.set('X-CastFlow-Session', _sessionToken);
      await (await request.close()).drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> disconnect() async {
    await _socket?.close();
    _socket = null;
    peer = null;
    _handleClosed();
  }

  Future<void> dispose() async {
    await disconnect();
    await _offerController.close();
    await _connectionController.close();
  }
}
