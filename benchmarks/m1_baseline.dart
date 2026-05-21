import 'dart:io';

import 'odbc_async_benchmarks.dart';

Future<void> main() async {
  final initBench = OdbcInitBenchmark();
  print('Init benchmark:');
  await initBench.report();

  final connString = Platform.environment['ODBC_TEST_DSN'] ?? '';
  if (connString.isNotEmpty) {
    final connectBench = OdbcConnectBenchmark(connString);
    print('Connect benchmark:');
    await connectBench.report();
  }
}
