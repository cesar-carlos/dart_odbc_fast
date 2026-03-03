/// Unit tests for [TelemetryBuffer] and [TelemetryBatch].
library;

import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:odbc_fast/infrastructure/native/telemetry/telemetry_buffer.dart';
import 'package:test/test.dart';

void main() {
  group('TelemetryBuffer', () {
    late TelemetryBuffer buffer;

    setUp(() {
      buffer = TelemetryBuffer(
        batchSize: 5,
        flushInterval: const Duration(hours: 1),
      );
    });

    tearDown(() {
      buffer.dispose();
    });

    test('size is zero initially', () {
      expect(buffer.size, 0);
      expect(buffer.traceCount, 0);
      expect(buffer.spanCount, 0);
      expect(buffer.metricCount, 0);
      expect(buffer.eventCount, 0);
    });

    test('addTrace increases size and returns shouldFlush', () {
      final trace = Trace(
        traceId: 't1',
        name: 'op',
        startTime: DateTime.now(),
      );
      final shouldFlush = buffer.addTrace(trace);
      expect(buffer.size, 1);
      expect(buffer.traceCount, 1);
      expect(shouldFlush, false);
    });

    test('addSpan increases spanCount', () {
      final span = Span(
        spanId: 's1',
        name: 'span',
        startTime: DateTime.now(),
      );
      buffer.addSpan(span);
      expect(buffer.spanCount, 1);
    });

    test('addMetric increases metricCount', () {
      final metric = Metric(
        name: 'm1',
        value: 1,
        unit: 'count',
        timestamp: DateTime.now(),
      );
      buffer.addMetric(metric);
      expect(buffer.metricCount, 1);
    });

    test('addEvent increases eventCount', () {
      final event = TelemetryEvent(
        name: 'e1',
        timestamp: DateTime.now(),
        severity: TelemetrySeverity.info,
        message: 'msg',
      );
      buffer.addEvent(event);
      expect(buffer.eventCount, 1);
    });

    test('flush returns batch and clears buffer', () {
      buffer.addTrace(
        Trace(
          traceId: 't1',
          name: 'op',
          startTime: DateTime.now(),
        ),
      );
      final batch = buffer.flush();
      expect(batch.traces.length, 1);
      expect(batch.traces[0].traceId, 't1');
      expect(buffer.size, 0);
    });

    test('flush when empty returns empty batch', () {
      final batch = buffer.flush();
      expect(batch.isEmpty, true);
      expect(batch.size, 0);
    });

    test('addTrace returns true when batchSize reached', () {
      for (var i = 0; i < 5; i++) {
        final shouldFlush = buffer.addTrace(
          Trace(
            traceId: 't$i',
            name: 'op',
            startTime: DateTime.now(),
          ),
        );
        if (i == 4) {
          expect(shouldFlush, true);
        }
      }
    });
  });

  group('TelemetryBatch', () {
    test('empty creates batch with zero size', () {
      final batch = TelemetryBatch.empty();
      expect(batch.isEmpty, true);
      expect(batch.size, 0);
    });

    test('batch with items has correct size', () {
      final batch = TelemetryBatch(
        traces: [
          Trace(
            traceId: 't1',
            name: 'op',
            startTime: DateTime.now(),
          ),
        ],
        spans: [],
        metrics: [],
        events: [],
      );
      expect(batch.isEmpty, false);
      expect(batch.size, 1);
    });
  });
}
