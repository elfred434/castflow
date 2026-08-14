import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/models.dart';
import '../network/castflow_client.dart';
import '../network/castflow_server.dart';
import '../network/discovery_service.dart';
import '../protocol/protocol.dart';
import '../security/security.dart';
import '../storage/settings_repository.dart';

final appControllerProvider = ChangeNotifierProvider<AppController>((ref) {
  final controller = AppController(SettingsRepository());
  ref.onDispose(controller.dispose);
  return controller;
});

class AppController extends ChangeNotifier {
  AppController(this._settings);

  final SettingsRepository _settings;
  DeviceInfo? identity;
  CastFlowServer? server;
  CastFlowClient? client;
  DiscoveryService? discovery;

  bool loading = true;
  String? error;
  String pin = generatePin();
  String localAddress = '127.0.0.1';
  String? downloadDirectory;
  RemoteDevice? connectedPeer;
  bool waitingForPin = false;
  int transferredBytes = 0;
  int totalTransferBytes = 0;
  IncomingOffer? incomingOffer;

  final List<RemoteDevice> devices = [];
  final List<LocalFile> selectedFiles = [];
  final List<TransferSnapshot> transferHistory = [];
  final List<TransferSnapshot> pendingTransfers = [];
  final List<DeviceInfo> inboundPeers = [];
  final List<StreamSubscription<Object?>> _subscriptions = [];

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  bool get clientConnected => client?.authenticated == true;
  bool get hasInboundPeer => inboundPeers.isNotEmpty;
  bool get transferring =>
      totalTransferBytes > 0 && transferredBytes < totalTransferBytes;

  String? get connectUrl {
    final activeServer = server;
    final currentIdentity = identity;
    if (activeServer == null || currentIdentity == null) return null;
    return buildConnectUrl(
      host: localAddress,
      httpPort: activeServer.httpPort!,
      wsPort: activeServer.wsPort!,
      device: currentIdentity,
      pin: pin,
    );
  }

  Future<void> initialize() async {
    try {
      identity = await _settings.loadIdentity();
      client = CastFlowClient(identity!);
      _subscriptions.add(
        client!.connectionChanges.listen((connected) {
          if (!connected) connectedPeer = null;
          notifyListeners();
        }),
      );
      _subscriptions.add(
        client!.offers.listen((offer) {
          incomingOffer = offer;
          notifyListeners();
        }),
      );

      if (isDesktop) {
        downloadDirectory = await _resolveDownloadDirectory();
        server = CastFlowServer(
          device: identity!,
          downloadDirectory: downloadDirectory!,
          pin: pin,
        );
        await server!.start();
        localAddress = await _primaryAddress();
        _subscriptions.add(server!.transfers.listen(_upsertTransfer));
        _subscriptions.add(
          server!.incomingTransfers.listen((transfer) {
            pendingTransfers.removeWhere((item) => item.id == transfer.id);
            pendingTransfers.insert(0, transfer);
            notifyListeners();
          }),
        );
        _subscriptions.add(
          server!.connectedPeers.listen((peer) {
            inboundPeers.removeWhere((item) => item.id == peer.id);
            inboundPeers.add(peer);
            notifyListeners();
          }),
        );
      }

      discovery = DiscoveryService(
        device: identity!,
        httpPort: server?.httpPort ?? 0,
        wsPort: server?.wsPort ?? 0,
        requiresPin: isDesktop,
        advertise: isDesktop,
      );
      _subscriptions.add(
        discovery!.devices.listen((items) {
          devices
            ..clear()
            ..addAll(
              items.where((item) => item.httpPort > 0 && item.wsPort > 0),
            );
          notifyListeners();
        }),
      );
      try {
        await discovery!.start();
      } on SocketException {
        // Le QR et l'adresse manuelle restent disponibles.
      }
    } on Object catch (exception) {
      error = exception.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<String> _resolveDownloadDirectory() async {
    final saved = await _settings.loadDownloadDirectory();
    if (saved != null && saved.isNotEmpty) return saved;
    final base =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final path = '${base.path}${Platform.pathSeparator}CastFlow';
    await Directory(path).create(recursive: true);
    await _settings.saveDownloadDirectory(path);
    return path;
  }

  Future<String> _primaryAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final addresses = interfaces.expand((item) => item.addresses).toList();
    int score(InternetAddress address) {
      final value = address.address;
      if (value.startsWith('192.168.43.')) return 0;
      if (value.startsWith('192.168.')) return 1;
      if (value.startsWith('10.')) return 2;
      if (value.startsWith('172.')) return 3;
      return 4;
    }

    addresses.sort((left, right) => score(left).compareTo(score(right)));
    return addresses.firstOrNull?.address ?? '127.0.0.1';
  }

  Future<bool> connect(RemoteDevice target, {String? pin}) async {
    error = null;
    waitingForPin = false;
    notifyListeners();
    try {
      final authenticated = await client!.connect(target, pin: pin);
      connectedPeer = target;
      waitingForPin = !authenticated;
      notifyListeners();
      return authenticated;
    } on Object catch (exception) {
      error = exception.toString();
      connectedPeer = null;
      notifyListeners();
      return false;
    }
  }

  Future<bool> connectManual(String input) async {
    final value = input.trim().replaceFirst(RegExp(r'^https?://'), '');
    final parts = value.split(':');
    final host = parts.first;
    final port = parts.length > 1
        ? int.tryParse(parts[1]) ?? CastFlowProtocol.defaultHttpPort
        : CastFlowProtocol.defaultHttpPort;
    if (host.isEmpty) return false;
    final found = await CastFlowClient.probe(host, port: port);
    if (found == null) {
      error = 'Aucun appareil CastFlow trouvé à $input';
      notifyListeners();
      return false;
    }
    return connect(found);
  }

  Future<bool> connectQr(String raw) async {
    final target = parseConnectUrl(raw);
    if (target == null) {
      error = 'QR CastFlow invalide';
      notifyListeners();
      return false;
    }
    return connect(target, pin: pinFromConnectUrl(raw));
  }

  Future<bool> submitPin(String value) async {
    try {
      final success = await client!.authenticate(value);
      waitingForPin = !success;
      if (!success) error = 'PIN incorrect';
      notifyListeners();
      return success;
    } on Object catch (exception) {
      error = exception.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> disconnect() async {
    await client?.disconnect();
    connectedPeer = null;
    waitingForPin = false;
    incomingOffer = null;
    notifyListeners();
  }

  Future<void> pickFiles() async {
    final result = await FilePicker.pickFiles();
    for (final picked in result) {
      final path = picked.path;
      if (path == null) continue;
      selectedFiles.add(
        LocalFile(
          id: secureId('f'),
          name: picked.name,
          path: path,
          size: await picked.length(),
          mime: guessMime(picked.name),
        ),
      );
    }
    notifyListeners();
  }

  void removeFile(String id) {
    selectedFiles.removeWhere((file) => file.id == id);
    notifyListeners();
  }

  Future<void> sendSelected() async {
    if (selectedFiles.isEmpty) return;
    error = null;
    transferredBytes = 0;
    totalTransferBytes = selectedFiles.fold(0, (sum, file) => sum + file.size);
    notifyListeners();
    try {
      if (clientConnected) {
        await client!.sendFiles(
          List<LocalFile>.from(selectedFiles),
          onProgress: (sent, total) {
            transferredBytes = sent;
            totalTransferBytes = total;
            notifyListeners();
          },
        );
      } else if (isDesktop && hasInboundPeer) {
        await server!.offerFiles(List<LocalFile>.from(selectedFiles));
        transferredBytes = totalTransferBytes;
      } else {
        throw StateError('Aucun appareil connecté');
      }
      selectedFiles.clear();
    } on Object catch (exception) {
      error = exception.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> acceptOffer() async {
    final offer = incomingOffer;
    if (offer == null) return;
    error = null;
    transferredBytes = 0;
    totalTransferBytes = offer.totalSize;
    notifyListeners();
    try {
      final directory = await _resolveDownloadDirectory();
      await client!.receiveOffer(
        offer,
        directory,
        onProgress: (received, total) {
          transferredBytes = received;
          totalTransferBytes = total;
          notifyListeners();
        },
      );
      incomingOffer = null;
    } on Object catch (exception) {
      error = exception.toString();
    } finally {
      notifyListeners();
    }
  }

  void rejectOffer() {
    incomingOffer = null;
    notifyListeners();
  }

  void acceptIncoming(String id) {
    server?.acceptTransfer(id);
    pendingTransfers.removeWhere((item) => item.id == id);
    notifyListeners();
  }

  void rejectIncoming(String id) {
    server?.rejectTransfer(id);
    pendingTransfers.removeWhere((item) => item.id == id);
    notifyListeners();
  }

  void regeneratePin() {
    pin = generatePin();
    server?.pin = pin;
    notifyListeners();
  }

  void refreshDiscovery() => discovery?.refresh();

  void _upsertTransfer(TransferSnapshot transfer) {
    transferHistory.removeWhere((item) => item.id == transfer.id);
    transferHistory.insert(0, transfer);
    notifyListeners();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(discovery?.dispose());
    unawaited(client?.dispose());
    unawaited(server?.dispose());
    super.dispose();
  }
}
