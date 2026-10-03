import 'dart:async';
import 'dart:isolate';

import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:test/test.dart';

void _delayedHandshake(SendPort parent) {
  final port = ReceivePort();
  Timer(const Duration(milliseconds: 30), () => parent.send(port.sendPort));
  port.listen((message) {
    if (message == 'shutdown') port.close();
    if (message is InitializeRequest) {
      parent.send(InitializeResponse(message.requestId, success: true));
    }
  });
}

void _lateConnect(SendPort parent) {
  final port = ReceivePort();
  var handles = 0;
  parent.send(port.sendPort);
  port.listen((message) {
    if (message == 'shutdown') {
      port.close();
      return;
    }
    switch (message) {
      case InitializeRequest():
        parent.send(InitializeResponse(message.requestId, success: true));
      case ConnectRequest():
        Timer(const Duration(milliseconds: 80), () {
          handles++;
          parent.send(ConnectResponse(message.requestId, 77));
        });
      case DisconnectRequest():
        handles--;
        parent.send(BoolResponse(message.requestId, value: true));
      case GetErrorRequest():
        parent.send(GetErrorResponse(message.requestId, '$handles'));
      default:
        break;
    }
  });
}

void _exitBeforeHandshake(SendPort parent) => Isolate.exit();

void _neverHandshake(SendPort parent) {
  ReceivePort().listen((_) {});
}

void _failedInitialization(SendPort parent) {
  final port = ReceivePort();
  parent.send(port.sendPort);
  port.listen((message) {
    if (message == 'shutdown') port.close();
    if (message is InitializeRequest) {
      parent.send(InitializeResponse(message.requestId, success: false));
    }
  });
}

void main() {
  test('should_report_worker_exit_before_handshake_without_waiting_for_timeout',
      () async {
    final native = AsyncNativeOdbcConnection(
      isolateEntry: _exitBeforeHandshake,
      requestTimeout: Duration.zero,
    );
    addTearDown(native.dispose);
    await expectLater(
      native.initialize(),
      throwsA(
        isA<AsyncError>().having(
          (error) => error.code,
          'code',
          AsyncErrorCode.workerTerminated,
        ),
      ),
    );
    expect(native.isInitialized, isFalse);
  });
  test('should_apply_timeout_to_handshake', () async {
    final native = AsyncNativeOdbcConnection(
      isolateEntry: _neverHandshake,
      requestTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(native.dispose);
    await expectLater(
      native.initialize(),
      throwsA(
        isA<AsyncError>().having(
          (error) => error.code,
          'code',
          AsyncErrorCode.requestTimeout,
        ),
      ),
    );
    expect(native.getWorkerPoolStats().workers, isEmpty);
  });
  test('should_not_notify_recovery_when_initialization_failed', () async {
    var notifications = 0;
    final native = AsyncNativeOdbcConnection(
      isolateEntry: _failedInitialization,
      workerCount: 2,
    )..onWorkerRecovered = () => notifications++;
    addTearDown(native.dispose);
    expect(await native.initialize(), isFalse);
    await native.recoverWorker();
    expect(native.isInitialized, isFalse);
    expect(native.getWorkerPoolStats().workers, isEmpty);
    expect(notifications, 0);
  });
  test('should_share_initialization_between_concurrent_callers', () async {
    final native = AsyncNativeOdbcConnection(isolateEntry: _delayedHandshake);
    addTearDown(native.dispose);
    expect(
      await Future.wait([native.initialize(), native.initialize()]),
      [true, true],
    );
    expect(native.getWorkerPoolStats().workers, hasLength(1));
  });
  test('should_not_publish_workers_after_dispose_during_spawn', () async {
    final native = AsyncNativeOdbcConnection(isolateEntry: _delayedHandshake);
    addTearDown(native.dispose);
    final init = native.initialize();
    final assertion = expectLater(init, throwsA(isA<AsyncError>()));
    native.dispose();
    await assertion;
    expect(native.isInitialized, isFalse);
    expect(await native.initialize(), isTrue);
    expect(native.getWorkerPoolStats().workers, hasLength(1));
  });
  test('should_disconnect_connection_created_after_timeout', () async {
    final native = AsyncNativeOdbcConnection(
      isolateEntry: _lateConnect,
      requestTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(native.dispose);
    await native.initialize();
    await expectLater(native.connect('fake'), throwsA(isA<AsyncError>()));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(await native.getError(), '0');
  });
}
