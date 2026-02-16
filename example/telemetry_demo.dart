// Telemetry service + buffer demo (no database required).
// Run: dart run example/telemetry_demo.dart

import 'package:odbc_fast/odbc_fast.dart';

class _InMemoryTelemetryRepository implements ITelemetryRepository {
  final traces = <Trace>[];
  final spans = <Span>[];
  final metrics = <Metric>[];
  final events = <TelemetryEvent>[];

  @override
  Future<void> exportEvent(TelemetryEvent event) async => events.add(event);

  @override
  Future<void> exportMetric(Metric metric) async => metrics.add(metric);

  @override
  Future<void> exportSpan(Span span) async => spans.add(span);

  @override
  Future<void> exportTrace(Trace trace) async => traces.add(trace);

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}

  @override
  Future<void> updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {}

  @override
  Future<void> updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {}
}

Future<void> main() async {
  AppLogger.initialize();

  final repo = _InMemoryTelemetryRepository();
  final ITelemetryService telemetry = SimpleTelemetryService(repo);

  final trace = telemetry.startTrace('example.telemetry');
  final span = telemetry.startSpan(
    parentId: trace.traceId,
    spanName: 'example.telemetry.span',
    initialAttributes: {'component': 'demo'},
  );

  await telemetry.recordMetric(
    name: 'demo.counter',
    metricType: 'counter',
    value: 1,
    attributes: {'source': 'example'},
  );
  await telemetry.recordGauge(
    name: 'demo.gauge',
    value: 7,
  );
  await telemetry.recordTiming(
    name: 'demo.duration',
    duration: const Duration(milliseconds: 12),
  );
  await telemetry.recordEvent(
    name: 'demo.event',
    severity: TelemetrySeverity.info,
    message: 'Telemetry demo event',
  );

  await telemetry.endSpan(spanId: span.spanId);
  await telemetry.endTrace(traceId: trace.traceId);
  await telemetry.flush();
  await telemetry.shutdown();

  final buffer = TelemetryBuffer(
    batchSize: 2,
    flushInterval: const Duration(days: 1),
  )
    ..addMetric(
      Metric(
        name: 'buffer.metric',
        value: 1,
        unit: 'count',
        timestamp: DateTime.now().toUtc(),
      ),
    )
    ..addEvent(
      TelemetryEvent(
        name: 'buffer.event',
        severity: TelemetrySeverity.info,
        message: 'buffered',
        timestamp: DateTime.now().toUtc(),
      ),
    );

  final batch = buffer.flush();
  buffer.dispose();

  AppLogger.info(
    'Telemetry demo exported traces=${repo.traces.length} '
    'spans=${repo.spans.length} metrics=${repo.metrics.length} '
    'events=${repo.events.length}',
  );
  AppLogger.info('TelemetryBuffer flushed items=${batch.size}');
}
