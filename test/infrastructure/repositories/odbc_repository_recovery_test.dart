import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/errors/native_call_context.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:odbc_fast/odbc_fast_native.dart';
import 'package:test/test.dart';

import '../../helpers/binary_protocol_test_helper.dart';
import '../../helpers/fake_async_native_for_errors.dart';

class _RecoveryNative extends FakeAsyncNativeForRepositoryErrors {
  final queryIds = <int>[];
  int connects = 0;
  bool failQuery = true;
  int nextPoolId = 100;
  Completer<void>? recoveryGate;
  final recoveryStarted = Completer<void>();
  final connectionStrings = <String>[];
  bool failOldHandle = false;
  bool commitBusy = false;
  int commits = 0;
  int rollbacks = 0;

  @override
  Future<int> connect(String connectionString, {int timeoutMs = 0}) async {
    connects++;
    connectionStrings.add(connectionString);
    if (connects > 1) {
      if (!recoveryStarted.isCompleted) recoveryStarted.complete();
      await recoveryGate?.future;
    }
    return super.connect(connectionString, timeoutMs: timeoutMs);
  }

  @override
  Future<Uint8List?> executeQueryParams(
    int connectionId,
    String sql,
    List<ParamValue> params, {
    int? maxBufferBytes,
    int? initialBufferBytes,
    Duration? timeout,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
    int fetchSize = 0,
  }) async {
    queryIds.add(connectionId);
    if (failQuery || (failOldHandle && connectionId == 51)) {
      failQuery = false;
      throw const QueryError(message: 'Lost connection', sqlState: '08006');
    }
    return createBinaryProtocolBuffer(
      rows: [
        [1],
      ],
    );
  }

  @override
  Future<bool> commitTransaction(int txnId) async {
    commits++;
    NativeCallContext.current!.completionStatus = commitBusy ? 2 : 0;
    return !commitBusy;
  }

  @override
  Future<bool> rollbackTransaction(int txnId) async {
    rollbacks++;
    return true;
  }

  @override
  Future<int> poolGetConnection(int poolId) async {
    final id = ++nextPoolId;
    if (id > 101 && recoveryGate != null) {
      if (!recoveryStarted.isCompleted) recoveryStarted.complete();
      await recoveryGate!.future;
    }
    return id;
  }

  @override
  Future<bool> poolReleaseConnection(int connectionId) async => true;

  @override
  Future<bool> poolClose(int poolId) async => true;
}

void main() {
  for (final action in ['release', 'close', 'dispose']) {
    test('pool $action during recovery cannot publish a new checkout',
        () async {
      final native = _RecoveryNative()..recoveryGate = Completer<void>();
      final repository = OdbcRepositoryImpl(native);
      addTearDown(repository.dispose);
      final conn = (await repository.poolGetConnection(
        7,
        options: const ConnectionOptions(autoReconnectOnConnectionLost: true),
      ))
          .getOrNull()!;
      final pending = repository.executeQuery(conn.id, 'query');
      await native.recoveryStarted.future;
      if (action == 'release') {
        expect(
          (await repository.poolReleaseConnection(conn.id)).isSuccess(),
          isTrue,
        );
      } else if (action == 'close') {
        expect((await repository.poolClose(7)).isSuccess(), isTrue);
      } else {
        repository.dispose();
      }
      native.recoveryGate!.complete();
      expect((await pending).isError(), isTrue);
      expect(repository.dartSideMetrics().connectionCount, 0);
      expect(repository.dartSideMetrics().connectionOptionsCount, 0);
    });
  }
  test('should_share_recovery_and_use_current_handle_for_concurrent_queries',
      () async {
    final native = _RecoveryNative()
      ..failOldHandle = true
      ..recoveryGate = Completer<void>();
    final repo = OdbcRepositoryImpl(native);
    addTearDown(repo.dispose);
    final conn = (await repo.connect(
      'DSN=fake',
      options: const ConnectionOptions(
        autoReconnectOnConnectionLost: true,
        replayQueriesAfterReconnect: true,
      ),
    ))
        .getOrNull()!;
    final pending = [
      repo.executeQuery(conn.id, 'one'),
      repo.executeQuery(conn.id, 'two'),
    ];
    await native.recoveryStarted.future;
    native.recoveryGate!.complete();
    final values = await Future.wait(pending);
    expect(values.every((r) => r.isSuccess()), isTrue);
    expect(native.connects, 2);
    expect(native.queryIds.where((id) => id == 52), hasLength(2));
  });

  test('should_not_publish_handle_after_disconnect_during_recovery', () async {
    final native = _RecoveryNative()..recoveryGate = Completer<void>();
    final repo = OdbcRepositoryImpl(native);
    addTearDown(repo.dispose);
    final conn = (await repo.connect(
      'DSN=fake',
      options: const ConnectionOptions(autoReconnectOnConnectionLost: true),
    ))
        .getOrNull()!;
    final pending = repo.executeQuery(conn.id, 'query');
    await native.recoveryStarted.future;
    expect((await repo.disconnect(conn.id)).isSuccess(), isTrue);
    native.recoveryGate!.complete();
    expect((await pending).isError(), isTrue);
    expect(repo.dartSideMetrics().connectionCount, 0);
    expect(repo.dartSideMetrics().connectionOptionsCount, 0);
  });

  test('should_reacquire_from_original_pool_without_using_pool_uri', () async {
    final native = _RecoveryNative();
    final repo = OdbcRepositoryImpl(native);
    addTearDown(repo.dispose);
    final conn = (await repo.poolGetConnection(
      7,
      options: const ConnectionOptions(
        autoReconnectOnConnectionLost: true,
        replayQueriesAfterReconnect: true,
      ),
    ))
        .getOrNull()!;
    expect((await repo.executeQuery(conn.id, 'query')).isSuccess(), isTrue);
    expect(native.queryIds, [101, 102]);
    expect(native.connectionStrings, isEmpty);
    expect((await repo.poolReleaseConnection(conn.id)).isSuccess(), isTrue);
    expect(repo.dartSideMetrics().connectionOptionsCount, 0);
  });

  test('should_block_recovery_during_transaction_and_validate_ownership',
      () async {
    final native = _RecoveryNative()..beginTransactionResult = 7;
    final repo = OdbcRepositoryImpl(native);
    addTearDown(repo.dispose);
    final conn = (await repo.connect(
      'DSN=fake',
      options: const ConnectionOptions(
        autoReconnectOnConnectionLost: true,
        replayQueriesAfterReconnect: true,
      ),
    ))
        .getOrNull()!;
    await repo.beginTransaction(conn.id, IsolationLevel.readCommitted);
    final other = (await repo.connect('DSN=other')).getOrNull()!;
    expect(
      (await repo.commitTransaction(other.id, 7)).exceptionOrNull(),
      isA<ValidationError>(),
    );
    final result = await repo.executeQuery(conn.id, 'query');
    expect(
      (result.exceptionOrNull()! as OdbcError).details.outcomeUnknown,
      isTrue,
    );
    expect(native.connects, 2);
    expect(native.queryIds, [51]);
    expect((await repo.rollbackTransaction(conn.id, 7)).isSuccess(), isTrue);
  });

  test('should_retain_busy_transaction_and_remove_consumed_handle', () async {
    final native = _RecoveryNative()
      ..beginTransactionResult = 7
      ..commitBusy = true;
    final repo = OdbcRepositoryImpl(native);
    addTearDown(repo.dispose);
    final conn = (await repo.connect('DSN=fake')).getOrNull()!;
    await repo.beginTransaction(conn.id, IsolationLevel.readCommitted);
    expect((await repo.commitTransaction(conn.id, 7)).isError(), isTrue);
    native.commitBusy = false;
    expect((await repo.commitTransaction(conn.id, 7)).isSuccess(), isTrue);
    expect(
      (await repo.rollbackTransaction(conn.id, 7)).exceptionOrNull(),
      isA<ValidationError>(),
    );
    expect(native.commits, 2);
    expect(native.rollbacks, 0);
  });

  test('should_stop_recovery_on_definitive_failure', () async {
    final native = _RecoveryNative();
    final repo = OdbcRepositoryImpl(native);
    addTearDown(repo.dispose);
    final conn = (await repo.connect(
      'DSN=fake',
      options: const ConnectionOptions(
        autoReconnectOnConnectionLost: true,
        maxReconnectAttempts: 5,
        reconnectBackoff: Duration.zero,
      ),
    ))
        .getOrNull()!;
    native
      ..connectReturnsZero = true
      ..globalStructuredError = StructuredError(
        sqlState: '28000'.codeUnits,
        nativeCode: 1,
        message: 'Invalid login',
      );
    final result = await repo.executeQuery(conn.id, 'query');
    expect(result.isError(), isTrue);
    expect(native.connects, 2);
    final error = result.exceptionOrNull()! as OdbcError;
    expect(error.sqlState, '08006');
    expect(error.details.secondaryErrors.single.sqlState, '28000');
  });

  test('should_validate_pool_options_before_calling_backend', () async {
    final native = _RecoveryNative();
    final repo = OdbcRepositoryImpl(native);
    addTearDown(repo.dispose);
    const options = ConnectionOptions(queryTimeout: Duration(seconds: -1));
    expect(
      (await repo.poolGetConnection(1, options: options)).exceptionOrNull(),
      isA<ValidationError>(),
    );
    expect(native.nextPoolId, 100);
    expect(
      (await repo.poolCreate('DSN=fake', 1, connectionOptions: options))
          .exceptionOrNull(),
      isA<ValidationError>(),
    );
  });

  test('should_replay_with_current_handle_when_explicitly_enabled', () async {
    final native = _RecoveryNative();
    final repository = OdbcRepositoryImpl(native);
    addTearDown(repository.dispose);
    final conn = (await repository.connect(
      'DSN=fake',
      options: const ConnectionOptions(
        autoReconnectOnConnectionLost: true,
        replayQueriesAfterReconnect: true,
      ),
    ))
        .getOrNull()!;
    expect(
      (await repository.executeQuery(conn.id, 'SELECT 1')).isSuccess(),
      isTrue,
    );
    expect(native.queryIds, [51, 52]);
  });

  test('should_restore_without_replay_by_default', () async {
    final native = _RecoveryNative();
    final repository = OdbcRepositoryImpl(native);
    addTearDown(repository.dispose);
    final conn = (await repository.connect(
      'DSN=fake',
      options: const ConnectionOptions(autoReconnectOnConnectionLost: true),
    ))
        .getOrNull()!;
    final result = await repository.executeQuery(conn.id, 'UPDATE t SET x=1');
    expect(result.isError(), isTrue);
    expect(
      (result.exceptionOrNull()! as OdbcError).details.outcomeUnknown,
      isTrue,
    );
    expect(native.queryIds, [51]);
    expect(native.connects, 2);
    expect(
      (await repository.executeQuery(conn.id, 'SELECT 1')).isSuccess(),
      isTrue,
    );
    expect(native.queryIds.last, 52);
  });

  test('should_return_failure_when_reconnect_fails', () async {
    final native = _RecoveryNative();
    final repository = OdbcRepositoryImpl(native);
    addTearDown(repository.dispose);
    final conn = (await repository.connect(
      'DSN=fake',
      options: const ConnectionOptions(
        autoReconnectOnConnectionLost: true,
        maxReconnectAttempts: 3,
        reconnectBackoff: Duration.zero,
      ),
    ))
        .getOrNull()!;
    native
      ..connectReturnsZero = true
      ..globalStructuredError = StructuredError(
        sqlState: '08001'.codeUnits,
        nativeCode: 1,
        message: 'Server unavailable',
      );
    final result = await repository.executeQuery(conn.id, 'SELECT 1');
    expect(result.isError(), isTrue);
    expect(native.connects, 4);
    expect(
      (result.exceptionOrNull()! as OdbcError).details.secondaryErrors,
      isNotEmpty,
    );
  });

  test('should_return_failure_when_multi_backend_returns_null', () async {
    final native = _RecoveryNative();
    final repository = OdbcRepositoryImpl(native);
    addTearDown(repository.dispose);
    final conn = (await repository.connect('DSN=fake')).getOrNull()!;
    expect(
      (await repository.executeQueryMultiFull(conn.id, 'bad SQL')).isError(),
      isTrue,
    );
  });

  test('should_clear_options_after_pool_lifecycle', () async {
    final repository = OdbcRepositoryImpl(_RecoveryNative());
    addTearDown(repository.dispose);
    for (var i = 1; i <= 100; i++) {
      final conn = (await repository.poolGetConnection(
        i,
        options: const ConnectionOptions(queryTimeout: Duration(seconds: 1)),
      ))
          .getOrNull()!;
      await repository.poolReleaseConnection(conn.id);
      await repository.poolClose(i);
    }
    expect(repository.dartSideMetrics().connectionCount, 0);
    expect(repository.dartSideMetrics().connectionOptionsCount, 0);
  });
}
