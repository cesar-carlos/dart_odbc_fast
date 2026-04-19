// Streaming multi-result demo (M8 in v3.3.0).
//
// Shows how `IOdbcService.streamQueryMulti` surfaces every result set and
// row-count from a batch one-by-one, instead of materialising the whole
// batch in memory. Each item arrives as soon as the engine produces it.
//
// Run: dart run example/multi_result_stream_demo.dart

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
    return;
  }

  try {
    // SQL Server batch with mixed cursors and row-counts. v3.3.0 surfaces
    // every item; pre-v3.2 used to silently drop trailing items.
    const sql = '''
      SELECT 1 AS a;
      SELECT 'two' AS b;
      SELECT 3.14 AS c;
    ''';

    AppLogger.info('Streaming multi-result for: ${sql.trim()}');
    var index = 0;
    await for (final result in service.streamQueryMulti(conn.id, sql)) {
      result.fold(
        (item) {
          if (item.isResultSet) {
            final rs = item.resultSet!;
            AppLogger.info(
              '[$index] result-set rows=${rs.rowCount} columns=${rs.columns}',
            );
          } else {
            AppLogger.info('[$index] row-count=${item.rowCount}');
          }
          index++;
        },
        (err) => AppLogger.severe('stream failure: $err'),
      );
    }
    AppLogger.info('Done. Total items streamed: $index');
  } finally {
    final disc = await service.disconnect(conn.id);
    disc.fold(
      (_) => AppLogger.info('Disconnected'),
      (e) => AppLogger.warning('Disconnect failed: $e'),
    );
  }
}
