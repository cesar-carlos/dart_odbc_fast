import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:odbc_fast/odbc_fast.dart';

/// Measures repeated [IOdbcService.initialize] after [ServiceLocator] setup.
///
/// Later iterations are often near-no-op when the native engine is already
/// initialized; use as a local smoke signal, not a cross-machine contract.
class OdbcInitBenchmark extends AsyncBenchmarkBase {
  OdbcInitBenchmark() : super('ODBC Init');
  late ServiceLocator locator;

  @override
  Future<void> setup() async {
    locator = ServiceLocator();
    locator.initialize();
  }

  @override
  Future<void> run() async {
    await locator.service.initialize();
  }
}

/// Measures connect + disconnect per iteration against [connectionString].
class OdbcConnectBenchmark extends AsyncBenchmarkBase {
  OdbcConnectBenchmark(this.connectionString) : super('ODBC Connect');
  late ServiceLocator locator;
  final String connectionString;

  @override
  Future<void> setup() async {
    locator = ServiceLocator();
    locator.initialize();
    await locator.service.initialize();
  }

  @override
  Future<void> run() async {
    final result = await locator.service.connect(connectionString);
    if (result.isSuccess()) {
      await locator.service.disconnect(result.getOrNull()!.id);
    }
  }
}
