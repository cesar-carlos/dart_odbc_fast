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

  @override
  void teardown() {}
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
  final initBench = InitBenchmark();
  print('Init benchmark:');
  initBench.report();

  final connString = Platform.environment['ODBC_TEST_DSN'] ?? '';
  if (connString.isNotEmpty) {
    final connectBench = ConnectBenchmark(connString);
    print('Connect benchmark:');
    connectBench.report();
  }
}
