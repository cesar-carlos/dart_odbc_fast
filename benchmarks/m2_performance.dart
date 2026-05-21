import 'dart:io';

import 'odbc_async_benchmarks.dart';

Future<void> main() async {
  final connString = Platform.environment['ODBC_TEST_DSN'] ?? '';
  if (connString.isEmpty) {
    print('Skipping benchmarks: ODBC_TEST_DSN not set');
    print('\n=== M2 Performance Benchmarks ===\n');
    print('Note: Full benchmarks require ODBC_TEST_DSN environment variable');
    return;
  }

  print('=== M2 Performance Benchmarks ===\n');

  final initBench = OdbcInitBenchmark();
  print('Init benchmark:');
  await initBench.report();

  final connectBench = OdbcConnectBenchmark(connString);
  print('\nConnect benchmark:');
  await connectBench.report();

  print('\nNote: Streaming and pool benchmarks require async setup');
  print('See test/stress/ for full stress testing');
}
