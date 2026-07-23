// Streaming multi-result demo (M8 in v3.3.0).
//
// Shows how `IOdbcService.streamQueryMulti` surfaces every logical result set
// and row-count from a batch one-by-one. Fetch batches that continue the same
// SQL cursor (wire tag 2) are coalesced into a single `QueryResultMultiItem`
// so the stream matches `executeQueryMultiFull` item counts. Row-major wire is
// always used; optional `fetchSize` / `chunkSize` (defaults 1000 / 64 KiB)
// forward to native when `*_options` exists and seed each `streamFetch`.
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
    // Defaults: fetchSize=1000, chunkSize=64 KiB. Override for large scans.
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
