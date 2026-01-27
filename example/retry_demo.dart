import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

/// Retry usage demo: connect and execute with automatic retry
/// on transient errors.
///
/// Uses [OdbcService.withRetry] and [RetryOptions] to retry on retryable
/// [OdbcError]s (e.g. connection timeouts, SQLSTATE 08xxx).
///
/// Prerequisites: Set ODBC_TEST_DSN in environment or .env.
/// Run: dart run example/retry_demo.dart
Future<void> main() async {
  print('=== ODBC Fast - Retry Demo ===\n');

  final dsn = Platform.environment['ODBC_TEST_DSN'];
  if (dsn == null || dsn.isEmpty) {
    print('Set ODBC_TEST_DSN to run this demo.');
    return;
  }

  final locator = ServiceLocator()..initialize();
  await locator.service.initialize();

  final service = locator.service;

  final connResult = await service.withRetry(
    () => service.connect(dsn),
    options: const RetryOptions(
      maxDelay: Duration(seconds: 10),
    ),
  );

  if (connResult.fold((_) => false, (_) => true)) {
    print('Connect failed (with retries).');
    return;
  }

  final conn = connResult.getOrElse((_) => throw StateError('no conn'));

  final queryResult = await service.withRetry(
    () => service.executeQuery(conn.id, 'SELECT 1 AS n'),
    options: RetryOptions.defaultOptions,
  );

  queryResult.fold(
    (qr) => print('Query result: ${qr.rows}'),
    (_) => print('Query failed'),
  );

  await service.disconnect(conn.id);
  print('\nDemo completed.');
}
