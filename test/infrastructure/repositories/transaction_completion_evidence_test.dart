import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_execution_stage.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/isolate/worker_failure_snapshot.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

void _transactionWorker(SendPort parent) {
  final port = ReceivePort();
  var mode = '0';
  var rollbackMode = false;
  var rollbacks = 0;
  var queries = 0;
  parent.send(port.sendPort);
  port.listen((message) {
    if (message == 'shutdown') {
      port.close();
      return;
    }
    if (message is! WorkerRequest) return;
    switch (message) {
      case InitializeRequest():
        parent.send(InitializeResponse(message.requestId, success: true));
      case ConnectRequest():
        rollbackMode = message.connectionString.startsWith('rollback:');
        mode = message.connectionString.replaceFirst('rollback:', '');
        parent.send(ConnectResponse(message.requestId, 7));
      case BeginTransactionRequest():
        parent.send(IntResponse(message.requestId, 101));
      case CommitTransactionRequest() || RollbackTransactionRequest():
        if (message is RollbackTransactionRequest) {
          rollbacks++;
          if (!rollbackMode) {
            parent.send(
              BoolResponse(
                message.requestId,
                value: true,
                completionStatus: 0,
              ),
            );
            return;
          }
        } else if (rollbackMode) {
          parent.send(
            BoolResponse(
              message.requestId,
              value: true,
              completionStatus: 0,
            ),
          );
          return;
        }
        final status = int.tryParse(mode);
        final response = BoolResponse(
          message.requestId,
          value: status == 0 || mode == 'late',
          completionStatus: mode == 'late' ? 0 : status,
          failure: status == 0 || mode == 'late'
              ? null
              : WorkerFailureSnapshot(
                  message: 'Commit failed',
                  operation: message.type.name,
                  requestId: message.requestId,
                  sqlState: '40001',
                  code: OdbcErrorCode.transaction,
                  executionStage: mode == 'before'
                      ? NativeExecutionStage.notStarted
                      : mode == 'missing'
                          ? null
                          : NativeExecutionStage.started,
                ),
        );
        if (mode == 'late') {
          Timer(const Duration(milliseconds: 80), () => parent.send(response));
        } else {
          parent.send(response);
        }
      case ExecuteAsyncStartParamsRequest():
        parent.send(
          IntResponse(
            message.requestId,
            0,
            failure: WorkerFailureSnapshot(
              message: 'Async execution unavailable',
              operation: 'executeAsyncStartParams',
              requestId: message.requestId,
              code: OdbcErrorCode.unsupported,
            ),
          ),
        );
      case ExecuteQueryParamsRequest():
        queries++;
        final frame = Uint8List(16);
        ByteData.sublistView(frame)
          ..setUint32(0, 0x4F444243, Endian.little)
          ..setUint16(4, 1, Endian.little);
        parent.send(QueryResponse(message.requestId, data: frame));
      case GetErrorRequest():
        parent.send(GetErrorResponse(message.requestId, '$rollbacks:$queries'));
      case DisconnectRequest():
        parent.send(BoolResponse(message.requestId, value: true));
      default:
        parent.send(
          BoolResponse(message.requestId, value: true),
        );
    }
  });
}

void main() {
  for (final mode in [
    '0',
    '1',
    '2',
    'before',
    'missing',
    'started',
    '7',
    'late',
  ]) {
    test('should_preserve_rollback_completion_evidence_$mode', () async {
      final native = AsyncNativeOdbcConnection(
        isolateEntry: _transactionWorker,
        requestTimeout: const Duration(milliseconds: 30),
      );
      final repository = OdbcRepositoryImpl(native);
      addTearDown(repository.dispose);
      await repository.initialize();
      final connection =
          (await repository.connect('rollback:$mode')).getOrNull()!;
      final txn = (await repository.beginTransaction(
        connection.id,
        IsolationLevel.readCommitted,
      ))
          .getOrNull()!;
      final rollback = await repository.rollbackTransaction(connection.id, txn);
      expect(rollback.isSuccess(), mode == '0');
      if (mode == 'late') {
        expect(
          (rollback.exceptionOrNull()! as OdbcError).details.outcomeUnknown,
          isTrue,
        );
        await Future<void>.delayed(const Duration(milliseconds: 140));
        expect(
          (await repository.executeQuery(connection.id, 'SELECT 1'))
              .isSuccess(),
          isTrue,
        );
      }
      final commit = await repository.commitTransaction(connection.id, txn);
      expect(commit.isSuccess(), mode == '2' || mode == 'before');
    });
  }

  for (final mode in [
    '0',
    '1',
    '2',
    'before',
    'missing',
    'started',
    '7',
    'late',
  ]) {
    test('should_preserve_ownership_from_completion_evidence_$mode', () async {
      final native = AsyncNativeOdbcConnection(
        isolateEntry: _transactionWorker,
        requestTimeout: const Duration(milliseconds: 30),
      );
      final repository = OdbcRepositoryImpl(native);
      addTearDown(repository.dispose);
      expect((await repository.initialize()).isSuccess(), isTrue);
      final connection = (await repository.connect(mode)).getOrNull()!;
      final txn = (await repository.beginTransaction(
        connection.id,
        IsolationLevel.readCommitted,
      ))
          .getOrNull()!;
      final commit = await repository.commitTransaction(connection.id, txn);
      expect(commit.isSuccess(), mode == '0');
      if (mode == 'missing' ||
          mode == 'started' ||
          mode == '7' ||
          mode == 'late' ||
          mode == '1') {
        final query = await repository.executeQuery(connection.id, 'SELECT 1');
        expect(query.isError(), isTrue);
        expect(
          (query.exceptionOrNull()! as OdbcError).details.outcomeUnknown,
          isTrue,
        );
      }
      if (mode == 'late') {
        final error = commit.exceptionOrNull()! as OdbcError;
        expect(error.code, OdbcErrorCode.timeout);
        expect(error.details.requestId, isNotNull);
        expect(error.details.operation, 'commitTransaction');
        await Future<void>.delayed(const Duration(milliseconds: 140));
        final query = await repository.executeQuery(connection.id, 'SELECT 1');
        expect(
          query.isSuccess(),
          isTrue,
          reason: '${(query.exceptionOrNull() as OdbcError?)?.details.cause} '
              '${(query.exceptionOrNull() as OdbcError?)?.details.stackTrace}',
        );
      }
      final rollback = await repository.rollbackTransaction(connection.id, txn);
      expect(rollback.isSuccess(), mode == '2' || mode == 'before');
      expect(
        await native.getError(),
        '${mode == '2' || mode == 'before' ? 1 : 0}:${mode == 'late' ? 1 : 0}',
      );
    });
  }
}
