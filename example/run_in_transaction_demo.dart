// Group related statements in one transaction; commit once after success.
// Run: dart run example/run_in_transaction_demo.dart
// A failed or uncertain commit must not trigger an automatic retry/rollback.

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() =>
    withExampleConnection((locator, service, connection) async {
      final result = await locator.transactionService.runInTransactionFor(
        connection,
        (transactionId) async {
          // Every operation uses the same connection and transaction.
          return locator.queryService.executeQueryFor(
            connection,
            'SELECT 42 AS value',
          );
        },
        isolationLevel: IsolationLevel.readCommitted,
      );
      final rows = result.getOrThrow();
      reportExampleProgress('Committed: rows=${rows.rowCount}');
      // Result failures retain primary/cleanup errors in OdbcError.details.
      // A timeout can leave outcomeUnknown=true; wait for reconciliation or
      // explicitly close the connection. Do not repeat a transactional
      // decision.
    });
