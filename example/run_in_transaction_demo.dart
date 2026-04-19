// `IOdbcService.runInTransaction<T>` demo (NEW in Sprint 4.4).
//
// Showcases the high-level transaction-scope helper added in
// `IOdbcService`. The helper captures the begin → action → commit /
// rollback dance behind a single call so application code never has to
// manage the `txnId` lifecycle by hand.
//
// Demonstrated:
//
//   1. Happy path → action returns Success → commit, value propagated.
//   2. Failure path → action returns Failure → rollback, original error
//      propagated verbatim.
//   3. Throw path → action throws → caught + converted to QueryError +
//      rollback (the throw never escapes the helper).
//   4. Threading the new transaction options (TransactionAccessMode +
//      Duration lockTimeout — Sprints 4.1 / 4.2) through the same call.
//
// Run: dart run example/run_in_transaction_demo.dart
//
// Requires `EXAMPLE_DSN` (or `ODBC_TEST_DSN`) pointing at any supported
// engine. Without a DSN the demo prints a friendly skip message.

import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    AppLogger.info(
      'EXAMPLE_DSN not set; skipping live demo. '
      'Set EXAMPLE_DSN in .env to see runInTransaction in action.',
    );
    return;
  }

  final native = NativeOdbcConnection();
  final repository = OdbcRepositoryImpl(native);
  final IOdbcService service = OdbcService(repository);

  await service.initialize();
  final connectResult = await service.connect(dsn);
  if (connectResult.isError()) {
    AppLogger.severe('Connect failed: ${connectResult.exceptionOrNull()}');
    return;
  }
  final connId = connectResult.getOrThrow().id;
  AppLogger.info('Connected: $connId');

  try {
    // -----------------------------------------------------------------
    // 1. Happy path: action returns Success → commit, value propagated.
    // -----------------------------------------------------------------
    AppLogger.info('--- 1. Happy path ---');
    final happy = await service.runInTransaction<int>(
      connId,
      (txnId) async {
        AppLogger.info('  inside txn $txnId — running a SELECT');
        final r = await service.executeQueryParams(
          connId,
          'SELECT 42',
          const <Object?>[],
        );
        if (r.isError()) return Failure(r.exceptionOrNull()!);
        return const Success(42);
      },
    );
    final happyView = happy.isSuccess()
        ? '${happy.getOrNull()}'
        : '${happy.exceptionOrNull()}';
    AppLogger.info('  result: $happyView');

    // -----------------------------------------------------------------
    // 2. Failure path: action returns Failure → rollback, original
    //    error surfaces verbatim. The QueryError below is what your
    //    business layer would propagate.
    // -----------------------------------------------------------------
    AppLogger.info('--- 2. Action returns Failure → rollback ---');
    final businessFailure = await service.runInTransaction<int>(
      connId,
      (_) async => const Failure(QueryError(message: 'business rule violated')),
    );
    AppLogger.info('  surfaced: ${businessFailure.exceptionOrNull()}');
    AppLogger.info('  (the engine rolled back; nothing was persisted)');

    // -----------------------------------------------------------------
    // 3. Throw path: action throws → helper catches, rolls back, and
    //    converts the throw into a QueryError with the original
    //    type/message preserved. The throw NEVER escapes runInTransaction.
    // -----------------------------------------------------------------
    AppLogger.info('--- 3. Action throws → caught + converted ---');
    final throwResult = await service.runInTransaction<int>(
      connId,
      (_) async {
        throw StateError('simulated bug — division by zero, etc.');
      },
    );
    AppLogger.info('  surfaced: ${throwResult.exceptionOrNull()}');
    AppLogger.info('  (no exception escaped; engine rolled back)');

    // -----------------------------------------------------------------
    // 4. Threading the Sprint 4.1 / 4.2 options through the helper.
    //
    // `accessMode: readOnly` advertises read-only intent (PostgreSQL /
    // MySQL skip locking; SQL Server / SQLite silently no-op).
    //
    // `lockTimeout: Duration(seconds: 2)` caps how long any statement
    // inside the transaction waits for a lock. Sub-second values round
    // up to 1s on engines that natively express waits in seconds
    // (MySQL/MariaDB/DB2).
    // -----------------------------------------------------------------
    AppLogger.info('--- 4. Threading accessMode + lockTimeout ---');
    final readOnlyResult = await service.runInTransaction<String>(
      connId,
      (txnId) async {
        AppLogger.info('  inside read-only txn $txnId');
        return const Success('ok');
      },
      isolationLevel: IsolationLevel.repeatableRead,
      savepointDialect: SavepointDialect.auto,
      accessMode: TransactionAccessMode.readOnly,
      lockTimeout: const Duration(seconds: 2),
    );
    final view =
        readOnlyResult.getOrNull() ?? readOnlyResult.exceptionOrNull();
    AppLogger.info('  result: $view');
  } finally {
    await service.disconnect(connId);
    AppLogger.info('Disconnected.');
  }
}
