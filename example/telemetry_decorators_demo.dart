// Narrow telemetry decorators via [TelemetryOdbcDecorators].
//
// Prefer capability-scoped factories (`query`, `pool`, `transaction`, `admin`)
// when a consumer depends on a sub-interface ([IQueryService], [IPoolService],
// etc.) instead of wrapping the full [IOdbcService] aggregate with
// [TelemetryOdbcServiceDecorator].
//
// Run: dart run example/telemetry_decorators_demo.dart
//
// DSN-free — exercises initialize/admin and records trace names even when
// downstream ODBC calls fail without a live connection.

import 'package:odbc_fast/odbc_fast.dart';

class _InMemoryTelemetryRepository implements ITelemetryRepository {
  final traces = <Trace>[];

  @override
  Future<void> exportTrace(Trace trace) async => traces.add(trace);

  @override
  Future<void> exportSpan(Span span) async {}

  @override
  Future<void> exportMetric(Metric metric) async {}

  @override
  Future<void> exportEvent(TelemetryEvent event) async {}

  @override
  Future<void> updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {}

  @override
  Future<void> updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}

Future<void> main() async {
  AppLogger.initialize();

  final telemetryRepo = _InMemoryTelemetryRepository();
  final telemetry = SimpleTelemetryService(telemetryRepo);

  final locator = ServiceLocator()..initialize();
  final inner = locator.service;

  // Each factory returns only the sub-interface the consumer needs, with
  // telemetry scoped to that capability's operations.
  final queries = TelemetryOdbcDecorators.query(inner, telemetry);
  final pools = TelemetryOdbcDecorators.pool(inner, telemetry);
  final transactions = TelemetryOdbcDecorators.transaction(inner, telemetry);
  final admin = TelemetryOdbcDecorators.admin(inner, telemetry);

  await admin.initialize();
  await queries.executeQueryParamValues('demo-conn', 'SELECT 1', const []);
  await pools.poolCreate('DSN=demo', 2);
  await transactions.beginTransaction('demo-conn');

  final traceNames = telemetryRepo.traces.map((t) => t.name).toList();
  print('Recorded ${traceNames.length} operation traces:');
  for (final name in traceNames) {
    print('  $name');
  }

  locator.shutdown();
}
