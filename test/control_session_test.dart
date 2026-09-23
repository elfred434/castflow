import 'package:castflow/remote/control_protocol.dart';
import 'package:castflow/remote/control_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 9, 22, 12);
  const localCapabilities = ControlCapabilities(
    values: {
      ControlCapability.screenCapture,
      ControlCapability.pointer,
      ControlCapability.keyboard,
    },
  );

  ControlSessionCoordinator coordinator() => ControlSessionCoordinator(
    localDeviceId: 'dev_windows_1',
    localCapabilities: localCapabilities,
  );

  ControlRequest request({
    String id = 'ctrl_1',
    Set<ControlCapability> requested = const {
      ControlCapability.screenCapture,
      ControlCapability.pointer,
    },
  }) => ControlRequest(sessionId: id, requested: requested);

  test('exige une approbation locale avant activation', () async {
    final control = coordinator();
    addTearDown(control.dispose);
    final changes = <ControlSessionSnapshot>[];
    final subscription = control.changes.listen(changes.add);
    addTearDown(subscription.cancel);

    final pending = control.receiveRequest(
      requesterDeviceId: 'dev_android_1',
      request: request(),
      now: start,
    );
    expect(pending.state, ControlSessionState.awaitingLocalApproval);
    expect(pending.acceptsInput, isFalse);

    final active = control.approve(
      pending.id,
      granted: pending.requested,
      now: start.add(const Duration(seconds: 1)),
    );
    expect(active.state, ControlSessionState.active);
    expect(active.acceptsInput, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(changes.map((value) => value.state), [
      ControlSessionState.awaitingLocalApproval,
      ControlSessionState.active,
    ]);
  });

  test('refuse une capacité non supportée localement', () async {
    final control = coordinator();
    addTearDown(control.dispose);

    expect(
      () => control.receiveRequest(
        requesterDeviceId: 'dev_android_1',
        request: request(requested: const {ControlCapability.wakeDevice}),
        now: start,
      ),
      throwsStateError,
    );
  });

  test('interdit deux sessions concurrentes', () async {
    final control = coordinator();
    addTearDown(control.dispose);
    control.receiveRequest(
      requesterDeviceId: 'dev_android_1',
      request: request(),
      now: start,
    );

    expect(
      () => control.receiveRequest(
        requesterDeviceId: 'dev_android_2',
        request: request(id: 'ctrl_2'),
        now: start,
      ),
      throwsStateError,
    );
  });

  test('pause, reprend puis arrête une session active', () async {
    final control = coordinator();
    addTearDown(control.dispose);
    final pending = control.receiveRequest(
      requesterDeviceId: 'dev_android_1',
      request: request(),
      now: start,
    );
    control.approve(pending.id, granted: pending.requested, now: start);

    expect(
      control.pause(pending.id, now: start).state,
      ControlSessionState.paused,
    );
    expect(
      control.resume(pending.id, now: start).state,
      ControlSessionState.active,
    );
    expect(
      control.stop(pending.id, now: start).state,
      ControlSessionState.stopped,
    );
    expect(() => control.resume(pending.id), throwsStateError);
  });

  test('refuse les événements rejoués ou désordonnés', () async {
    final control = coordinator();
    addTearDown(control.dispose);
    final pending = control.receiveRequest(
      requesterDeviceId: 'dev_android_1',
      request: request(),
      now: start,
    );
    control.approve(pending.id, granted: pending.requested, now: start);

    expect(control.acceptInputSequence(pending.id, 1), isTrue);
    expect(control.acceptInputSequence(pending.id, 1), isFalse);
    expect(control.acceptInputSequence(pending.id, 0), isFalse);
    expect(control.acceptInputSequence(pending.id, 2), isTrue);
  });

  test('n’accepte aucune entrée pendant une pause', () async {
    final control = coordinator();
    addTearDown(control.dispose);
    final pending = control.receiveRequest(
      requesterDeviceId: 'dev_android_1',
      request: request(),
      now: start,
    );
    control.approve(pending.id, granted: pending.requested, now: start);
    control.pause(pending.id, now: start);

    expect(() => control.acceptInputSequence(pending.id, 1), throwsStateError);
  });

  test('expire une demande restée sans décision', () async {
    final control = coordinator();
    addTearDown(control.dispose);
    final pending = control.receiveRequest(
      requesterDeviceId: 'dev_android_1',
      request: request(),
      now: start,
    );

    expect(
      control.expirePending(start.add(controlApprovalTimeout)),
      hasLength(1),
    );
    expect(control.find(pending.id)?.state, ControlSessionState.denied);
    expect(control.find(pending.id)?.reason, contains('expiré'));
  });

  test('un refus libère la place pour une nouvelle demande', () async {
    final control = coordinator();
    addTearDown(control.dispose);
    final first = control.receiveRequest(
      requesterDeviceId: 'dev_android_1',
      request: request(),
      now: start,
    );
    control.deny(first.id, now: start);

    final second = control.receiveRequest(
      requesterDeviceId: 'dev_android_2',
      request: request(id: 'ctrl_2'),
      now: start,
    );
    expect(second.state, ControlSessionState.awaitingLocalApproval);
  });
}
