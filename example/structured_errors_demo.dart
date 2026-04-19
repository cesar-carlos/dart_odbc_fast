// Structured error handling — 12+ typed Dart classes (v3.0).
// Run: dart run example/structured_errors_demo.dart
//
// No database required — exercises every concrete `OdbcError` subclass
// added since v1, including the seven new variants from v3.0.

import 'package:odbc_fast/odbc_fast.dart';

void main() {
  AppLogger.initialize();

  AppLogger.info('--- v1 error classes --------------------------------');
  _show(
    const ConnectionError(message: 'TCP connect failed', sqlState: '08S01'),
  );
  _show(
    const QueryError(message: 'syntax error near "FORM"', sqlState: '42601'),
  );
  _show(const ValidationError(message: 'fetchSize must be > 0'));
  _show(
    const UnsupportedFeatureError(
      message: 'Statement cancellation is not active in this build',
      sqlState: '0A000',
    ),
  );
  _show(const EnvironmentNotInitializedError());

  AppLogger.info('');
  AppLogger.info('--- v3.0 error classes ------------------------------');
  _show(const NoMoreResultsError());
  _show(const MalformedPayloadError(message: 'truncated null bitmap'));
  _show(
    const RollbackFailedError(
      message: 'rollback failed: deadlock victim',
      sqlState: '40001',
    ),
  );
  _show(const ResourceLimitReachedError(message: 'pool exhausted'));
  _show(const CancelledError());
  _show(const WorkerCrashedError(message: 'worker disconnected mid-stream'));
  _show(
    const BulkPartialFailureError(
      rowsInsertedBeforeFailure: 12_500,
      failedChunks: 2,
      detail: 'chunk[3]: timeout; chunk[7]: deadlock',
    ),
  );

  AppLogger.info('');
  AppLogger.info('--- Decision-making by category ---------------------');
  final examples = <OdbcError>[
    const ConnectionError(message: 'connection lost', sqlState: '08S01'),
    const QueryError(message: 'duplicate key', sqlState: '23505'),
    const ValidationError(message: 'bad parameter'),
    const ResourceLimitReachedError(message: 'pool full'),
    const WorkerCrashedError(message: 'worker died'),
  ];
  for (final e in examples) {
    final action = switch (e.category) {
      ErrorCategory.transient => 'retry with backoff',
      ErrorCategory.fatal => 'abort and surface to caller',
      ErrorCategory.validation => 'fix caller input — never retry',
      ErrorCategory.connectionLost => 'reconnect and retry once',
    };
    final type = e.runtimeType.toString().padRight(28);
    final cat = e.category.name.padRight(16);
    AppLogger.info('$type -> $cat -> $action');
  }
}

void _show(OdbcError e) {
  final type = e.runtimeType.toString().padRight(28);
  final cat = e.category.name.padRight(16);
  AppLogger.info('$type | category=$cat | $e');
}
