import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/isolate/worker_failure_snapshot.dart';
import 'package:odbc_fast/infrastructure/native/isolate/worker_isolate.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:odbc_fast/odbc_fast_native.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

void _worker(SendPort parent) {
  final port = ReceivePort();
  parent.send(port.sendPort);
  port.listen((message) {
    if (message == 'shutdown') {
      port.close();
      return;
    }
    switch (message) {
      case InitializeRequest(:final requestId):
        parent.send(InitializeResponse(requestId, success: true));
      case ConnectRequest(:final requestId):
        parent.send(ConnectResponse(requestId, requestId + 100));
      case ExecuteQueryMultiRequest(
          :final requestId,
          :final connectionId,
          :final sql
        ):
        Timer(Duration(milliseconds: sql == 'A' ? 10 : 1), () {
          parent.send(
            QueryResponse(
              requestId,
              error: 'failure $sql',
              failure: WorkerFailureSnapshot(
                message: 'failure $sql',
                operation: 'executeQueryMulti',
                requestId: requestId,
                connectionId: connectionId,
                sqlState: sql == 'A' ? '42000' : '23000',
                nativeCode: connectionId,
              ),
            ),
          );
        });
      case XaStartRequest(:final requestId):
        parent.send(IntResponse(requestId, requestId + 900));
      case XaIdRequest(:final requestId, :final type):
        if (type == RequestType.xaEnd || type == RequestType.xaPrepare) {
          parent.send(IntResponse(requestId, 0));
        } else {
          parent.send(
            IntResponse(
              requestId,
              -1,
              failure: WorkerFailureSnapshot(
                message: 'Transaction completion failed',
                operation: type.name,
                requestId: requestId,
                sqlState: '08007',
                nativeCode: 5,
                code: OdbcErrorCode.transaction,
                outcomeUnknown: true,
              ),
            ),
          );
        }
      case GetStructuredErrorRequest():
        throw StateError('Must not query a later global diagnostic');
      case GetStructuredErrorForConnectionRequest():
        throw StateError('Must not query a later connection diagnostic');
      case GetErrorRequest():
        throw StateError('Must not query a later error');
      default:
        throw StateError('Unexpected fake worker request');
    }
  });
}

void _missingLibraryWorker(SendPort parent) {
  final port = ReceivePort();
  parent
    ..send(port.sendPort)
    ..send(
      const InitializeResponse(
        0,
        success: false,
        failure: WorkerFailureSnapshot(
          message: 'Native library missing',
          operation: 'initialize',
          requestId: 0,
          code: OdbcErrorCode.environmentUnavailable,
          cause: 'Library loader failed',
          stackTrace: 'loader trace',
        ),
      ),
    );
  port.close();
}

void main() {
  test('should_preserve_loader_diagnostic_for_concurrent_initialization',
      () async {
    final repository = OdbcRepositoryImpl(
      AsyncNativeOdbcConnection(
        isolateEntry: _missingLibraryWorker,
        requestTimeout: const Duration(milliseconds: 100),
      ),
    );
    addTearDown(repository.dispose);
    final results = await Future.wait([
      repository.initialize(),
      repository.initialize(),
    ]);
    for (final result in results) {
      final error = result.exceptionOrNull()! as OdbcError;
      expect(error.code, OdbcErrorCode.environmentUnavailable);
      expect(error.details.cause, 'Library loader failed');
      expect(error.details.stackTrace.toString(), 'loader trace');
    }
  });
  test('snapshot preserves sealed variants and partial insert information', () {
    const errors = <OdbcError>[
      QueryError(message: 'SQL lost connection', sqlState: '08006'),
      ValidationError(message: 'Bad input', sqlState: 'HY090', nativeCode: 7),
      RollbackFailedError(message: 'Rollback failed', sqlState: '40001'),
      BulkPartialFailureError(
        rowsInsertedBeforeFailure: 4,
        failedChunks: 2,
        detail: 'partial',
        sqlState: '23000',
        nativeCode: 8,
      ),
    ];
    for (final error in errors) {
      final copy =
          WorkerFailureSnapshot.fromError(error, requestId: 12).toError(1);
      expect(copy.runtimeType, error.runtimeType);
      expect(copy.sqlState, error.sqlState);
      expect(copy.nativeCode, error.nativeCode);
      if (copy is BulkPartialFailureError) {
        expect(copy.rowsInsertedBeforeFailure, 4);
        expect(copy.failedChunks, 2);
        expect(copy.detail, 'partial');
      }
    }
  });
  test(
      'missing worker library returns an environment failure with loader cause',
      () async {
    final repository = OdbcRepositoryImpl(
      AsyncNativeOdbcConnection(
        isolateEntry: _missingLibraryWorker,
        requestTimeout: const Duration(milliseconds: 100),
      ),
    );
    addTearDown(repository.dispose);
    final error =
        (await repository.initialize()).exceptionOrNull()! as OdbcError;
    expect(error.code, OdbcErrorCode.environmentUnavailable);
    expect(error.details.cause, 'Library loader failed');
    expect(error.details.stackTrace.toString(), 'loader trace');
  });
  test('XA commit failure preserves request diagnostic and uncertain phase',
      () async {
    final native = AsyncNativeOdbcConnection(isolateEntry: _worker);
    final repository = OdbcRepositoryImpl(native);
    addTearDown(repository.dispose);
    await repository.initialize();
    final connection = (await repository.connect('DSN=fake')).getOrNull()!;
    final xid = Xid(
      formatId: 1,
      gtrid: Uint8List.fromList([1]),
      bqual: Uint8List.fromList([2]),
    );
    final result = await OdbcService(repository).runInXaTransaction<int>(
      connection.id,
      xid,
      (xa) async => const Success(1),
    );
    final error = result.exceptionOrNull()! as OdbcError;
    expect(error.sqlState, '08007');
    expect(error.nativeCode, 5);
    expect(error.details.operation, 'xaCommitPrepared');
    expect(error.details.outcomeUnknown, isTrue);
    expect(error.details.transactionId, xid.toString());
    expect(native.getWorkerPoolStats().failedRequests, 1);
  });
  test('snapshot preserves uncertain outcome and secondary diagnostics', () {
    final original = QueryError(
      message: 'SQL failure',
      sqlState: '42000',
      nativeCode: 12,
      details: OdbcErrorDetails(
        operation: 'executeQuery',
        cause: StateError('worker cause'),
        stackTrace: StackTrace.current,
        outcomeUnknown: true,
        secondaryErrors: [
          QueryError(
            message: 'Diagnostic unavailable',
            details: OdbcErrorDetails(
              code: OdbcErrorCode.internal,
              operation: 'collectDiagnostic',
              cause: StateError('collector'),
            ),
          ),
        ],
      ),
    );
    final transported =
        WorkerFailureSnapshot.fromError(original, requestId: 7).toError(2);
    expect(transported.sqlState, '42000');
    expect(transported.nativeCode, 12);
    expect(transported.details.outcomeUnknown, isTrue);
    expect(transported.details.cause, contains('worker cause'));
    expect(transported.details.stackTrace, isNotNull);
    expect(
      transported.details.secondaryErrors.single.details.operation,
      'collectDiagnostic',
    );
    expect(
      transported.details.secondaryErrors.single.details.cause,
      contains('collector'),
    );
  });
  test('should_preserve_different_concurrent_worker_diagnostics', () async {
    final native =
        AsyncNativeOdbcConnection(workerCount: 2, isolateEntry: _worker);
    final repository = OdbcRepositoryImpl(native);
    addTearDown(repository.dispose);
    expect((await repository.initialize()).isSuccess(), isTrue);
    final a = (await repository.connect('DSN=fake')).getOrNull()!;
    final b = (await repository.connect('DSN=fake')).getOrNull()!;
    final results = await Future.wait([
      repository.executeQueryMultiFull(a.id, 'A'),
      repository.executeQueryMultiFull(b.id, 'B'),
    ]);
    final errors =
        results.map((r) => r.exceptionOrNull()! as OdbcError).toList();
    expect(errors.map((e) => e.message), ['failure A', 'failure B']);
    expect(errors.map((e) => e.sqlState), ['42000', '23000']);
    expect(errors.map((e) => e.details.workerId).toSet(), hasLength(2));
    expect(errors.map((e) => e.details.requestId).toSet(), hasLength(2));
    expect(native.getWorkerPoolStats().failedRequests, 2);
  });

  test('should_not_map_poll_or_xa_exceptions_to_pending_or_success', () {
    for (final request in [
      const AsyncPollRequest(1, 1),
      const StreamPollAsyncRequest(2, 1),
      XaIdRequest(3, RequestType.xaPrepare, 1),
    ]) {
      final response =
          buildWorkerErrorResponse(request, 'worker exception') as IntResponse;
      expect(response.value, -1);
    }
  });
}
