import 'dart:io';
import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:odbc_fast/odbc_fast.dart';

class InitBenchmark extends BenchmarkBase {

  InitBenchmark() : super('ODBC Init');
  late ServiceLocator locator;

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

  ConnectBenchmark(this.connectionString) : super('ODBC Connect');
  late ServiceLocator locator;
  final String connectionString;

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
