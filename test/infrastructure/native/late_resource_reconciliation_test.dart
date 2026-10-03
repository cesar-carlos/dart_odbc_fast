import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:test/test.dart';

void _resourceWorker(SendPort parent) => _resources(parent);

void _failedCleanupWorker(SendPort parent) =>
    _resources(parent, failCleanup: true);

void _diesWithAbandonedRequest(SendPort parent) {
  _resources(parent);
  Timer(const Duration(milliseconds: 70), Isolate.exit);
}

void _resources(SendPort parent, {bool failCleanup = false}) {
  final port = ReceivePort();
  final operations = <String>[];
  parent.send(port.sendPort);
  port.listen((message) {
    if (message == 'shutdown') {
      port.close();
      return;
    }
    if (message is! WorkerRequest) return;
    operations.add(message.type.name);
    if (message is InitializeRequest) {
      parent.send(InitializeResponse(message.requestId, success: true));
    } else if (message is GetErrorRequest) {
      parent.send(GetErrorResponse(message.requestId, jsonEncode(operations)));
    } else if (message is ConnectRequest) {
      Timer(const Duration(milliseconds: 80), () {
        parent
          ..send(ConnectResponse(message.requestId, 100))
          ..send(ConnectResponse(message.requestId, 100));
      });
    } else if (message is PoolCreateRequest ||
        message is PoolGetConnectionRequest ||
        message is PrepareRequest ||
        message is BeginTransactionRequest ||
        message is XaStartRequest ||
        message is XaResumePreparedRequest ||
        message is StreamStartBatchedRequest ||
        message is StreamStartAsyncRequest ||
        message is StreamMultiStartBatchedRequest ||
        message is StreamMultiStartAsyncRequest ||
        message is ExecuteAsyncStartRequest ||
        message is ExecuteAsyncStartParamsRequest) {
      Timer(const Duration(milliseconds: 80), () {
        parent
          ..send(IntResponse(message.requestId, 100))
          ..send(IntResponse(message.requestId, 100));
      });
    } else if (message is XaIdRequest) {
      parent.send(IntResponse(message.requestId, 0));
    } else {
      parent.send(
        BoolResponse(
          message.requestId,
          value: !(failCleanup && message is DisconnectRequest),
          completionStatus: message is RollbackTransactionRequest ? 0 : null,
        ),
      );
    }
  });
}

void main() {
  test('should_report_unconfirmed_cleanup_when_worker_dies_after_timeout',
      () async {
    final diagnostics = <OdbcError>[];
    final native = AsyncNativeOdbcConnection(
      isolateEntry: _diesWithAbandonedRequest,
      requestTimeout: const Duration(milliseconds: 30),
      onDiagnostic: diagnostics.add,
    );
    addTearDown(native.dispose);
    await native.initialize();
    await expectLater(native.connect('fake'), throwsA(isA<AsyncError>()));
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(diagnostics.single.details.outcomeUnknown, isTrue);
    expect(diagnostics.single.details.operation, 'connect');
    expect(diagnostics.single.details.requestId, isNotNull);
    await expectLater(native.getError(), throwsA(isA<AsyncError>()));
  });
  test('should_isolate_disposed_abandonment_from_a_new_generation', () async {
    final diagnostics = <OdbcError>[];
    final native = AsyncNativeOdbcConnection(
      isolateEntry: _resourceWorker,
      requestTimeout: const Duration(milliseconds: 30),
      maxPendingRequests: 1,
      onDiagnostic: diagnostics.add,
    );
    addTearDown(native.dispose);
    await native.initialize();
    await expectLater(native.connect('old'), throwsA(isA<AsyncError>()));
    native.dispose();
    expect(diagnostics.single.details.outcomeUnknown, isTrue);
    await native.initialize();
    await expectLater(native.connect('new'), throwsA(isA<AsyncError>()));
    await Future<void>.delayed(const Duration(milliseconds: 140));
    final operations = jsonDecode(await native.getError()) as List<Object?>;
    expect(operations.where((op) => op == 'disconnect'), hasLength(1));
    expect(native.getWorkerPoolStats().activeRequests, 0);
    expect(diagnostics, hasLength(2));
  });
  test('should_clean_up_on_owner_even_when_another_worker_has_less_load',
      () async {
    final native = AsyncNativeOdbcConnection(
      isolateEntry: _resourceWorker,
      workerCount: 2,
      requestTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(native.dispose);
    await native.initialize();
    await expectLater(
      native.prepare(1, 'SELECT 1'),
      throwsA(isA<AsyncError>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 140));
    final other = jsonDecode(await native.getError()) as List<Object?>;
    final owner = jsonDecode(await native.getError()) as List<Object?>;
    expect(other, isNot(contains('closeStatement')));
    expect(owner.where((op) => op == 'closeStatement'), hasLength(1));
  });
  test('should_preserve_timeout_and_failed_cleanup_in_quarantine', () async {
    final diagnostics = <OdbcError>[];
    final native = AsyncNativeOdbcConnection(
      isolateEntry: _failedCleanupWorker,
      requestTimeout: const Duration(milliseconds: 30),
      maxPendingRequests: 1,
      onDiagnostic: diagnostics.add,
    );
    addTearDown(native.dispose);
    await native.initialize();
    await expectLater(native.connect('fake'), throwsA(isA<AsyncError>()));
    await Future<void>.delayed(const Duration(milliseconds: 140));
    final error = diagnostics.single;
    expect(error.code, OdbcErrorCode.timeout);
    expect(error.details.secondaryErrors, hasLength(1));
    expect(native.getWorkerPoolStats().activeRequests, 1);
    await expectLater(
      native.connect('another'),
      throwsA(
        isA<AsyncError>()
            .having((e) => e.code, 'code', AsyncErrorCode.resourceExhausted),
      ),
    );
  });
  final xid = Xid.fromStrings(gtrid: 'branch');
  final cases = <String,
      (Future<Object?> Function(AsyncNativeOdbcConnection), List<String>)>{
    'connect': ((n) => n.connect('fake'), ['disconnect']),
    'poolCreate': ((n) => n.poolCreate('fake', 1), ['poolClose']),
    'poolGetConnection': (
      (n) => n.poolGetConnection(9),
      ['poolReleaseConnection']
    ),
    'prepare': ((n) => n.prepare(1, 'SELECT 1'), ['closeStatement']),
    'beginTransaction': (
      (n) => n.beginTransaction(1, 2),
      ['rollbackTransaction']
    ),
    'xaStart': ((n) => n.xaStart(1, xid), ['xaEnd', 'xaRollbackActive']),
    'streamStartBatched': (
      (n) => n.streamStartBatched(1, 'SELECT 1'),
      ['streamCancel', 'streamClose']
    ),
    'streamStartAsync': (
      (n) => n.streamStartAsync(1, 'SELECT 1'),
      ['streamCancel', 'streamClose']
    ),
    'streamMultiStartBatched': (
      (n) => n.streamMultiStartBatched(1, 'SELECT 1'),
      ['streamCancel', 'streamClose']
    ),
    'streamMultiStartAsync': (
      (n) => n.streamMultiStartAsync(1, 'SELECT 1'),
      ['streamCancel', 'streamClose']
    ),
    'executeAsyncStart': (
      (n) => n.executeAsyncStart(1, 'SELECT 1'),
      ['asyncCancel', 'asyncFree']
    ),
    'executeAsyncStartParams': (
      (n) => n.executeAsyncStartParams(1, 'SELECT 1', Uint8List(0)),
      ['asyncCancel', 'asyncFree']
    ),
  };
  for (final entry in cases.entries) {
    test('should_compensate_late_${entry.key}_once_on_owner_worker', () async {
      final diagnostics = <OdbcError>[];
      final native = AsyncNativeOdbcConnection(
        isolateEntry: _resourceWorker,
        requestTimeout: const Duration(milliseconds: 30),
        maxPendingRequests: 1,
        onDiagnostic: diagnostics.add,
      );
      addTearDown(native.dispose);
      await native.initialize();
      await expectLater(entry.value.$1(native), throwsA(isA<AsyncError>()));
      await expectLater(
        native.getError(),
        throwsA(
          isA<AsyncError>().having(
            (e) => e.code,
            'code',
            AsyncErrorCode.resourceExhausted,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 140));
      final operations = jsonDecode(await native.getError()) as List<Object?>;
      for (final operation in entry.value.$2) {
        expect(operations.where((op) => op == operation), hasLength(1));
      }
      expect(diagnostics.single.details.requestId, isNotNull);
      expect(native.getWorkerPoolStats().timeouts, 1);
      expect(native.getWorkerPoolStats().activeRequests, 0);
    });
  }
  test('should_adopt_late_prepared_resume_without_rollback_or_duplicate',
      () async {
    final native = AsyncNativeOdbcConnection(
      isolateEntry: _resourceWorker,
      requestTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(native.dispose);
    await native.initialize();
    await expectLater(
      native.xaResumePrepared(1, xid),
      throwsA(isA<AsyncError>()),
    );
    await expectLater(
      native.xaResumePrepared(1, xid),
      throwsA(isA<OdbcError>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(await native.xaResumePrepared(1, xid), 100);
    final operations = jsonDecode(await native.getError()) as List<Object?>;
    expect(operations.where((op) => op == 'xaResumePrepared'), hasLength(1));
    expect(operations, isNot(contains('xaRollbackPrepared')));
  });
  test('should_protect_throwing_diagnostic_callback', () async {
    final native = AsyncNativeOdbcConnection(
      isolateEntry: _resourceWorker,
      requestTimeout: const Duration(milliseconds: 30),
      onDiagnostic: (_) => throw StateError('Diagnostic unavailable'),
    );
    addTearDown(native.dispose);
    await native.initialize();
    await expectLater(native.connect('fake'), throwsA(isA<AsyncError>()));
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(await native.getError(), contains('disconnect'));
  });
}
