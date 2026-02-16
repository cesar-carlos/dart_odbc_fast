// OpenTelemetry repository demo (optional backend).
// Run: dart run example/otel_repository_demo.dart
//
// This demo tries to initialize OTLP exporter via FFI. If endpoint is not
// available, it logs a warning and exits gracefully.

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

Future<void> main() async {
  AppLogger.initialize();

  final endpoint = Platform.environment['OTEL_EXPORTER_OTLP_ENDPOINT'] ??
      'http://localhost:4318';

  final ffi = OpenTelemetryFFI();
  final repo = TelemetryRepositoryImpl(
    ffi,
    batchSize: 10,
    flushInterval: const Duration(seconds: 2),
  );

  final init = await repo.initialize(otlpEndpoint: endpoint);
  if (init.isError()) {
    init.fold((_) {}, (e) {
      AppLogger.warning('Telemetry init failed for endpoint=$endpoint: $e');
    });
    return;
  }

  final trace = Trace(
    traceId: 'demo-trace-id',
    name: 'otel.repository.demo',
    startTime: DateTime.now().toUtc(),
    attributes: {'env': 'example'},
  );

  await repo.exportTrace(trace);
  await repo.exportMetric(
    Metric(
      name: 'otel.demo.metric',
      value: 1,
      unit: 'count',
      timestamp: DateTime.now().toUtc(),
      attributes: {'source': 'example'},
    ),
  );

  final flush = await repo.flush();
  flush.fold(
    (_) => AppLogger.info('Telemetry flush OK'),
    (e) => AppLogger.warning('Telemetry flush failed: $e'),
  );

  final shutdown = await repo.shutdown();
  shutdown.fold(
    (_) => AppLogger.info('Telemetry shutdown OK'),
    (e) => AppLogger.warning('Telemetry shutdown failed: $e'),
  );
}
