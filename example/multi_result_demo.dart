// Small responses: buffered typed parameters and coalesced multi-result stream.
// Large cursors: multi_result_batches_demo.dart.
// Run: dart run example/multi_result_demo.dart
// Requires multi-statement parameter support (e.g. SQL Server).

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() =>
    withExampleConnection((locator, service, connection) async {
      const sql = 'SELECT CAST(? AS INTEGER) AS first_id; SELECT CAST(? AS '
          'INTEGER) AS second_id;';
      const params = [ParamValueInt32(1), ParamValueInt32(2)];
      final buffered = (await service.executeQueryMultiParamValues(
        connection.id,
        sql,
        params,
      ))
          .getOrThrow();
      reportExampleProgress('Buffered logical items=${buffered.items.length}');
      var items = 0;
      await for (final result in service.streamQueryMultiParamValues(
        connection.id,
        sql,
        params,
        chunkSize: locator.recommendedStreamChunkSizeBytes,
      )) {
        final item = result.getOrThrow();
        items++;
        reportExampleProgress(
          'item=$items resultRows=${item.resultSet?.rowCount} '
          'affectedRows=${item.rowCount}',
        );
      }
      // One item per cursor; memory is not bounded by fetchSize in this API.
      reportExampleProgress('Coalesced logical items=$items');
    });
