// Transaction helpers demo (NEW in v3.1).
//
// Showcases the new safety APIs added in v3.1:
//   - `SavepointDialect.auto` is the default; the engine resolves it to
//     `SAVEPOINT` (SQL-92) or `SAVE TRANSACTION` (SQL Server) via SQLGetInfo.
//   - `TransactionHandle.runWithBegin(...)` runs a closure inside a fresh
//     transaction, committing on success and rolling back on any thrown
//     exception. No more manual try/finally to remember.
//   - `TransactionHandle.withSavepoint(name, action)` wraps a partial unit of
//     work in a named savepoint with the same try/commit/rollback discipline.
//
// Run: dart run example/transaction_helpers_demo.dart
//
// This demo can run **without** a database when there is no `EXAMPLE_DSN` —
// it just prints the wire codes for `SavepointDialect`. With a DSN it
// performs a small commit / rollback / savepoint round-trip.

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  AppLogger.info('=== SavepointDialect wire codes ===');
  for (final d in SavepointDialect.values) {
    AppLogger.info('  ${d.name.padRight(10)} -> code=${d.code}');
  }

  final dsn = requireExampleDsn();
  if (dsn == null) {
    AppLogger.info(
      'EXAMPLE_DSN not set; skipping live transaction parts. '
      'Set EXAMPLE_DSN to run the round-trip.',
    );
    return;
  }

  final native = OdbcNative();
  if (!native.init()) {
    AppLogger.severe('Failed to init native engine');
    return;
  }

  final connId = native.connect(dsn);
  if (connId == 0) {
    AppLogger.severe('Failed to connect: ${native.getError()}');
    native.dispose();
    return;
  }

  final conn = NativeOdbcConnection()..initialize();

  try {
    AppLogger.info('--- runWithBegin: commit on success ---');
    final commitedValue = await TransactionHandle.runWithBegin(
      () => conn.beginTransactionHandle(
        connId,
        IsolationLevel.readCommitted.value,
      ),
      (txn) async {
        AppLogger.info('  txnId=${txn.txnId} active=${txn.isActive}');
        // Any work inside this closure participates in the transaction.
        return 'value-from-action';
      },
    );
    AppLogger.info('  closure returned: $commitedValue');

    AppLogger.info('--- runWithBegin: rollback on exception ---');
    try {
      await TransactionHandle.runWithBegin(
        () => conn.beginTransactionHandle(
          connId,
          IsolationLevel.readCommitted.value,
        ),
        (txn) async {
          AppLogger.info('  txnId=${txn.txnId} (will throw)');
          throw StateError('simulated business-rule violation');
        },
      );
    } on Object catch (e) {
      AppLogger.info('  caught: $e (transaction was auto-rolled back)');
    }

    AppLogger.info('--- explicit dialect (SqlServer) on a non-SQL-Server ---');
    AppLogger.info(
      '  begin txn with savepointDialect=${SavepointDialect.sqlServer.code} '
      'forces SAVE TRANSACTION syntax even if the engine is not SQL Server. '
      'Use only when you really know what you are doing.',
    );

    AppLogger.info('--- withSavepoint usage ---');
    await TransactionHandle.runWithBegin(
      () => conn.beginTransactionHandle(
        connId,
        IsolationLevel.readCommitted.value,
      ),
      (txn) async {
        try {
          await txn.withSavepoint('sp_inner', () async {
            AppLogger.info('  inside savepoint sp_inner');
            // Simulate failure inside the savepoint.
            throw StateError('inner failure');
          });
        } on Object catch (e) {
          AppLogger.info(
            '  caught inner: $e (savepoint rolled back, txn still active)',
          );
        }
        AppLogger.info('  outer txn continues; commit will succeed');
      },
    );
  } finally {
    native
      ..disconnect(connId)
      ..dispose();
  }
}
