// Low-level polling API: sentinels/exceptions, explicit disposal.
// Application code should prefer Result services in streaming_demo.dart.
// Run: dart run example/execute_async_demo.dart
// Optional: ODBC_ASYNC_QUERY (read-only, default SELECT 1 AS id).

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:odbc_fast/odbc_fast_native.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();
  final dsn = requireExampleDsn();
  if (dsn == null) return;
  final native = AsyncNativeOdbcConnection(
    requestTimeout: const Duration(seconds: 30),
    maxPendingRequests: 32,
    backpressureMode: AsyncBackpressureMode.waitForSlot,
    onDiagnostic: (error) => AppLogger.warning(
      '${error.code.name}: ${error.userMessage} '
      '(request=${error.details.requestId})',
    ),
  );
  var connectionId = 0;
  try {
    if (!await native.initialize()) {
      throw StateError('Native initialization did not succeed.');
    }
    connectionId = await native.connect(dsn);
    if (connectionId == 0) {
      throw StateError('Native connection did not succeed.');
    }
    final query = Platform.environment['ODBC_ASYNC_QUERY'] ?? 'SELECT 1 AS id';
    final raw = await native.executeAsync(connectionId, query);
    if (raw == null) throw StateError('Native execution returned failure.');
    final buffered = BinaryProtocolParser.parse(raw);
    reportExampleProgress('executeAsync bufferedRows=${buffered.rowCount}');
    var rows = 0;
    var batches = 0;
    await for (final batch in native.streamAsync(
      connectionId,
      query,
      chunkSize: 1024 * 1024,
    )) {
      rows += batch.rowCount;
      batches++;
    }
    reportExampleProgress('streamAsync rows=$rows batches=$batches');
  } on Object catch (error, stackTrace) {
    reportExampleError(error, 'executeAsync');
    AppLogger.fine('Native example failure stack: $stackTrace');
  } finally {
    try {
      if (connectionId != 0 && !await native.disconnect(connectionId)) {
        reportExampleError(
          StateError('Disconnect not confirmed.'),
          'disconnect',
        );
      }
    } on Object catch (error, stackTrace) {
      reportExampleError(error, 'disconnect');
      AppLogger.fine('Disconnect failure stack: $stackTrace');
    } finally {
      native.dispose();
    }
  }
  // API timeout does not prove driver cancellation; do not replay SQL.
}
