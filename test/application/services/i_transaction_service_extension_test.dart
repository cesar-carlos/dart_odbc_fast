/// Unit tests for [ITransactionServiceConnectionOverloads].
library;

import 'package:odbc_fast/application/services/i_transaction_service.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

class _FakeTransactionService implements ITransactionService {
  String? capturedConnectionId;
  IsolationLevel? capturedIsolationLevel;
  SavepointDialect? capturedSavepointDialect;
  TransactionAccessMode? capturedAccessMode;
  Duration? capturedLockTimeout;
  int? capturedTxnId;
  Future<Result<Object>> Function(int)? capturedAction;

  @override
  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) async {
    capturedConnectionId = connectionId;
    capturedIsolationLevel = isolationLevel;
    capturedSavepointDialect = savepointDialect;
    capturedAccessMode = accessMode;
    capturedLockTimeout = lockTimeout;
    return const Success(1);
  }

  @override
  Future<Result<void>> commitTransaction(String connectionId, int txnId) async {
    capturedConnectionId = connectionId;
    capturedTxnId = txnId;
    return const Success('');
  }

  @override
  Future<Result<void>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async {
    capturedConnectionId = connectionId;
    capturedTxnId = txnId;
    return const Success('');
  }

  @override
  Future<Result<T>> runInTransaction<T extends Object>(
    String connectionId,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) async {
    capturedConnectionId = connectionId;
    capturedIsolationLevel = isolationLevel;
    capturedSavepointDialect = savepointDialect;
    capturedAccessMode = accessMode;
    capturedLockTimeout = lockTimeout;
    capturedAction = action as Future<Result<Object>> Function(int);
    return action(99);
  }
}

void main() {
  late _FakeTransactionService fake;
  final conn = Connection(
    id: 'conn-7',
    connectionString: 'DSN=test',
    createdAt: DateTime.utc(2026),
  );

  setUp(() {
    fake = _FakeTransactionService();
  });

  group('ITransactionServiceConnectionOverloads.beginTransactionFor', () {
    test('should_forward_connection_id_and_default_optional_args', () async {
      await fake.beginTransactionFor(conn);
      expect(fake.capturedConnectionId, equals('conn-7'));
      expect(fake.capturedIsolationLevel, isNull);
      expect(fake.capturedSavepointDialect, isNull);
      expect(fake.capturedAccessMode, isNull);
      expect(fake.capturedLockTimeout, isNull);
    });

    test('should_forward_all_optional_args_when_provided', () async {
      await fake.beginTransactionFor(
        conn,
        isolationLevel: IsolationLevel.serializable,
        savepointDialect: SavepointDialect.sql92,
        accessMode: TransactionAccessMode.readOnly,
        lockTimeout: const Duration(seconds: 5),
      );
      expect(fake.capturedIsolationLevel, equals(IsolationLevel.serializable));
      expect(fake.capturedSavepointDialect, equals(SavepointDialect.sql92));
      expect(fake.capturedAccessMode, equals(TransactionAccessMode.readOnly));
      expect(fake.capturedLockTimeout, equals(const Duration(seconds: 5)));
    });
  });

  group('ITransactionServiceConnectionOverloads.runInTransactionFor', () {
    test('should_invoke_action_with_txnId_and_propagate_result', () async {
      final result = await fake.runInTransactionFor<int>(
        conn,
        (txnId) async => Success(txnId * 2),
      );
      expect(result.getOrNull(), equals(198));
      expect(fake.capturedConnectionId, equals('conn-7'));
    });

    test('should_forward_all_options_to_underlying_runInTransaction', () async {
      await fake.runInTransactionFor<int>(
        conn,
        (_) async => const Success(0),
        isolationLevel: IsolationLevel.repeatableRead,
        savepointDialect: SavepointDialect.sqlServer,
        accessMode: TransactionAccessMode.readWrite,
        lockTimeout: const Duration(seconds: 2),
      );
      expect(
        fake.capturedIsolationLevel,
        equals(IsolationLevel.repeatableRead),
      );
      expect(
        fake.capturedSavepointDialect,
        equals(SavepointDialect.sqlServer),
      );
      expect(fake.capturedAccessMode, equals(TransactionAccessMode.readWrite));
      expect(fake.capturedLockTimeout, equals(const Duration(seconds: 2)));
    });
  });
}
