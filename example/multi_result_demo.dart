// Multi-result demo via the high-level service API.
//
// Uses `executeQueryMultiFull` and `executeQueryMultiParamValues`
// (`List<ParamValue>`). For the native wire path see
// `odbc_fast_native.dart` (`executeQueryMulti` / `executeQueryMultiParams`).
// Streaming item-by-item is covered by `multi_result_stream_demo.dart`
// (`streamQueryMulti` coalesces tag-2 batches so logical item counts match
// the buffered Full path).
//
// Run: dart run example/multi_result_demo.dart

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final locator = ServiceLocator()..initialize();
  final service = locator.syncService;

  final init = await service.initialize();
  if (init.isError()) {
    init.fold((_) {}, (e) => AppLogger.severe('Init failed: $e'));
    return;
  }

  final connResult = await service.connect(dsn);
  final conn = connResult.getOrNull();
  if (conn == null) {
    connResult.fold((_) {}, (e) => AppLogger.severe('Connect failed: $e'));
    locator.shutdown();
    return;
  }

  try {
    await _runMultiResultBatch(service, conn.id);
    await _runParameterizedMultiResultBatch(service, conn.id);
  } finally {
    await service.disconnect(conn.id);
    locator.shutdown();
    AppLogger.info('Disconnected');
  }
}

Future<void> _runMultiResultBatch(
  IOdbcService service,
  String connectionId,
) async {
  const sql = '''
    SELECT 1 AS id, 'Alice' AS name;
    SELECT 2 AS orders_count;
    SELECT 3 AS updated_rows;
  ''';

  final result = await service.executeQueryMultiFull(connectionId, sql);
  result.fold(
    (multi) {
      _logMultiResultItems(
        'Multi-result items (plain batch)',
        multi.items,
      );
      final first = multi.firstResultSetOrNull;
      if (first != null) {
        AppLogger.info('First result-set rowCount: ${first.rowCount}');
      } else {
        AppLogger.info('No result set in batch (only row-counts).');
      }
    },
    (error) => AppLogger.severe('Multi-result query failed: $error'),
  );
}

Future<void> _runParameterizedMultiResultBatch(
  IOdbcService service,
  String connectionId,
) async {
  const sql = '''
    SELECT ? AS first_a, ? AS first_b, ? AS first_optional;
    SELECT ? AS second_d, ? AS second_e, ? AS second_f;
  ''';

  final result = await service.executeQueryMultiParamValues(
    connectionId,
    sql,
    const <ParamValue>[
      ParamValueInt32(1),
      ParamValueInt32(2),
      ParamValueNull(),
      ParamValueInt32(4),
      ParamValueInt32(5),
      ParamValueInt32(6),
    ],
  );

  result.fold(
    (multi) => _logMultiResultItems(
      'Multi-result items (parameterized batch with >5 params)',
      multi.items,
    ),
    (error) => AppLogger.severe(
      'Parameterized multi-result query failed: $error',
    ),
  );
}

void _logMultiResultItems(
  String label,
  List<QueryResultMultiItem> items,
) {
  AppLogger.info('$label: ${items.length}');

  for (var i = 0; i < items.length; i++) {
    final item = items[i];

    if (item.isResultSet) {
      final rs = item.resultSet!;
      AppLogger.info(
        'Item $i => result-set '
        '(rows=${rs.rowCount}, columns=${rs.columns.length})',
      );
      for (final row in rs.rows) {
        AppLogger.fine('  Row: $row');
      }
      continue;
    }

    AppLogger.info('Item $i => row-count (${item.rowCount})');
  }
}
