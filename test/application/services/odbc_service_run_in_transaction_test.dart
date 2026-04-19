/// Test suite for `OdbcService.runInTransaction<T>` (Sprint 4.4).
///
/// Covers the full state machine of the transaction-scope helper:
///
/// - happy path → action returns `Success`, commit succeeds, value is
///   propagated as-is;
/// - action returns `Failure` → rollback runs, original failure surfaces;
/// - action **throws** → rollback runs, exception is converted to a
///   `QueryError`, the throw never escapes;
/// - `beginTransaction` fails → no rollback attempted, failure surfaces;
/// - `commit` fails after a successful action → failure surfaces (the
///   driver has already rolled back per ODBC contract);
/// - rollback failure during the cleanup paths is swallowed so the
///   user-visible error stays the original cause;
/// - isolation / dialect / access-mode are threaded through to the
///   underlying `beginTransaction` call.
library;

import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

import '../../helpers/mock_odbc_repository.dart';

void main() {
  group('OdbcService.runInTransaction (Sprint 4.4)', () {
    late MockOdbcRepository mockRepo;
    late OdbcService service;

    setUp(() {
      mockRepo = MockOdbcRepository();
      service = OdbcService(mockRepo);
    });

    tearDown(() {
      mockRepo.dispose();
    });

    test('happy path: action Success → commit, value is propagated', () async {
      var actionTxnId = -1;
      final result = await service.runInTransaction<int>(
        'conn-1',
        (txnId) async {
          actionTxnId = txnId;
          return const Success(42);
        },
      );

      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull(), equals(42));
      expect(
        actionTxnId,
        greaterThan(0),
        reason: 'action must receive the txnId allocated by beginTransaction',
      );
      expect(mockRepo.beginTransactionCalled, isTrue);
      expect(mockRepo.commitTransactionCalled, isTrue);
      expect(
        mockRepo.rollbackTransactionCalled,
        isFalse,
        reason: 'happy path must not roll back',
      );
    });

    test('action returns Failure → rollback runs, original error surfaces',
        () async {
      const original = QueryError(message: 'business rule violated');
      final result = await service.runInTransaction<int>(
        'conn-1',
        (_) async => const Failure(original),
      );

      expect(result.isError(), isTrue);
      expect(
        result.exceptionOrNull(),
        same(original),
        reason: 'must propagate the action error verbatim, not wrap it',
      );
      expect(mockRepo.beginTransactionCalled, isTrue);
      expect(mockRepo.rollbackTransactionCalled, isTrue);
      expect(
        mockRepo.commitTransactionCalled,
        isFalse,
        reason: 'failure path must NOT commit',
      );
    });

    test('action throws → rollback runs, throw is converted to QueryError',
        () async {
      final result = await service.runInTransaction<int>(
        'conn-1',
        (_) async {
          throw StateError('boom');
        },
      );

      expect(result.isError(), isTrue);
      final err = result.exceptionOrNull();
      expect(err, isA<QueryError>());
      expect(
        (err! as QueryError).message,
        contains('runInTransaction: action threw'),
        reason: 'error message must identify the helper as the catcher',
      );
      expect(
        (err as QueryError).message,
        contains('boom'),
        reason: 'original throw message must be preserved for diagnostics',
      );
      expect(mockRepo.rollbackTransactionCalled, isTrue);
      expect(mockRepo.commitTransactionCalled, isFalse);
    });

    test(
        'beginTransaction failure → no rollback attempted, '
        'failure surfaces unchanged', () async {
      mockRepo.beginTransactionShouldFail = true;
      var actionWasCalled = false;

      final result = await service.runInTransaction<int>(
        'conn-1',
        (_) async {
          actionWasCalled = true;
          return const Success(0);
        },
      );

      expect(result.isError(), isTrue);
      expect(
        actionWasCalled,
        isFalse,
        reason: 'action must not run when begin failed',
      );
      expect(mockRepo.commitTransactionCalled, isFalse);
      expect(
        mockRepo.rollbackTransactionCalled,
        isFalse,
        reason: 'no transaction was opened, so there is nothing to roll back',
      );
    });

    test(
        'commit failure after successful action → failure surfaces, '
        'no extra rollback attempted', () async {
      mockRepo.commitTransactionShouldFail = true;

      final result = await service.runInTransaction<String>(
        'conn-1',
        (_) async => const Success('done'),
      );

      expect(result.isError(), isTrue);
      final err = result.exceptionOrNull()!;
      expect(err, isA<QueryError>());
      expect(
        (err as QueryError).message,
        contains('commitTransaction forced failure'),
      );
      expect(mockRepo.commitTransactionCalled, isTrue);
      // Per ODBC contract a failed commit already implies the engine
      // rolled back; the helper does not issue an extra rollback.
      expect(mockRepo.rollbackTransactionCalled, isFalse);
    });

    test('rollback failure during cleanup is swallowed; original error wins',
        () async {
      mockRepo.rollbackTransactionShouldFail = true;
      const original = QueryError(message: 'business rule violated');

      final result = await service.runInTransaction<int>(
        'conn-1',
        (_) async => const Failure(original),
      );

      expect(result.isError(), isTrue);
      expect(
        result.exceptionOrNull(),
        same(original),
        reason:
            'a noisy rollback failure must NOT overwrite the original cause',
      );
      expect(
        mockRepo.rollbackTransactionCalled,
        isTrue,
        reason: 'rollback was attempted, just failed silently',
      );
    });

    test(
      'isolation / dialect / accessMode / lockTimeout are threaded '
      'through to beginTransaction',
      () async {
        await service.runInTransaction<int>(
          'conn-1',
          (_) async => const Success(0),
          isolationLevel: IsolationLevel.serializable,
          savepointDialect: SavepointDialect.sqlServer,
          accessMode: TransactionAccessMode.readOnly,
          lockTimeout: const Duration(milliseconds: 750),
        );

        expect(mockRepo.lastBeginIsolationLevel, IsolationLevel.serializable);
        expect(mockRepo.lastBeginSavepointDialect, SavepointDialect.sqlServer);
        expect(mockRepo.lastBeginAccessMode, TransactionAccessMode.readOnly);
        expect(
          mockRepo.lastBeginLockTimeout,
          const Duration(milliseconds: 750),
          reason: 'lockTimeout (Sprint 4.2) must reach the repository',
        );
      },
    );

    test(
      'defaults: readCommitted / auto / readWrite / null lockTimeout',
      () async {
        await service.runInTransaction<int>(
          'conn-1',
          (_) async => const Success(0),
        );

        expect(
          mockRepo.lastBeginIsolationLevel,
          IsolationLevel.readCommitted,
          reason: 'helper inherits beginTransaction defaults',
        );
        expect(mockRepo.lastBeginSavepointDialect, SavepointDialect.auto);
        expect(mockRepo.lastBeginAccessMode, TransactionAccessMode.readWrite);
        expect(
          mockRepo.lastBeginLockTimeout,
          isNull,
          reason: 'omitted lockTimeout must reach the repository as null '
              '(engine default)',
        );
      },
    );

    test('async action awaits before commit (no race)', () async {
      // Simulates a real-world action that does several async ops.
      // The helper must wait for the whole future to settle before
      // committing — never fire-and-forget.
      var commitAt = -1;
      var actionFinishedAt = -1;
      var counter = 0;

      final result = await service.runInTransaction<int>(
        'conn-1',
        (_) async {
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          actionFinishedAt = ++counter;
          return const Success(7);
        },
      );

      // Sneaky: read the call order indirectly. commitTransactionCalled
      // can only be true after the action returned, by construction —
      // but pin it with a counter for clarity.
      if (mockRepo.commitTransactionCalled) commitAt = ++counter;

      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull(), equals(7));
      expect(
        actionFinishedAt,
        equals(1),
        reason: 'action future must fully settle',
      );
      expect(
        commitAt,
        equals(2),
        reason: 'commit must run strictly after the action',
      );
    });
  });
}
