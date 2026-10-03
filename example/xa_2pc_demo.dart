// XA through Result services: one decision per branch, no automatic recovery.
// Run: dart run example/xa_2pc_demo.dart
// Requires a driver/native build with XA support.
// Optional: ODBC_XA_ONE_PHASE=1 (only one participating resource manager),
// ODBC_XA_SQL (statement inside the branch), ODBC_XA_RECOVER_ONLY=1.
// Oracle needs DML for a meaningful prepared branch; supply suitable SQL.
// The transaction manager must durably record the XID and its decision.

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() =>
    withExampleConnection((locator, service, connection) async {
      if (Platform.environment['ODBC_XA_RECOVER_ONLY'] == '1') {
        final branches = (await service.xaRecover(connection.id)).getOrThrow();
        for (final xid in branches) {
          reportExampleProgress('Prepared branch: $xid');
        }
        reportExampleProgress(
          'Recovery listing only; no decision was applied.',
        );
        // A transaction manager can explicitly call xaResumePrepared with an
        // original XID, then apply its durable commit/rollback decision once.
        // Never commit every branch returned by xaRecover.
        return;
      }

      final xid = Xid.fromStrings(
        gtrid: 'odbc-demo-${DateTime.now().microsecondsSinceEpoch}',
        bqual: 'branch-1',
      );
      reportExampleProgress('Starting branch: $xid');
      final result = await service.runInXaTransaction<int>(
        connection.id,
        xid,
        (handle) async {
          final sql =
              Platform.environment['ODBC_XA_SQL'] ?? 'SELECT 1 AS value';
          final query =
              await service.executeQuery(sql, connectionId: connection.id);
          return query.map((rows) => rows.rowCount);
        },
        onePhase: Platform.environment['ODBC_XA_ONE_PHASE'] == '1',
      );
      reportExampleProgress('XA committed: rows=${result.getOrThrow()}');
      // Manual phases inside the callback are tracked by the handle. Helpers
      // respect commitAttempted/outcomeUnknown and do not reverse uncertain
      // phases.
      // Xid.fromStrings uses UTF-8 (64-byte parts). Recover old non-ASCII XIDs
      // with the exact original bytes via Xid, not re-encoded strings.
    });
