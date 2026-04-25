import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcMetrics', () {
    test('stores engine counters', () {
      const metrics = OdbcMetrics(
        queryCount: 10,
        errorCount: 2,
        uptimeSecs: 60,
        totalLatencyMillis: 500,
        avgLatencyMillis: 50,
      );

      expect(metrics.queryCount, 10);
      expect(metrics.errorCount, 2);
      expect(metrics.uptimeSecs, 60);
      expect(metrics.totalLatencyMillis, 500);
      expect(metrics.avgLatencyMillis, 50);
    });
  });

  group('PreparedStatementMetrics', () {
    test('parses little-endian binary metrics payload', () {
      final bytes = ByteData(64)
        ..setUint64(0, 4, Endian.little)
        ..setUint64(8, 16, Endian.little)
        ..setUint64(16, 30, Endian.little)
        ..setUint64(24, 10, Endian.little)
        ..setUint64(32, 8, Endian.little)
        ..setUint64(40, 40, Endian.little)
        ..setUint64(48, 2048, Endian.little)
        ..setFloat64(56, 5, Endian.little);

      final metrics = PreparedStatementMetrics.fromBytes(
        bytes.buffer.asUint8List(),
      );

      expect(metrics.cacheSize, 4);
      expect(metrics.cacheMaxSize, 16);
      expect(metrics.cacheHits, 30);
      expect(metrics.cacheMisses, 10);
      expect(metrics.totalPrepares, 8);
      expect(metrics.totalExecutions, 40);
      expect(metrics.memoryUsageBytes, 2048);
      expect(metrics.avgExecutionsPerStmt, 5.0);
    });

    test('calculates cache rates and utilization', () {
      const metrics = PreparedStatementMetrics(
        cacheSize: 5,
        cacheMaxSize: 10,
        cacheHits: 8,
        cacheMisses: 2,
        totalPrepares: 3,
        totalExecutions: 12,
        memoryUsageBytes: 1024,
        avgExecutionsPerStmt: 4,
      );

      expect(metrics.totalCacheAccesses, 10);
      expect(metrics.cacheHitRate, 80.0);
      expect(metrics.cacheMissRate, 20.0);
      expect(metrics.cacheUtilization, 50.0);
    });

    test('returns zero rates when denominators are zero', () {
      const metrics = PreparedStatementMetrics(
        cacheSize: 0,
        cacheMaxSize: 0,
        cacheHits: 0,
        cacheMisses: 0,
        totalPrepares: 0,
        totalExecutions: 0,
        memoryUsageBytes: 0,
        avgExecutionsPerStmt: 0,
      );

      expect(metrics.totalCacheAccesses, isZero);
      expect(metrics.cacheHitRate, isZero);
      expect(metrics.cacheMissRate, isZero);
      expect(metrics.cacheUtilization, isZero);
    });
  });
}
