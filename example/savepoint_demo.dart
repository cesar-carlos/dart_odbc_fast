// Savepoints inside a service-managed transaction, with checked Result values.
// Run: dart run example/savepoint_demo.dart

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() =>
    withExampleConnection((locator, service, connection) async {
      final result = await service.runInTransaction(
        connection.id,
        (transactionId) async {
          (await service.createSavepoint(
            connection.id,
            transactionId,
            'before_optional_work',
          ))
              .getOrThrow();
          (await service.executeQuery(
            'SELECT 1 AS optional_value',
            connectionId: connection.id,
          ))
              .getOrThrow();
          (await service.rollbackToSavepoint(
            connection.id,
            transactionId,
            'before_optional_work',
          ))
              .getOrThrow();
          // Some dialects cannot release savepoints; leave release to
          // transaction
          // completion. Do not assume rollback succeeded just because it was
          // sent.
          return service.executeQuery(
            'SELECT 2 AS final_value',
            connectionId: connection.id,
          );
        },
        savepointDialect: SavepointDialect.auto,
      );
      reportExampleProgress(
        'Committed after savepoint: rows=${result.getOrThrow().rowCount}',
      );
    });
