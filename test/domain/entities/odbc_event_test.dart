/// Unit tests for the [OdbcEvent] sealed surface and its variants.
library;

import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcEvent variants', () {
    final ts = DateTime.utc(2026, 5, 26);

    test('ConnectionLost preserves connectionId and reason', () {
      const reason = ConnectionError(
        message: 'socket reset',
        sqlState: '08S01',
      );
      final e = ConnectionLost(
        timestamp: ts,
        connectionId: 'conn-1',
        reason: reason,
      );
      expect(e.connectionId, equals('conn-1'));
      expect(e.reason, isA<ConnectionError>());
      expect(e.timestamp, equals(ts));
    });

    test('WorkerRecovered carries only the timestamp', () {
      final e = WorkerRecovered(timestamp: ts);
      expect(e.timestamp, equals(ts));
    });

    test('AutoReconnectAttempted preserves attempt counters', () {
      final e = AutoReconnectAttempted(
        timestamp: ts,
        connectionId: 'conn-2',
        attempt: 2,
        maxAttempts: 5,
      );
      expect(e.attempt, equals(2));
      expect(e.maxAttempts, equals(5));
      expect(e.connectionId, equals('conn-2'));
    });

    test('PoolResize captures both old and new size', () {
      final e = PoolResize(
        timestamp: ts,
        poolId: 1,
        oldSize: 4,
        newSize: 8,
      );
      expect(e.poolId, equals(1));
      expect(e.oldSize, equals(4));
      expect(e.newSize, equals(8));
    });

    test('SlowQueryDetected preserves SQL and duration', () {
      final e = SlowQueryDetected(
        timestamp: ts,
        connectionId: 'conn-3',
        sql: 'SELECT * FROM big_table',
        durationMs: 1500,
      );
      expect(e.sql, contains('big_table'));
      expect(e.durationMs, equals(1500));
    });
  });

  group('OdbcEvent toString overrides', () {
    final ts = DateTime.utc(2026, 5, 26, 12);

    test('ConnectionLost.toString includes connectionId and reason type', () {
      final e = ConnectionLost(
        timestamp: ts,
        connectionId: 'conn-abc',
        reason: const ConnectionError(message: 'reset', sqlState: '08S01'),
      );
      final repr = e.toString();
      expect(repr, contains('ConnectionLost'));
      expect(repr, contains('conn-abc'));
      expect(repr, contains('ConnectionError'));
      expect(repr, contains('2026-05-26'));
    });

    test('WorkerRecovered.toString includes timestamp', () {
      final e = WorkerRecovered(timestamp: ts);
      final repr = e.toString();
      expect(repr, startsWith('WorkerRecovered'));
      expect(repr, contains('2026-05-26'));
    });

    test('AutoReconnectAttempted.toString includes attempt fraction', () {
      final e = AutoReconnectAttempted(
        timestamp: ts,
        connectionId: 'conn-x',
        attempt: 2,
        maxAttempts: 7,
      );
      final repr = e.toString();
      expect(repr, contains('AutoReconnectAttempted'));
      expect(repr, contains('conn-x'));
      expect(repr, contains('2/7'));
    });

    test('PoolResize.toString reflects capacity transition', () {
      final e = PoolResize(
        timestamp: ts,
        poolId: 42,
        oldSize: 4,
        newSize: 16,
      );
      final repr = e.toString();
      expect(repr, contains('PoolResize'));
      expect(repr, contains('poolId: 42'));
      expect(repr, contains('4 -> 16'));
    });

    test('SlowQueryDetected.toString keeps short SQL verbatim', () {
      final e = SlowQueryDetected(
        timestamp: ts,
        connectionId: 'conn-1',
        sql: 'SELECT 1',
        durationMs: 250,
      );
      final repr = e.toString();
      expect(repr, contains('SlowQueryDetected'));
      expect(repr, contains('conn-1'));
      expect(repr, contains('"SELECT 1"'));
      expect(repr, contains('250ms'));
      expect(repr, isNot(contains('...')));
    });

    test('SlowQueryDetected.toString truncates SQL longer than 80 chars', () {
      final longSql = 'SELECT ${'x' * 200} FROM t';
      final e = SlowQueryDetected(
        timestamp: ts,
        connectionId: 'conn-1',
        sql: longSql,
        durationMs: 1000,
      );
      final repr = e.toString();
      expect(repr, contains('...'));
      expect(repr.length, lessThan(longSql.length + 50));
    });
  });

  group('OdbcEvent sealed exhaustiveness', () {
    String describe(OdbcEvent e) {
      // Pattern-match exhaustively so the analyzer enforces that every
      // variant is handled. Fails to compile if a new variant is added
      // without updating this test.
      return switch (e) {
        ConnectionLost() => 'lost',
        WorkerRecovered() => 'recovered',
        AutoReconnectAttempted() => 'retry',
        PoolResize() => 'resize',
        SlowQueryDetected() => 'slow',
      };
    }

    test('switch covers all variants', () {
      final ts = DateTime.utc(2026);
      expect(
        describe(
          ConnectionLost(
            timestamp: ts,
            connectionId: 'a',
            reason: const ConnectionError(message: 'x'),
          ),
        ),
        equals('lost'),
      );
      expect(describe(WorkerRecovered(timestamp: ts)), equals('recovered'));
      expect(
        describe(
          AutoReconnectAttempted(
            timestamp: ts,
            connectionId: 'a',
            attempt: 1,
            maxAttempts: 3,
          ),
        ),
        equals('retry'),
      );
      expect(
        describe(
          PoolResize(timestamp: ts, poolId: 1, oldSize: 1, newSize: 2),
        ),
        equals('resize'),
      );
      expect(
        describe(
          SlowQueryDetected(
            timestamp: ts,
            connectionId: 'a',
            sql: '',
            durationMs: 0,
          ),
        ),
        equals('slow'),
      );
    });
  });
}
