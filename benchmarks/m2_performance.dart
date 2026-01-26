import 'dart:io';
import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:odbc_fast/odbc_fast.dart';

class InitBenchmark extends BenchmarkBase {
  late ServiceLocator locator;

  InitBenchmark() : super('ODBC Init');

  @override
  void setup() {
    locator = ServiceLocator();
    locator.initialize();
  }

  @override
  void run() {
    locator.service.initialize();
  }
}

class ConnectBenchmark extends BenchmarkBase {
  late ServiceLocator locator;
  final String connectionString;

  ConnectBenchmark(this.connectionString) : super('ODBC Connect');

  @override
  void setup() {
    locator = ServiceLocator();
    locator.initialize();
    locator.service.initialize();
  }

  @override
  void run() {
    locator.service.connect(connectionString);
  }
}

void main() {
  final connString = Platform.environment['ODBC_TEST_DSN'] ?? '';
  if (connString.isEmpty) {
    print('Skipping benchmarks: ODBC_TEST_DSN not set');
    print('\n=== M2 Performance Benchmarks ===\n');
    print('Note: Full benchmarks require ODBC_TEST_DSN environment variable');
    return;
  }

  print('=== M2 Performance Benchmarks ===\n');

  final initBench = InitBenchmark();
  print('Init benchmark:');
  initBench.report();

  final connectBench = ConnectBenchmark(connString);
  print('\nConnect benchmark:');
  connectBench.report();

  print('\nNote: Streaming and pool benchmarks require async setup');
  print('See test/stress/ for full stress testing');
}
