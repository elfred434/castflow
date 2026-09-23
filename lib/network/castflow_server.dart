import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/constants.dart';
import '../core/models.dart';
import '../protocol/protocol.dart';
import '../remote/control_frame.dart';
import '../remote/control_protocol.dart';
import '../remote/control_session.dart';
import '../remote/transport_identity.dart';
import '../remote/trust_protocol.dart';
import '../remote/trusted_peer_store.dart';
import '../security/file_hash.dart';
import '../security/security.dart';

class CastFlowServer {
  CastFlowServer({
    required this.device,
    required this.downloadDirectory,
    this.pin,
    this.autoAccept = false,
    this.controlCapabilities = const ControlCapabilities(values: {}),
    this.transportIdentity,
    this.trustedPeers,
    this.inputInjector,
    this.frameProvider,
  }) : _controlSessions = ControlSessionCoordinator(
         localDeviceId: device.id,
         localCapabilities: controlCapabilities,
       );

  final DeviceInfo device;
  String downloadDirectory;
  String? pin;
  bool autoAccept;
  final ControlCapabilities controlCapabilities;
  final TransportIdentity? transportIdentity;
  final TrustedPeerStore? trustedPeers;
  final Future<void> Function(RemoteInputEvent event)? inputInjector;
  final Future<ControlFramePayload> Function(int maxWidth, int maxHeight)?
  frameProvider;
  final ControlSessionCoordinator _controlSessions;

  bool get secureTransport => transportIdentity != null;

  HttpServer? _httpServer;
  HttpServer? _wsServer;
  int? httpPort;
  int? wsPort;

  final Map<String, _TransferSession> _transfers = {};
  final Set<_ClientSession> _clients = {};
  final Map<String, _PinGuard> _pinGuards = {};
  final Set<String> _reservedFinalPaths = {};
  final TrustChallengeRegistry _trustChallenges = TrustChallengeRegistry();
  final Map<String, _PendingTrustRequest> _pendingTrust = {};
  final Map<String, _PendingControlRequest> _pendingControl = {};

  final StreamController<TransferSnapshot> _transferController =
      StreamController<TransferSnapshot>.broadcast();
  final StreamController<TransferSnapshot> _incomingController =
      StreamController<TransferSnapshot>.broadcast();
  final StreamController<DeviceInfo> _peerController =
      StreamController<DeviceInfo>.broadcast();
  final StreamController<IncomingTrustRequest> _trustRequestController =
      StreamController<IncomingTrustRequest>.broadcast();
  final StreamController<IncomingControlRequest> _controlRequestController =
      StreamController<IncomingControlRequest>.broadcast();

  Stream<TransferSnapshot> get transfers => _transferController.stream;
  Stream<TransferSnapshot> get incomingTransfers => _incomingController.stream;
  Stream<DeviceInfo> get connectedPeers => _peerController.stream;
  Stream<IncomingTrustRequest> get trustRequests =>
      _trustRequestController.stream;
  Stream<IncomingControlRequest> get controlRequests =>
      _controlRequestController.stream;
  Stream<ControlSessionSnapshot> get controlSessionChanges =>
      _controlSessions.changes;

  ControlCapabilities? controlCapabilitiesFor(String deviceId) {
    for (final client in _clients) {
      if (client.device?.id == deviceId) return client.controlCapabilities;
    }
    return null;
  }

  List<TransferSnapshot> get transferHistory {
    final result = _transfers.values.map(_snapshot).toList();
    result.sort((left, right) => right.startedAt.compareTo(left.startedAt));
    return result;
  }

  Future<void> start({
    int preferredHttpPort = CastFlowProtocol.defaultHttpPort,
    int preferredWsPort = CastFlowProtocol.defaultWsPort,
  }) async {
    if (_httpServer != null) return;
    final tlsIdentity = transportIdentity;
    if (tlsIdentity != null && device.fingerprint != tlsIdentity.fingerprint) {
      throw StateError('Empreinte TLS différente de l’identité annoncée');
    }
    await Directory(downloadDirectory).create(recursive: true);
    _httpServer = await _bindFrom(preferredHttpPort);
    httpPort = _httpServer!.port;
    _httpServer!.listen(_handleHttpSafely);

    try {
      _wsServer = tlsIdentity == null
          ? await _bindFrom(preferredWsPort)
          : await _bindSecureFrom(preferredWsPort, tlsIdentity);
      wsPort = _wsServer!.port;
      _wsServer!.listen(_handleWebSocketUpgrade);
    } catch (_) {
      await _httpServer?.close(force: true);
      _httpServer = null;
      httpPort = null;
      rethrow;
    }
  }

  Future<HttpServer> _bindFrom(int preferred) async {
    if (preferred == 0) {
      return HttpServer.bind(InternetAddress.anyIPv4, 0, shared: true);
    }
    Object? lastError;
    for (var candidate = preferred; candidate < preferred + 20; candidate++) {
      try {
        return await HttpServer.bind(
          InternetAddress.anyIPv4,
          candidate,
          shared: true,
        );
      } on SocketException catch (error) {
        lastError = error;
      }
    }
    throw SocketException(
      'Aucun port disponible près de $preferred: $lastError',
    );
  }

  Future<HttpServer> _bindSecureFrom(
    int preferred,
    TransportIdentity identity,
  ) async {
    if (preferred == 0) {
      return HttpServer.bindSecure(
        InternetAddress.anyIPv4,
        0,
        identity.createServerContext(),
        shared: true,
      );
    }
    Object? lastError;
    for (var candidate = preferred; candidate < preferred + 20; candidate++) {
      try {
        return await HttpServer.bindSecure(
          InternetAddress.anyIPv4,
          candidate,
          identity.createServerContext(),
          shared: true,
        );
      } on SocketException catch (error) {
        lastError = error;
      }
    }
    throw SocketException(
      'Aucun port TLS disponible près de $preferred: $lastError',
    );
  }

  Future<void> stop() async {
    for (final client in _clients.toList()) {
      await client.socket.close();
    }
    _clients.clear();
    _pendingTrust.clear();
    for (final pending in _pendingControl.values) {
      pending.cancelTimers();
    }
    _pendingControl.clear();
    _trustChallenges.clear();
    await _wsServer?.close(force: true);
    await _httpServer?.close(force: true);
    _wsServer = null;
    _httpServer = null;
    wsPort = null;
    httpPort = null;
  }

  Future<void> dispose() async {
    await stop();
    await _transferController.close();
    await _incomingController.close();
    await _peerController.close();
    await _trustRequestController.close();
    await _controlRequestController.close();
    await _controlSessions.dispose();
  }

  Future<void> _handleHttpSafely(HttpRequest request) async {
    try {
      await _handleHttp(request);
    } on _HttpProblem catch (problem) {
      try {
        await _error(
          request.response,
          problem.status,
          problem.code,
          problem.message,
        );
      } on StateError {
        await request.response.close();
      }
    } on Object catch (error) {
      try {
        await _error(request.response, 500, 'INTERNAL', error.toString());
      } on StateError {
        await request.response.close();
      }
    }
  }

  Future<void> _handleHttp(HttpRequest request) async {
    _cors(request.response);
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      return request.response.close();
    }

    final segments = request.uri.pathSegments;
    if (request.method == 'GET' &&
        segments.length == 1 &&
        segments[0] == 'info') {
      return _json(request.response, 200, {
        'v': CastFlowProtocol.version,
        'device': device.toJson(),
        'http': httpPort,
        'ws': wsPort,
        'secure': secureTransport,
        'requiresPin': pin != null,
      });
    }

    if (segments.length == 3 && segments[0] == 'upload') {
      final transfer = _transfers[segments[1]];
      final entry = transfer?.files[segments[2]];
      if (transfer == null ||
          entry == null ||
          transfer.direction != TransferDirection.receive) {
        throw const _HttpProblem(404, 'UNKNOWN_FILE', 'Fichier inconnu');
      }
      _validateFileToken(request, entry);
      if (transfer.state != TransferState.transferring) {
        throw const _HttpProblem(403, 'NOT_ACCEPTED', 'Transfert non accepté');
      }
      if (request.method == 'HEAD') {
        request.response.headers.set('X-Received-Bytes', entry.transferred);
        request.response.statusCode = 200;
        return request.response.close();
      }
      if (request.method == 'POST') {
        return _receiveFile(request, transfer, entry);
      }
      throw const _HttpProblem(
        405,
        'METHOD_NOT_ALLOWED',
        'Méthode non supportée',
      );
    }

    if (request.method == 'GET' &&
        segments.length == 2 &&
        segments[0] == 'offer') {
      final sessionToken = _requireSession(request);
      final transfer = _transfers[segments[1]];
      if (transfer == null ||
          transfer.direction != TransferDirection.send ||
          !transfer.allowedSessions.contains(sessionToken)) {
        throw const _HttpProblem(404, 'UNKNOWN_FILE', 'Offre inconnue');
      }
      return _json(request.response, 200, {
        'transferId': transfer.id,
        'totalSize': transfer.totalBytes,
        'files': transfer.files.values
            .map((entry) => entry.offeredFile.toJson())
            .toList(),
      });
    }

    if (request.method == 'GET' &&
        segments.length == 3 &&
        segments[0] == 'download') {
      _requireSession(request);
      return _sendFile(request, segments[1], segments[2]);
    }

    if (request.method == 'POST' &&
        segments.length == 2 &&
        segments[0] == 'cancel') {
      final sessionToken = _requireSession(request);
      final transfer = _transfers[segments[1]];
      if (transfer == null ||
          (transfer.client?.sessionToken != sessionToken &&
              !transfer.allowedSessions.contains(sessionToken))) {
        throw const _HttpProblem(404, 'UNKNOWN_FILE', 'Transfert inconnu');
      }
      cancelTransfer(transfer.id, reason: 'Annulé par le pair');
      return _json(request.response, 200, {'ok': true});
    }

    throw const _HttpProblem(404, 'NOT_FOUND', 'Route inconnue');
  }

  void _validateFileToken(HttpRequest request, _FileEntry entry) {
    final token = request.headers.value('X-CastFlow-Token');
    if (token == null || token.isEmpty) {
      throw const _HttpProblem(401, 'NO_TOKEN', 'Jeton manquant');
    }
    if (!constantTimeEquals(token, entry.token)) {
      throw const _HttpProblem(401, 'BAD_TOKEN', 'Jeton invalide');
    }
    if (entry.tokenExpiresAt.isBefore(DateTime.now()) || entry.tokenConsumed) {
      throw const _HttpProblem(
        401,
        'EXPIRED_TOKEN',
        'Jeton expiré ou déjà utilisé',
      );
    }
  }

  String _requireSession(HttpRequest request) {
    final token = request.headers.value('X-CastFlow-Session');
    if (token == null ||
        !_clients.any(
          (client) =>
              client.authenticated &&
              constantTimeEquals(client.sessionToken, token),
        )) {
      throw const _HttpProblem(
        401,
        'AUTH_REQUIRED',
        'Session authentifiée requise',
      );
    }
    return token;
  }

  Future<void> _receiveFile(
    HttpRequest request,
    _TransferSession transfer,
    _FileEntry entry,
  ) async {
    final offset = int.tryParse(request.headers.value('X-Offset') ?? '0');
    if (offset == null || offset != entry.transferred) {
      throw _HttpProblem(
        409,
        'OFFSET_MISMATCH',
        'Offset attendu ${entry.transferred}',
      );
    }
    final remaining = entry.size - offset;
    if (request.contentLength > remaining) {
      throw const _HttpProblem(413, 'TOO_LARGE', 'Taille annoncée dépassée');
    }

    final temporary = File(entry.temporaryPath!);
    await temporary.parent.create(recursive: true);
    final output = await temporary.open(
      mode: offset == 0 ? FileMode.write : FileMode.append,
    );
    var written = offset;
    try {
      await for (final chunk in request) {
        if (written + chunk.length > entry.size) {
          throw const _HttpProblem(413, 'TOO_LARGE', 'Taille dépassée');
        }
        await output.writeFrom(chunk);
        written += chunk.length;
        entry.transferred = written;
        _emitTransfer(transfer);
      }
      await output.flush();
    } finally {
      await output.close();
    }

    if (entry.transferred != entry.size) {
      throw const _HttpProblem(
        400,
        'INCOMPLETE',
        'Transfert incomplet, reprise possible',
      );
    }

    final actualHash = await hashFile(temporary.path);
    if (!hashMatches(entry.expectedHash, actualHash)) {
      await temporary.delete().catchError((_) => temporary);
      entry.transferred = 0;
      throw const _HttpProblem(
        422,
        'HASH_MISMATCH',
        'Intégrité du fichier invalide',
      );
    }

    final finalPath = await _reserveUniquePath(entry.name);
    try {
      await temporary.rename(finalPath);
      entry.finalPath = finalPath;
    } finally {
      _reservedFinalPaths.remove(finalPath);
    }
    entry.hash = actualHash;
    entry.done = true;
    entry.tokenConsumed = true;

    if (transfer.files.values.every((file) => file.done)) {
      transfer.state = TransferState.completed;
      _sendToClient(
        transfer.client,
        Envelope(
          type: 'TRANSFER_COMPLETE',
          data: {
            'transferId': transfer.id,
            'files': transfer.files.values.map((file) => file.name).toList(),
            'durationMs': DateTime.now()
                .difference(transfer.startedAt)
                .inMilliseconds,
          },
        ),
      );
    }
    _emitTransfer(transfer);
    await _json(request.response, 200, {
      'ok': true,
      'received': entry.transferred,
      'hash': actualHash,
    });
  }

  Future<String> _reserveUniquePath(String name) async {
    final directory = Directory(downloadDirectory);
    await directory.create(recursive: true);
    final extensionIndex = name.lastIndexOf('.');
    final base = extensionIndex > 0 ? name.substring(0, extensionIndex) : name;
    final extension = extensionIndex > 0 ? name.substring(extensionIndex) : '';
    var index = 0;
    while (true) {
      final candidateName = index == 0 ? name : '$base ($index)$extension';
      final candidate =
          '${directory.path}${Platform.pathSeparator}$candidateName';
      if (!_reservedFinalPaths.contains(candidate) &&
          !await File(candidate).exists()) {
        _reservedFinalPaths.add(candidate);
        return candidate;
      }
      index++;
    }
  }

  Future<void> _sendFile(
    HttpRequest request,
    String transferId,
    String fileId,
  ) async {
    final transfer = _transfers[transferId];
    final entry = transfer?.files[fileId];
    if (transfer == null ||
        entry == null ||
        transfer.direction != TransferDirection.send ||
        entry.sourcePath == null) {
      throw const _HttpProblem(404, 'UNKNOWN_FILE', 'Fichier inconnu');
    }
    _validateFileToken(request, entry);
    final file = File(entry.sourcePath!);
    if (!await file.exists()) {
      throw const _HttpProblem(404, 'UNKNOWN_FILE', 'Fichier absent du disque');
    }
    final size = await file.length();
    final range = _parseRange(
      request.headers.value(HttpHeaders.rangeHeader),
      size,
    );
    final start = range.$1;
    final endExclusive = range.$2;
    final partial = start != 0 || endExclusive != size;

    request.response.statusCode = partial
        ? HttpStatus.partialContent
        : HttpStatus.ok;
    request.response.headers
      ..set(HttpHeaders.contentTypeHeader, entry.mime)
      ..set(HttpHeaders.contentLengthHeader, endExclusive - start)
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(
        'Content-Disposition',
        "attachment; filename*=UTF-8''${Uri.encodeComponent(entry.name)}",
      );
    if (partial) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${endExclusive - 1}/$size',
      );
    }

    await request.response.addStream(file.openRead(start, endExclusive));
    entry.transferred = max(entry.transferred, endExclusive);
    if (start == 0 && endExclusive == size) {
      entry.done = true;
      entry.tokenConsumed = true;
      if (transfer.files.values.every((item) => item.done)) {
        transfer.state = TransferState.completed;
      }
    }
    _emitTransfer(transfer);
    await request.response.close();
  }

  (int, int) _parseRange(String? header, int size) {
    if (header == null) return (0, size);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header);
    if (match == null || size == 0) {
      throw const _HttpProblem(416, 'BAD_RANGE', 'Plage HTTP invalide');
    }
    final first = match.group(1)!;
    final second = match.group(2)!;
    int start;
    int endInclusive;
    if (first.isEmpty) {
      final suffix = int.tryParse(second);
      if (suffix == null || suffix <= 0) {
        throw const _HttpProblem(416, 'BAD_RANGE', 'Plage HTTP invalide');
      }
      start = max(0, size - suffix);
      endInclusive = size - 1;
    } else {
      start = int.tryParse(first) ?? -1;
      endInclusive = second.isEmpty ? size - 1 : int.tryParse(second) ?? -1;
    }
    if (start < 0 ||
        start >= size ||
        endInclusive < start ||
        endInclusive >= size) {
      throw const _HttpProblem(416, 'BAD_RANGE', 'Plage HTTP hors fichier');
    }
    return (start, endInclusive + 1);
  }

  Future<void> _handleWebSocketUpgrade(HttpRequest request) async {
    if (request.uri.path != '/' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      return request.response.close();
    }
    final socket = await WebSocketTransformer.upgrade(request);
    final client = _ClientSession(
      socket: socket,
      address: request.connectionInfo?.remoteAddress.address ?? 'unknown',
    );
    _clients.add(client);
    socket.listen(
      (raw) => _handleMessage(client, raw),
      onDone: () => _removeClient(client),
      onError: (_) => _removeClient(client),
      cancelOnError: true,
    );
  }

  void _removeClient(_ClientSession client) {
    _clients.remove(client);
    _pendingTrust.removeWhere((_, pending) => pending.client == client);
    final controlIds = _pendingControl.entries
        .where((entry) => entry.value.client == client)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final id in controlIds) {
      final state = _controlSessions.find(id)?.state;
      if (state == ControlSessionState.awaitingLocalApproval ||
          state == ControlSessionState.active ||
          state == ControlSessionState.paused) {
        _controlSessions.stop(id, reason: 'Connexion interrompue');
      }
      _pendingControl.remove(id)?.cancelTimers();
    }
  }

  Future<void> _handleMessage(_ClientSession client, Object? raw) async {
    if (raw is! String || raw.length > CastFlowProtocol.maxManifestBytes) {
      await client.socket.close(
        WebSocketStatus.messageTooBig,
        'Message trop volumineux',
      );
      return;
    }
    Envelope message;
    try {
      message = Envelope.decode(raw);
    } on FormatException {
      return;
    }
    if (message.version != CastFlowProtocol.version) {
      return _sendToClient(
        client,
        message.reply('ERROR', {
          'code': 'VERSION_MISMATCH',
          'message': 'Version de protocole non supportée',
        }),
      );
    }

    switch (message.type) {
      case 'PING':
        _sendToClient(client, message.reply('PONG', const {}));
      case 'HELLO':
        final rawDevice = message.data['device'];
        if (rawDevice is! Map) return;
        client.device = DeviceInfo.fromJson(rawDevice.cast<String, Object?>());
        final rawCapabilities = message.data['controlCapabilities'];
        client.controlCapabilities = rawCapabilities is Map
            ? ControlCapabilities.fromJson(
                rawCapabilities.cast<String, Object?>(),
              )
            : const ControlCapabilities(values: {});
        client.authenticated = pin == null;
        if (client.authenticated) client.sessionToken = secureId('session');
        TrustChallenge? trustChallenge;
        final peerDevice = client.device;
        final trustStore = trustedPeers;
        if (!client.authenticated &&
            secureTransport &&
            peerDevice != null &&
            trustStore != null) {
          final credential = await trustStore.credential(peerDevice.id);
          if (credential != null &&
              constantTimeEquals(
                credential.peer.fingerprint,
                peerDevice.fingerprint,
              )) {
            trustChallenge = _trustChallenges.issue(
              requesterDeviceId: peerDevice.id,
              targetDeviceId: device.id,
            );
          }
        }
        _sendToClient(
          client,
          message.reply('HELLO_ACK', {
            'device': device.toJson(),
            'nonce': client.nonce,
            'requiresPin': pin != null,
            'trusted': false,
            if (trustChallenge != null)
              'trustChallenge': trustChallenge.toJson(),
            'controlCapabilities': controlCapabilities.toJson(),
            if (client.authenticated) 'sessionToken': client.sessionToken,
          }),
        );
        if (client.device != null) _peerController.add(client.device!);
      case 'AUTH':
        _authenticate(client, message);
      case ControlMessageType.trustProof:
        await _authenticateTrusted(client, message);
      case ControlMessageType.trustRequest:
        _requestTrust(client, message);
      case ControlMessageType.request:
        await _requestControl(client, message);
      case ControlMessageType.input:
        await _handleControlInput(client, message);
      case ControlMessageType.pause:
        _changeControlState(client, message, pause: true);
      case ControlMessageType.resume:
        _changeControlState(client, message, pause: false);
      case ControlMessageType.stop:
        _stopControl(client, message);
      case ControlMessageType.capabilities:
        if (!client.authenticated) {
          _sendToClient(
            client,
            message.reply(ControlMessageType.error, {
              'code': 'AUTH_REQUIRED',
              'message': 'Authentification requise',
            }),
          );
          return;
        }
        _sendToClient(
          client,
          message.reply(
            ControlMessageType.capabilities,
            controlCapabilities.toJson(),
          ),
        );
      case 'TRANSFER_REQUEST':
        if (!client.authenticated) {
          _sendToClient(
            client,
            message.reply('ERROR', {
              'code': 'AUTH_REQUIRED',
              'message': 'Authentification requise',
            }),
          );
          return;
        }
        await _createIncomingTransfer(client, message);
      case 'TRANSFER_CANCEL':
        if (!client.authenticated) return;
        cancelTransfer(
          message.data['transferId']?.toString() ?? '',
          reason: message.data['reason']?.toString() ?? 'Annulé par le pair',
        );
    }
  }

  Future<void> _requestControl(_ClientSession client, Envelope message) async {
    final peer = client.device;
    if (!secureTransport || !client.authenticated || peer == null) {
      _sendControlError(
        client,
        message,
        'CONTROL_UNAVAILABLE',
        'Contrôle distant sécurisé indisponible',
      );
      return;
    }
    try {
      final request = ControlRequest.fromJson(message.data);
      final needsCapture = request.requested.contains(
        ControlCapability.screenCapture,
      );
      final needsInput = request.requested.any(
        (capability) => capability != ControlCapability.screenCapture,
      );
      if ((needsCapture && frameProvider == null) ||
          (needsInput && inputInjector == null)) {
        throw StateError('Adaptateur de contrôle demandé indisponible');
      }
      final snapshot = _controlSessions.receiveRequest(
        requesterDeviceId: peer.id,
        request: request,
      );
      final incoming = IncomingControlRequest(
        id: snapshot.id,
        device: peer,
        request: request,
        createdAt: snapshot.createdAt,
      );
      final pending = _PendingControlRequest(
        request: incoming,
        client: client,
        messageId: message.id,
      );
      pending.expiryTimer = Timer(
        controlApprovalTimeout,
        () => _expireControlRequest(snapshot.id),
      );
      _pendingControl[snapshot.id] = pending;
      if (client.trustedAuthenticated) {
        final credential = await trustedPeers?.credential(peer.id);
        if (credential != null &&
            credential.peer.capabilities.containsAll(request.requested)) {
          approveControl(snapshot.id, granted: request.requested);
          return;
        }
      }
      _controlRequestController.add(incoming);
    } on Object catch (error) {
      _sendControlError(
        client,
        message,
        'CONTROL_REQUEST_INVALID',
        error.toString(),
      );
    }
  }

  void _scheduleControlFrame(
    _PendingControlRequest pending, {
    Duration delay = Duration.zero,
  }) {
    pending.frameTimer?.cancel();
    pending.frameTimer = Timer(
      delay,
      () => unawaited(_captureAndSendControlFrame(pending)),
    );
  }

  Future<void> _captureAndSendControlFrame(
    _PendingControlRequest pending,
  ) async {
    final sessionId = pending.request.id;
    if (_pendingControl[sessionId] != pending) return;
    final snapshot = _controlSessions.find(sessionId);
    if (snapshot?.state == ControlSessionState.paused) {
      _scheduleControlFrame(pending, delay: const Duration(milliseconds: 100));
      return;
    }
    if (snapshot?.state != ControlSessionState.active ||
        !snapshot!.granted.contains(ControlCapability.screenCapture)) {
      return;
    }
    final provider = frameProvider;
    if (provider == null) {
      stopControlLocally(sessionId, reason: 'Capture d’écran indisponible');
      return;
    }
    final stopwatch = Stopwatch()..start();
    try {
      final request = pending.request.request;
      final payload = await provider(request.width, request.height);
      payload.validate();
      if (_pendingControl[sessionId] != pending ||
          _controlSessions.find(sessionId)?.state !=
              ControlSessionState.active) {
        return;
      }
      pending.client.socket.add(
        ControlVideoFrame(
          sessionId: sessionId,
          sequence: pending.frameSequence++,
          capturedAt: DateTime.now().toUtc(),
          width: payload.width,
          height: payload.height,
          codec: payload.codec,
          bytes: payload.bytes,
        ).encode(),
      );
    } on Object {
      stopControlLocally(sessionId, reason: 'Capture d’écran interrompue');
      return;
    }
    stopwatch.stop();
    final interval = Duration(
      microseconds:
          Duration.microsecondsPerSecond ~/ pending.request.request.fps,
    );
    final delay = interval > stopwatch.elapsed
        ? interval - stopwatch.elapsed
        : Duration.zero;
    _scheduleControlFrame(pending, delay: delay);
  }

  void _expireControlRequest(String sessionId) {
    final pending = _pendingControl.remove(sessionId);
    if (pending == null ||
        _controlSessions.find(sessionId)?.state !=
            ControlSessionState.awaitingLocalApproval) {
      return;
    }
    const reason = 'Délai d’approbation expiré';
    _controlSessions.deny(sessionId, reason: reason);
    _sendToClient(
      pending.client,
      Envelope(
        type: ControlMessageType.deny,
        replyTo: pending.messageId,
        data: {'sessionId': sessionId, 'reason': reason},
      ),
    );
  }

  void approveControl(
    String sessionId, {
    required Set<ControlCapability> granted,
  }) {
    final pending = _pendingControl[sessionId];
    if (pending == null) return;
    try {
      final snapshot = _controlSessions.approve(sessionId, granted: granted);
      pending.cancelTimers();
      pending.controlToken = secureId('control');
      _sendToClient(
        pending.client,
        Envelope(
          type: ControlMessageType.accept,
          replyTo: pending.messageId,
          data: {
            'sessionId': snapshot.id,
            'granted': snapshot.granted
                .map((capability) => capability.name)
                .toList(growable: false),
            'controlToken': pending.controlToken,
          },
        ),
      );
      if (snapshot.granted.contains(ControlCapability.screenCapture)) {
        _scheduleControlFrame(pending);
      }
    } on Object catch (error) {
      _sendToClient(
        pending.client,
        Envelope(
          type: ControlMessageType.error,
          replyTo: pending.messageId,
          data: {
            'code': 'CONTROL_APPROVAL_INVALID',
            'message': error.toString(),
          },
        ),
      );
    }
  }

  void denyControl(
    String sessionId, {
    String reason = 'Demande refusée localement',
  }) {
    final pending = _pendingControl.remove(sessionId);
    if (pending == null) return;
    pending.cancelTimers();
    _controlSessions.deny(sessionId, reason: reason);
    _sendToClient(
      pending.client,
      Envelope(
        type: ControlMessageType.deny,
        replyTo: pending.messageId,
        data: {'sessionId': sessionId, 'reason': reason},
      ),
    );
  }

  Future<void> _handleControlInput(
    _ClientSession client,
    Envelope message,
  ) async {
    final sessionId = message.data['sessionId']?.toString() ?? '';
    final token = message.data['controlToken']?.toString() ?? '';
    final rawEvent = message.data['event'];
    final pending = _pendingControl[sessionId];
    if (pending == null ||
        pending.client != client ||
        pending.controlToken.isEmpty ||
        !constantTimeEquals(pending.controlToken, token) ||
        rawEvent is! Map) {
      _sendControlError(
        client,
        message,
        'CONTROL_SESSION_INVALID',
        'Session ou jeton de contrôle invalide',
      );
      return;
    }
    try {
      final event = RemoteInputEvent.decode(rawEvent.cast<String, Object?>());
      final snapshot = _controlSessions.find(sessionId);
      if (snapshot == null || !_eventAllowed(event, snapshot.granted)) {
        throw StateError('Capacité d’entrée non accordée');
      }
      if (!_controlSessions.acceptInputSequence(sessionId, event.sequence)) {
        throw StateError('Événement rejoué ou désordonné');
      }
      await inputInjector!(event);
      _sendToClient(
        client,
        message.reply(ControlMessageType.ready, {
          'sessionId': sessionId,
          'sequence': event.sequence,
        }),
      );
    } on Object catch (error) {
      _sendControlError(
        client,
        message,
        'CONTROL_INPUT_REJECTED',
        error.toString(),
      );
    }
  }

  bool _eventAllowed(RemoteInputEvent event, Set<ControlCapability> granted) =>
      switch (event.kind) {
        RemoteInputKind.pointerDown ||
        RemoteInputKind.pointerMove ||
        RemoteInputKind.pointerUp ||
        RemoteInputKind.scroll => granted.contains(ControlCapability.pointer),
        RemoteInputKind.keyDown ||
        RemoteInputKind.keyUp => granted.contains(ControlCapability.keyboard),
        RemoteInputKind.text => granted.contains(ControlCapability.textInput),
        RemoteInputKind.back ||
        RemoteInputKind.home ||
        RemoteInputKind.recentApps => granted.contains(
          ControlCapability.systemNavigation,
        ),
      };

  void _changeControlState(
    _ClientSession client,
    Envelope message, {
    required bool pause,
  }) {
    final sessionId = message.data['sessionId']?.toString() ?? '';
    final token = message.data['controlToken']?.toString() ?? '';
    final pending = _pendingControl[sessionId];
    if (pending == null ||
        pending.client != client ||
        pending.controlToken.isEmpty ||
        !constantTimeEquals(pending.controlToken, token)) {
      _sendControlError(
        client,
        message,
        'CONTROL_SESSION_INVALID',
        'Session de contrôle invalide',
      );
      return;
    }
    try {
      final snapshot = pause
          ? _controlSessions.pause(sessionId)
          : _controlSessions.resume(sessionId);
      if (pause) {
        pending.frameTimer?.cancel();
      } else if (snapshot.granted.contains(ControlCapability.screenCapture)) {
        _scheduleControlFrame(pending);
      }
      _sendToClient(
        client,
        message.reply(ControlMessageType.ready, {
          'sessionId': sessionId,
          'state': snapshot.state.name,
        }),
      );
    } on Object catch (error) {
      _sendControlError(
        client,
        message,
        'CONTROL_STATE_INVALID',
        error.toString(),
      );
    }
  }

  void stopControlLocally(
    String sessionId, {
    String reason = 'Session arrêtée localement',
  }) {
    final pending = _pendingControl.remove(sessionId);
    if (pending == null) return;
    pending.cancelTimers();
    _controlSessions.stop(sessionId, reason: reason);
    _sendToClient(
      pending.client,
      Envelope(
        type: ControlMessageType.stop,
        data: {'sessionId': sessionId, 'reason': reason},
      ),
    );
  }

  void _stopControl(_ClientSession client, Envelope message) {
    final sessionId = message.data['sessionId']?.toString() ?? '';
    final token = message.data['controlToken']?.toString() ?? '';
    final pending = _pendingControl[sessionId];
    if (pending == null ||
        pending.client != client ||
        pending.controlToken.isEmpty ||
        !constantTimeEquals(pending.controlToken, token)) {
      _sendControlError(
        client,
        message,
        'CONTROL_SESSION_INVALID',
        'Session de contrôle invalide',
      );
      return;
    }
    try {
      final snapshot = _controlSessions.stop(
        sessionId,
        reason: 'Arrêt demandé par le contrôleur',
      );
      _pendingControl.remove(sessionId)?.cancelTimers();
      _sendToClient(
        client,
        message.reply(ControlMessageType.ready, {
          'sessionId': sessionId,
          'state': snapshot.state.name,
        }),
      );
    } on Object catch (error) {
      _sendControlError(
        client,
        message,
        'CONTROL_STATE_INVALID',
        error.toString(),
      );
    }
  }

  void _sendControlError(
    _ClientSession client,
    Envelope request,
    String code,
    String message,
  ) {
    _sendToClient(
      client,
      request.reply(ControlMessageType.error, {
        'code': code,
        'message': message,
      }),
    );
  }

  Future<void> _authenticateTrusted(
    _ClientSession client,
    Envelope message,
  ) async {
    final peerDevice = client.device;
    final store = trustedPeers;
    final challengeId = message.data['challengeId']?.toString() ?? '';
    final proof = message.data['proof']?.toString() ?? '';
    final credential = peerDevice == null || store == null
        ? null
        : await store.credential(peerDevice.id);
    final valid =
        credential != null &&
        constantTimeEquals(
          credential.peer.fingerprint,
          peerDevice!.fingerprint,
        ) &&
        _trustChallenges.consume(
          challengeId: challengeId,
          requesterDeviceId: peerDevice.id,
          targetDeviceId: device.id,
          secret: credential.secret,
          proof: proof,
        );
    if (!valid) {
      _sendToClient(
        client,
        message.reply(ControlMessageType.error, {
          'code': 'TRUST_PROOF_INVALID',
          'message': 'Preuve de confiance invalide ou expirée',
        }),
      );
      return;
    }
    client.authenticated = true;
    client.trustedAuthenticated = true;
    client.sessionToken = secureId('session');
    await store!.updateLastSeen(peerDevice.id, DateTime.now());
    _sendToClient(
      client,
      message.reply(ControlMessageType.trustOk, {
        'sessionToken': client.sessionToken,
      }),
    );
  }

  void _requestTrust(_ClientSession client, Envelope message) {
    final peerDevice = client.device;
    if (!secureTransport ||
        trustedPeers == null ||
        !client.authenticated ||
        peerDevice == null) {
      _sendToClient(
        client,
        message.reply(ControlMessageType.error, {
          'code': 'TRUST_UNAVAILABLE',
          'message': 'Appairage sécurisé indisponible',
        }),
      );
      return;
    }
    final requested = <ControlCapability>{};
    final rawCapabilities = message.data['capabilities'];
    if (rawCapabilities is List) {
      for (final raw in rawCapabilities) {
        for (final capability in ControlCapability.values) {
          if (capability.name == raw?.toString() &&
              controlCapabilities.values.contains(capability)) {
            requested.add(capability);
          }
        }
      }
    }
    if (requested.isEmpty) {
      _sendToClient(
        client,
        message.reply(ControlMessageType.error, {
          'code': 'NO_CAPABILITY',
          'message': 'Aucune capacité de contrôle demandée',
        }),
      );
      return;
    }
    final request = IncomingTrustRequest(
      id: message.id,
      device: peerDevice,
      requestedCapabilities: requested,
      createdAt: DateTime.now(),
    );
    _pendingTrust[request.id] = _PendingTrustRequest(
      request: request,
      client: client,
    );
    _trustRequestController.add(request);
  }

  Future<void> approveTrust(
    String requestId, {
    required Set<ControlCapability> capabilities,
  }) async {
    final pending = _pendingTrust.remove(requestId);
    final store = trustedPeers;
    if (pending == null || store == null || capabilities.isEmpty) return;
    final granted = capabilities.intersection(
      pending.request.requestedCapabilities,
    );
    if (granted.isEmpty) return;
    final secret = generateTrustSecret();
    final now = DateTime.now().toUtc();
    final peer = pending.request.device;
    await store.approve(
      peer: TrustedPeer(
        deviceId: peer.id,
        name: peer.name,
        fingerprint: peer.fingerprint,
        approvedAt: now,
        lastSeenAt: now,
        capabilities: granted,
      ),
      secret: secret,
    );
    _sendToClient(
      pending.client,
      Envelope(
        type: ControlMessageType.trustAccept,
        replyTo: requestId,
        data: {
          'secret': secret,
          'capabilities': granted
              .map((capability) => capability.name)
              .toList(growable: false),
        },
      ),
    );
  }

  void rejectTrust(String requestId, {String reason = 'Appairage refusé'}) {
    final pending = _pendingTrust.remove(requestId);
    if (pending == null) return;
    _sendToClient(
      pending.client,
      Envelope(
        type: ControlMessageType.trustDeny,
        replyTo: requestId,
        data: {'reason': reason},
      ),
    );
  }

  void _authenticate(_ClientSession client, Envelope message) {
    final guard = _pinGuards.putIfAbsent(client.address, _PinGuard.new);
    if (guard.lockedUntil?.isAfter(DateTime.now()) == true) {
      _sendToClient(
        client,
        message.reply('AUTH_FAIL', {
          'reason': 'Trop de tentatives',
          'attemptsLeft': 0,
        }),
      );
      return;
    }
    final expected = pinProof(pin ?? '', client.nonce, client.device?.id ?? '');
    final supplied = message.data['proof']?.toString() ?? '';
    if (pin != null && constantTimeEquals(expected, supplied)) {
      client.authenticated = true;
      client.sessionToken = secureId('session');
      _pinGuards.remove(client.address);
      _sendToClient(
        client,
        message.reply('AUTH_OK', {'sessionToken': client.sessionToken}),
      );
      return;
    }
    guard.failures++;
    if (guard.failures >= CastFlowProtocol.maxPinAttempts) {
      guard.lockedUntil = DateTime.now().add(CastFlowProtocol.pinLockout);
    }
    _sendToClient(
      client,
      message.reply('AUTH_FAIL', {
        'reason': 'PIN incorrect',
        'attemptsLeft': max(
          0,
          CastFlowProtocol.maxPinAttempts - guard.failures,
        ),
      }),
    );
  }

  Future<void> _createIncomingTransfer(
    _ClientSession client,
    Envelope message,
  ) async {
    final rawFiles = message.data['files'];
    if (rawFiles is! List ||
        rawFiles.isEmpty ||
        rawFiles.length > CastFlowProtocol.maxFilesPerTransfer) {
      _sendToClient(
        client,
        message.reply('ERROR', {
          'code': 'BAD_MANIFEST',
          'message': 'Manifest vide ou trop volumineux',
        }),
      );
      return;
    }

    try {
      final transferId = sanitizeId(
        message.data['transferId'] ?? secureId('t'),
      );
      if (_transfers.containsKey(transferId)) {
        throw const FormatException('Transfert déjà existant');
      }
      final files = <String, _FileEntry>{};
      var total = 0;
      for (final raw in rawFiles) {
        if (raw is! Map) throw const FormatException('Fichier invalide');
        final json = raw.cast<String, Object?>();
        final id = sanitizeId(json['id']);
        if (files.containsKey(id)) {
          throw const FormatException('ID de fichier dupliqué');
        }
        final size = (json['size'] as num?)?.toInt() ?? -1;
        if (size < 0 || size > CastFlowProtocol.maxFileSize) {
          throw const FormatException('Taille de fichier invalide');
        }
        total += size;
        final name = sanitizeFileName(json['name']);
        files[id] = _FileEntry(
          id: id,
          name: name,
          size: size,
          mime: json['mime']?.toString() ?? guessMime(name),
          expectedHash: json['hash']?.toString(),
          token: secureId('file'),
          tokenExpiresAt: DateTime.now().add(CastFlowProtocol.tokenTtl),
          temporaryPath:
              '$downloadDirectory${Platform.pathSeparator}.$transferId-$id.cfpart',
        );
      }
      final transfer = _TransferSession(
        id: transferId,
        direction: TransferDirection.receive,
        state: autoAccept ? TransferState.transferring : TransferState.pending,
        peerName: client.device?.name ?? 'Appareil',
        totalBytes: total,
        files: files,
        client: client,
        requestId: message.id,
      );
      _transfers[transferId] = transfer;
      _emitTransfer(transfer);
      if (autoAccept) {
        _sendAcceptance(transfer);
      } else {
        _incomingController.add(_snapshot(transfer));
      }
    } on FormatException catch (error) {
      _sendToClient(
        client,
        message.reply('ERROR', {
          'code': 'BAD_MANIFEST',
          'message': error.message,
        }),
      );
    }
  }

  void acceptTransfer(String id) {
    final transfer = _transfers[id];
    if (transfer == null || transfer.state != TransferState.pending) return;
    transfer.state = TransferState.transferring;
    _sendAcceptance(transfer);
    _emitTransfer(transfer);
  }

  void _sendAcceptance(_TransferSession transfer) {
    _sendToClient(
      transfer.client,
      Envelope(
        type: 'TRANSFER_ACCEPT',
        replyTo: transfer.requestId,
        data: {
          'transferId': transfer.id,
          'tokens': {
            for (final entry in transfer.files.entries)
              entry.key: entry.value.token,
          },
        },
      ),
    );
  }

  void rejectTransfer(String id, {String reason = 'Refusé par l’utilisateur'}) {
    final transfer = _transfers[id];
    if (transfer == null || transfer.state != TransferState.pending) return;
    transfer.state = TransferState.rejected;
    transfer.error = reason;
    _sendToClient(
      transfer.client,
      Envelope(
        type: 'TRANSFER_REJECT',
        replyTo: transfer.requestId,
        data: {'transferId': id, 'reason': reason},
      ),
    );
    _emitTransfer(transfer);
  }

  void cancelTransfer(String id, {String reason = 'Annulé'}) {
    final transfer = _transfers[id];
    if (transfer == null ||
        transfer.state == TransferState.completed ||
        transfer.state == TransferState.cancelled) {
      return;
    }
    transfer.state = TransferState.cancelled;
    transfer.error = reason;
    _sendToClient(
      transfer.client,
      Envelope(
        type: 'TRANSFER_CANCEL',
        data: {'transferId': id, 'reason': reason},
      ),
    );
    _emitTransfer(transfer);
  }

  Future<String> offerFiles(List<LocalFile> localFiles) async {
    if (localFiles.isEmpty ||
        localFiles.length > CastFlowProtocol.maxFilesPerTransfer) {
      throw ArgumentError('Liste de fichiers vide ou trop volumineuse');
    }
    final id = secureId('t');
    final entries = <String, _FileEntry>{};
    var total = 0;
    for (final local in localFiles) {
      final safeId = sanitizeId(local.id);
      final actualHash = local.hash ?? await hashFile(local.path);
      entries[safeId] = _FileEntry(
        id: safeId,
        name: sanitizeFileName(local.name),
        size: local.size,
        mime: local.mime,
        expectedHash: actualHash,
        hash: actualHash,
        token: secureId('file'),
        tokenExpiresAt: DateTime.now().add(CastFlowProtocol.tokenTtl),
        sourcePath: local.path,
      );
      total += local.size;
    }
    final allowed = _clients
        .where((client) => client.authenticated)
        .map((client) => client.sessionToken)
        .toSet();
    if (allowed.isEmpty) throw StateError('Aucun pair authentifié');
    final transfer = _TransferSession(
      id: id,
      direction: TransferDirection.send,
      state: TransferState.transferring,
      peerName: 'Appareil distant',
      totalBytes: total,
      files: entries,
      allowedSessions: allowed,
    );
    _transfers[id] = transfer;
    _emitTransfer(transfer);
    for (final client in _clients.where((item) => item.authenticated)) {
      _sendToClient(
        client,
        Envelope(
          type: 'OFFER',
          data: {
            'transferId': id,
            'totalSize': total,
            'files': entries.values
                .map((entry) => entry.offeredFile.toJson(includeToken: false))
                .toList(),
          },
        ),
      );
    }
    return id;
  }

  void _sendToClient(_ClientSession? client, Envelope message) {
    if (client == null || client.socket.readyState != WebSocket.open) return;
    client.socket.add(message.encode());
  }

  void _emitTransfer(_TransferSession transfer) {
    if (!_transferController.isClosed) {
      _transferController.add(_snapshot(transfer));
    }
  }

  TransferSnapshot _snapshot(_TransferSession transfer) => TransferSnapshot(
    id: transfer.id,
    direction: transfer.direction,
    state: transfer.state,
    peerName: transfer.peerName,
    totalBytes: transfer.totalBytes,
    transferredBytes: transfer.files.values.fold(
      0,
      (sum, entry) => sum + entry.transferred,
    ),
    fileCount: transfer.files.length,
    startedAt: transfer.startedAt,
    error: transfer.error,
  );

  void _cors(HttpResponse response) {
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET,POST,HEAD,OPTIONS')
      ..set(
        'Access-Control-Allow-Headers',
        'Content-Type,X-CastFlow-Token,X-CastFlow-Session,X-Offset,Range',
      )
      ..set('Access-Control-Expose-Headers', 'X-Received-Bytes,Content-Range');
  }

  Future<void> _json(HttpResponse response, int status, Object body) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _error(
    HttpResponse response,
    int status,
    String code,
    String message,
  ) => _json(response, status, {
    'error': true,
    'code': code,
    'message': message,
  });
}

class IncomingTrustRequest {
  const IncomingTrustRequest({
    required this.id,
    required this.device,
    required this.requestedCapabilities,
    required this.createdAt,
  });

  final String id;
  final DeviceInfo device;
  final Set<ControlCapability> requestedCapabilities;
  final DateTime createdAt;
}

class _PendingTrustRequest {
  const _PendingTrustRequest({required this.request, required this.client});

  final IncomingTrustRequest request;
  final _ClientSession client;
}

class IncomingControlRequest {
  const IncomingControlRequest({
    required this.id,
    required this.device,
    required this.request,
    required this.createdAt,
  });

  final String id;
  final DeviceInfo device;
  final ControlRequest request;
  final DateTime createdAt;
}

class _PendingControlRequest {
  _PendingControlRequest({
    required this.request,
    required this.client,
    required this.messageId,
  });

  final IncomingControlRequest request;
  final _ClientSession client;
  final String messageId;
  String controlToken = '';
  Timer? expiryTimer;
  Timer? frameTimer;
  int frameSequence = 0;

  void cancelTimers() {
    expiryTimer?.cancel();
    frameTimer?.cancel();
  }
}

class _ClientSession {
  _ClientSession({required this.socket, required this.address})
    : nonce = secureId('nonce');

  final WebSocket socket;
  final String address;
  final String nonce;
  DeviceInfo? device;
  ControlCapabilities controlCapabilities = const ControlCapabilities(
    values: {},
  );
  bool authenticated = false;
  bool trustedAuthenticated = false;
  String sessionToken = '';
}

class _PinGuard {
  int failures = 0;
  DateTime? lockedUntil;
}

class _FileEntry {
  _FileEntry({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.token,
    required this.tokenExpiresAt,
    this.expectedHash,
    this.hash,
    this.temporaryPath,
    this.sourcePath,
  });

  final String id;
  final String name;
  final int size;
  final String mime;
  final String token;
  final DateTime tokenExpiresAt;
  final String? expectedHash;
  final String? temporaryPath;
  final String? sourcePath;
  String? hash;
  String? finalPath;
  int transferred = 0;
  bool done = false;
  bool tokenConsumed = false;

  OfferedFile get offeredFile => OfferedFile(
    id: id,
    name: name,
    size: size,
    mime: mime,
    token: token,
    hash: hash ?? expectedHash,
  );
}

class _TransferSession {
  _TransferSession({
    required this.id,
    required this.direction,
    required this.state,
    required this.peerName,
    required this.totalBytes,
    required this.files,
    this.client,
    this.requestId,
    Set<String>? allowedSessions,
  }) : startedAt = DateTime.now(),
       allowedSessions = allowedSessions ?? <String>{};

  final String id;
  final TransferDirection direction;
  TransferState state;
  final String peerName;
  final int totalBytes;
  final Map<String, _FileEntry> files;
  final _ClientSession? client;
  final String? requestId;
  final DateTime startedAt;
  final Set<String> allowedSessions;
  String? error;
}

class _HttpProblem implements Exception {
  const _HttpProblem(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;
}
