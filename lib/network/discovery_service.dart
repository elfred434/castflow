import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';
import '../core/models.dart';

class DiscoveryService {
  DiscoveryService({
    required this.device,
    required this.httpPort,
    required this.wsPort,
    required this.requiresPin,
    this.port = CastFlowProtocol.discoveryPort,
    this.advertise = true,
  });

  final DeviceInfo device;
  final int httpPort;
  final int wsPort;
  final bool requiresPin;
  final int port;
  final bool advertise;

  RawDatagramSocket? _socket;
  Timer? _announcer;
  Timer? _sweeper;
  final Map<String, RemoteDevice> _devices = {};
  final StreamController<List<RemoteDevice>> _controller =
      StreamController<List<RemoteDevice>>.broadcast();

  Stream<List<RemoteDevice>> get devices => _controller.stream;
  List<RemoteDevice> get currentDevices => _sortedDevices();

  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = socket.receive();
        if (datagram != null) _handle(datagram);
      }
    });
    _socket = socket;
    refresh();
    if (advertise) {
      _announcer = Timer.periodic(
        CastFlowProtocol.announceInterval,
        (_) => _send('ANNOUNCE'),
      );
    }
    _sweeper = Timer.periodic(const Duration(seconds: 2), (_) => _sweep());
  }

  void refresh() => _send('DISCOVER');

  Map<String, Object?> _packet(String type) => {
    'v': CastFlowProtocol.version,
    'type': type,
    'device': device.toJson(),
    'http': httpPort,
    'ws': wsPort,
    'secure': false,
    'requiresPin': requiresPin,
    't': DateTime.now().millisecondsSinceEpoch,
  };

  void _send(String type, {InternetAddress? address, int? targetPort}) {
    final socket = _socket;
    if (socket == null) return;
    final bytes = utf8.encode(jsonEncode(_packet(type)));
    try {
      socket.send(
        bytes,
        address ?? InternetAddress('255.255.255.255'),
        targetPort ?? port,
      );
    } on SocketException {
      // Certains runners et réseaux mobiles interdisent le broadcast.
    }
  }

  void _handle(Datagram datagram) {
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map) return;
      final json = decoded.cast<String, Object?>();
      if ((json['v'] as num?)?.toInt() != CastFlowProtocol.version) return;
      final rawDevice = json['device'];
      if (rawDevice is! Map) return;
      final found = DeviceInfo.fromJson(rawDevice.cast<String, Object?>());
      if (found.id.isEmpty || found.id == device.id) return;
      final type = json['type']?.toString();
      if (type == 'BYE') {
        if (_devices.remove(found.id) != null) _emit();
        return;
      }
      if (type != 'ANNOUNCE' && type != 'DISCOVER') return;
      _devices[found.id] = RemoteDevice(
        id: found.id,
        name: found.name,
        platform: found.platform,
        kind: found.kind,
        fingerprint: found.fingerprint,
        host: datagram.address.address,
        httpPort:
            (json['http'] as num?)?.toInt() ?? CastFlowProtocol.defaultHttpPort,
        wsPort: (json['ws'] as num?)?.toInt() ?? CastFlowProtocol.defaultWsPort,
        requiresPin: json['requiresPin'] == true,
        secure: json['secure'] == true,
        source: 'udp',
        lastSeen: DateTime.now(),
      );
      _emit();
      if (type == 'DISCOVER' && advertise) {
        _send('ANNOUNCE', address: datagram.address, targetPort: datagram.port);
      }
    } on FormatException {
      return;
    }
  }

  void _sweep() {
    final threshold = DateTime.now().subtract(CastFlowProtocol.deviceTtl);
    final before = _devices.length;
    _devices.removeWhere(
      (_, value) => (value.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0))
          .isBefore(threshold),
    );
    if (_devices.length != before) _emit();
  }

  List<RemoteDevice> _sortedDevices() {
    final values = _devices.values.toList();
    values.sort((left, right) => left.name.compareTo(right.name));
    return values;
  }

  void _emit() => _controller.add(_sortedDevices());

  Future<void> stop() async {
    _announcer?.cancel();
    _sweeper?.cancel();
    _send('BYE');
    _socket?.close();
    _socket = null;
    _devices.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
