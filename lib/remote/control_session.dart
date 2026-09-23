import 'dart:async';

import 'control_protocol.dart';

const controlApprovalTimeout = Duration(seconds: 30);

class ControlSessionSnapshot {
  const ControlSessionSnapshot({
    required this.id,
    required this.requesterDeviceId,
    required this.state,
    required this.requested,
    required this.granted,
    required this.createdAt,
    required this.updatedAt,
    this.reason,
  });

  final String id;
  final String requesterDeviceId;
  final ControlSessionState state;
  final Set<ControlCapability> requested;
  final Set<ControlCapability> granted;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? reason;

  bool get acceptsInput => state == ControlSessionState.active;
}

class ControlSessionCoordinator {
  ControlSessionCoordinator({
    required this.localDeviceId,
    required this.localCapabilities,
  });

  final String localDeviceId;
  final ControlCapabilities localCapabilities;
  final Map<String, _MutableControlSession> _sessions = {};
  final StreamController<ControlSessionSnapshot> _changes =
      StreamController<ControlSessionSnapshot>.broadcast();

  Stream<ControlSessionSnapshot> get changes => _changes.stream;

  List<ControlSessionSnapshot> get sessions => _sessions.values
      .map((session) => session.snapshot)
      .toList(growable: false);

  ControlSessionSnapshot? find(String id) => _sessions[id]?.snapshot;

  ControlSessionSnapshot receiveRequest({
    required String requesterDeviceId,
    required ControlRequest request,
    DateTime? now,
  }) {
    _validateSessionId(request.sessionId, 'session');
    _validateSessionId(requesterDeviceId, 'appareil demandeur');
    _validateSessionId(localDeviceId, 'appareil local');
    if (requesterDeviceId == localDeviceId) {
      throw const FormatException(
        'Un appareil ne peut pas se contrôler lui-même',
      );
    }
    _ensureNoConcurrentSession();
    final unsupported = request.requested.difference(localCapabilities.values);
    if (unsupported.isNotEmpty) {
      throw StateError(
        'Capacités non supportées: ${unsupported.map((value) => value.name).join(', ')}',
      );
    }
    if (request.requested.isEmpty) {
      throw const FormatException('Aucune capacité de contrôle demandée');
    }
    final clock = (now ?? DateTime.now()).toUtc();
    final session = _MutableControlSession(
      id: request.sessionId,
      requesterDeviceId: requesterDeviceId,
      state: ControlSessionState.awaitingLocalApproval,
      requested: Set.unmodifiable(request.requested),
      createdAt: clock,
      updatedAt: clock,
    );
    _sessions[session.id] = session;
    return _emit(session);
  }

  ControlSessionSnapshot approve(
    String id, {
    required Set<ControlCapability> granted,
    DateTime? now,
  }) {
    final session = _requireState(id, const {
      ControlSessionState.awaitingLocalApproval,
    });
    if (granted.isEmpty || !session.requested.containsAll(granted)) {
      throw const FormatException('Capacités accordées invalides');
    }
    if (!localCapabilities.values.containsAll(granted)) {
      throw const FormatException('Capacités locales insuffisantes');
    }
    session
      ..state = ControlSessionState.active
      ..granted = Set.unmodifiable(granted)
      ..updatedAt = (now ?? DateTime.now()).toUtc();
    return _emit(session);
  }

  ControlSessionSnapshot deny(
    String id, {
    String reason = 'Demande refusée localement',
    DateTime? now,
  }) {
    final session = _requireState(id, const {
      ControlSessionState.awaitingLocalApproval,
    });
    session
      ..state = ControlSessionState.denied
      ..reason = reason
      ..updatedAt = (now ?? DateTime.now()).toUtc();
    return _emit(session);
  }

  ControlSessionSnapshot pause(String id, {DateTime? now}) {
    final session = _requireState(id, const {ControlSessionState.active});
    session
      ..state = ControlSessionState.paused
      ..updatedAt = (now ?? DateTime.now()).toUtc();
    return _emit(session);
  }

  ControlSessionSnapshot resume(String id, {DateTime? now}) {
    final session = _requireState(id, const {ControlSessionState.paused});
    session
      ..state = ControlSessionState.active
      ..updatedAt = (now ?? DateTime.now()).toUtc();
    return _emit(session);
  }

  ControlSessionSnapshot stop(
    String id, {
    String reason = 'Session arrêtée',
    DateTime? now,
  }) {
    final session = _requireState(id, const {
      ControlSessionState.awaitingLocalApproval,
      ControlSessionState.active,
      ControlSessionState.paused,
    });
    session
      ..state = ControlSessionState.stopped
      ..reason = reason
      ..updatedAt = (now ?? DateTime.now()).toUtc();
    return _emit(session);
  }

  bool acceptInputSequence(String id, int sequence) {
    final session = _requireState(id, const {ControlSessionState.active});
    if (sequence < 0 || sequence <= session.lastInputSequence) return false;
    session.lastInputSequence = sequence;
    return true;
  }

  List<ControlSessionSnapshot> expirePending([DateTime? now]) {
    final clock = (now ?? DateTime.now()).toUtc();
    final expired = <ControlSessionSnapshot>[];
    for (final session in _sessions.values) {
      if (session.state == ControlSessionState.awaitingLocalApproval &&
          !clock.isBefore(session.createdAt.add(controlApprovalTimeout))) {
        session
          ..state = ControlSessionState.denied
          ..reason = 'Délai d’approbation expiré'
          ..updatedAt = clock;
        expired.add(_emit(session));
      }
    }
    return expired;
  }

  Future<void> dispose() => _changes.close();

  _MutableControlSession _requireState(
    String id,
    Set<ControlSessionState> allowed,
  ) {
    final session = _sessions[id];
    if (session == null) throw StateError('Session de contrôle introuvable');
    if (!allowed.contains(session.state)) {
      throw StateError('Transition interdite depuis ${session.state.name}');
    }
    return session;
  }

  void _ensureNoConcurrentSession() {
    final occupied = _sessions.values.any(
      (session) =>
          session.state == ControlSessionState.awaitingLocalApproval ||
          session.state == ControlSessionState.active ||
          session.state == ControlSessionState.paused,
    );
    if (occupied) throw StateError('Une session de contrôle est déjà en cours');
  }

  ControlSessionSnapshot _emit(_MutableControlSession session) {
    final snapshot = session.snapshot;
    if (!_changes.isClosed) _changes.add(snapshot);
    return snapshot;
  }
}

void _validateSessionId(String value, String label) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(value)) {
    throw FormatException('Identifiant $label invalide');
  }
}

class _MutableControlSession {
  _MutableControlSession({
    required this.id,
    required this.requesterDeviceId,
    required this.state,
    required this.requested,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String requesterDeviceId;
  ControlSessionState state;
  final Set<ControlCapability> requested;
  Set<ControlCapability> granted = const {};
  final DateTime createdAt;
  DateTime updatedAt;
  String? reason;
  int lastInputSequence = -1;

  ControlSessionSnapshot get snapshot => ControlSessionSnapshot(
    id: id,
    requesterDeviceId: requesterDeviceId,
    state: state,
    requested: requested,
    granted: granted,
    createdAt: createdAt,
    updatedAt: updatedAt,
    reason: reason,
  );
}
