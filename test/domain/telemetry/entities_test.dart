import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:test/test.dart';

void main() {
  group('Trace', () {
    test('copyWith preserves values by default and replaces provided values',
        () {
      final start = DateTime.utc(2026);
      final end = DateTime.utc(2026, 1, 1, 0, 0, 1);
      final trace = Trace(
        traceId: 'trace-1',
        name: 'odbc.query',
        startTime: start,
        attributes: const {'db.system': 'odbc'},
      );

      final unchanged = trace.copyWith();
      final changed = trace.copyWith(
        endTime: end,
        attributes: const {'status': 'ok'},
      );

      expect(unchanged.traceId, trace.traceId);
      expect(unchanged.name, trace.name);
      expect(unchanged.startTime, start);
      expect(unchanged.attributes, trace.attributes);
      expect(changed.endTime, end);
      expect(changed.attributes, {'status': 'ok'});
      expect(trace.toString(), 'Trace(traceId: trace-1, name: odbc.query)');
    });
  });

  group('Span', () {
    test('copyWith updates end time, parent id and attributes', () {
      final start = DateTime.utc(2026);
      final end = DateTime.utc(2026, 1, 1, 0, 0, 2);
      final span = Span(
        spanId: 'span-1',
        traceId: 'trace-1',
        name: 'execute',
        startTime: start,
        duration: const Duration(milliseconds: 12),
      );

      final copy = span.copyWith(
        endTime: end,
        parentSpanId: 'parent-1',
        attributes: const {'rows': '1'},
      );

      expect(copy.spanId, 'span-1');
      expect(copy.traceId, 'trace-1');
      expect(copy.endTime, end);
      expect(copy.parentSpanId, 'parent-1');
      expect(copy.duration, const Duration(milliseconds: 12));
      expect(copy.attributes, {'rows': '1'});
      expect(span.toString(), contains('duration: 12ms'));
      expect(span.toString(), contains('parent: none'));
    });
  });

  group('Metric and TelemetryEvent', () {
    test('store values and produce diagnostic strings', () {
      final timestamp = DateTime.utc(2026);
      final metric = Metric(
        name: 'query.count',
        value: 3,
        unit: 'count',
        timestamp: timestamp,
        attributes: const {'pool': 'main'},
      );
      final event = TelemetryEvent(
        name: 'query.failed',
        severity: TelemetrySeverity.error,
        message: 'failed',
        timestamp: timestamp,
        context: const {'sql_state': '42000'},
      );

      expect(metric.timestamp, timestamp);
      expect(metric.toString(), contains('query.count'));
      expect(metric.toString(), contains('pool: main'));
      expect(event.context, {'sql_state': '42000'});
      expect(event.toString(), contains('TelemetrySeverity.error'));
    });
  });

  group('OdbcTelemetryAttributes', () {
    test('exposes stable attribute keys', () {
      expect(OdbcTelemetryAttributes.sql, 'odbc.sql');
      expect(OdbcTelemetryAttributes.connectionId, 'odbc.connection_id');
      expect(OdbcTelemetryAttributes.statementId, 'odbc.statement_id');
      expect(OdbcTelemetryAttributes.parameterCount, 'odbc.parameter_count');
      expect(OdbcTelemetryAttributes.rowCount, 'odbc.row_count');
      expect(OdbcTelemetryAttributes.errorCode, 'odbc.error_code');
      expect(OdbcTelemetryAttributes.errorType, 'odbc.error_type');
      expect(OdbcTelemetryAttributes.errorMessage, 'odbc.error_message');
      expect(OdbcTelemetryAttributes.cacheStatus, 'odbc.cache_status');
      expect(OdbcTelemetryAttributes.poolId, 'odbc.pool_id');
      expect(OdbcTelemetryAttributes.driverName, 'odbc.driver_name');
      expect(OdbcTelemetryAttributes.dsn, 'odbc.dsn');
      expect(OdbcTelemetryAttributes.timeoutMs, 'odbc.timeout_ms');
      expect(OdbcTelemetryAttributes.fetchSize, 'odbc.fetch_size');
      expect(OdbcTelemetryAttributes.bulkOperationType,
          'odbc.bulk_operation_type',);
      expect(OdbcTelemetryAttributes.transactionId, 'odbc.transaction_id');
      expect(OdbcTelemetryAttributes.isolationLevel, 'odbc.isolation_level');
      expect(OdbcTelemetryAttributes.retryCount, 'odbc.retry_count');
      expect(OdbcTelemetryAttributes.retryAttempt, 'odbc.retry_attempt');
      expect(OdbcTelemetryAttributes.queryHash, 'odbc.query_hash');
      expect(OdbcTelemetryAttributes.cacheSize, 'odbc.cache_size');
      expect(OdbcTelemetryAttributes.cacheMaxSize, 'odbc.cache_max_size');
      expect(OdbcTelemetryAttributes.memoryUsage, 'odbc.memory_usage');
    });
  });
}
