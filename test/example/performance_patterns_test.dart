import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

import '../../example/common.dart';
import '../../example/typed_columnar_demo.dart';

void main() {
  group('bounded example tasks', () {
    test('should_limit_concurrency_and_run_each_task_once', () async {
      var active = 0;
      var peak = 0;
      final visited = <int>[];
      await runBoundedExampleTasks(100, 3, (index) async {
        active++;
        if (active > peak) peak = active;
        visited.add(index);
        await Future<void>.delayed(Duration.zero);
        active--;
      });
      expect(peak, 3);
      expect(active, 0);
      expect(visited, orderedEquals(List.generate(100, (index) => index)));
    });

    test('should_stop_new_work_and_drain_active_tasks_before_failing',
        () async {
      final gate = Completer<void>();
      final error = StateError('workload failed');
      final started = <int>[];
      var drained = false;
      final work = runBoundedExampleTasks(20, 2, (index) async {
        started.add(index);
        if (index == 0) throw error;
        await gate.future;
        drained = true;
      });
      // Observe failure before yielding, avoiding an unhandled error.
      final assertion = expectLater(work, throwsA(same(error)));
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1]);
      expect(drained, isFalse);
      gate.complete();
      await assertion;
      expect(drained, isTrue);
      expect(started, [0, 1]);
    });

    test('should_allow_empty_work_and_reject_invalid_bounds', () async {
      await runBoundedExampleTasks(0, 2, (_) async => fail('No work expected'));
      await expectLater(
        runBoundedExampleTasks(-1, 2, (_) async {}),
        throwsArgumentError,
      );
      await expectLater(
        runBoundedExampleTasks(1, 0, (_) async {}),
        throwsArgumentError,
      );
    });

    test('should_start_only_needed_workers_when_count_is_below_limit',
        () async {
      final visited = <int>[];
      await runBoundedExampleTasks(2, 100, (index) async => visited.add(index));
      expect(visited, [0, 1]);
    });
  });

  group('numeric column consumption', () {
    test('should_skip_float_nulls_and_match_column_names_ignoring_case', () {
      final result = TypedColumnarResult(
        rowCount: 3,
        columns: [
          TypedColumnFloat64(
            name: 'SCORE',
            values: Float64List.fromList([1.5, 999, 2.5]),
            nullBitmap: Uint8List.fromList([2]),
          ),
        ],
      );
      expect(sumNonNullScores(result), 4);
    });

    test('should_handle_integer_arrays_and_empty_results', () {
      final int32 = TypedColumnarResult(
        rowCount: 3,
        columns: [
          TypedColumnInt32(
            name: 'score',
            values: Int32List.fromList([5, 999, -2]),
            nullBitmap: Uint8List.fromList([2]),
          ),
        ],
      );
      final int64 = TypedColumnarResult(
        rowCount: 1,
        columns: [
          TypedColumnInt64(
            name: 'score',
            values: Int64List.fromList([5000000000]),
            nullBitmap: Uint8List(1),
          ),
        ],
      );
      final empty = TypedColumnarResult(
        rowCount: 0,
        columns: [
          TypedColumnFloat64(
            name: 'score',
            values: Float64List(0),
            nullBitmap: Uint8List(0),
          ),
        ],
      );
      expect(sumNonNullScores(int32), 3);
      expect(sumNonNullScores(int64), 5000000000);
      expect(sumNonNullScores(empty), 0);
    });

    test('should_preserve_integer_precision_above_double_exact_range', () {
      final large = int.parse('9007199254740993');
      final result = TypedColumnarResult(
        rowCount: 2,
        columns: [
          TypedColumnInt64(
            name: 'score',
            values: Int64List.fromList([large, 1]),
            nullBitmap: Uint8List(1),
          ),
        ],
      );
      expect(sumNonNullScores(result), large + 1);
      expect(sumNonNullScores(result), isA<int>());
    });

    test('should_reject_missing_or_string_backed_numeric_columns', () {
      final missing = TypedColumnarResult(columns: [], rowCount: 0);
      final strings = TypedColumnarResult(
        rowCount: 1,
        columns: [
          TypedColumnObject<String>(
            name: 'score',
            kind: TypedColumnKind.decimal,
            values: ['1.5'],
          ),
        ],
      );
      expect(() => sumNonNullScores(missing), throwsStateError);
      expect(() => sumNonNullScores(strings), throwsStateError);
    });
  });

  test('should_report_cleanup_without_throwing_or_exposing_driver_text',
      () async {
    final previousExitCode = exitCode;
    final previousLogger = AppLogger.logger;
    final messages = <String>[];
    // stderr is the CLI presentation channel; verify the logger's messages too.
    final subscription = AppLogger.logger.onRecord.listen(
      (record) => messages.add(record.message),
    );
    try {
      reportExampleCleanup(
        const Failure(
          QueryError(
            message: 'private SQL/driver text',
            details: OdbcErrorDetails(operation: 'poolReleaseConnection'),
          ),
        ),
        'release',
      );
      await Future<void>.delayed(Duration.zero);
      expect(exitCode, 1);
      expect(messages.join(), contains('poolReleaseConnection'));
      expect(messages.join(), isNot(contains('private SQL/driver text')));
      expect(AppLogger.logger, same(previousLogger));
    } finally {
      exitCode = previousExitCode;
      await subscription.cancel();
    }
  });
}
