import 'dart:async';

import 'package:odbc_fast/infrastructure/repositories/runners/query_timeout_helpers.dart';
import 'package:test/test.dart';

void main() {
  group('streamWithQueryTimeout', () {
    test('should_forward_pause_resume_and_timeout_during_pause', () async {
      var pauses = 0;
      var resumes = 0;
      var cancels = 0;
      final source = StreamController<int>(
        onPause: () {
          pauses++;
        },
        onResume: () {
          resumes++;
        },
        onCancel: () {
          cancels++;
        },
      );
      final values = <int>[];
      final done = Completer<void>();
      final sub = streamWithQueryTimeout(
        source: source.stream,
        queryTimeout: const Duration(milliseconds: 40),
        onTimeoutItem: -1,
      ).listen(values.add, onDone: done.complete);
      source.add(1);
      await Future<void>.delayed(Duration.zero);
      sub.pause();
      expect(pauses, 1);
      sub.resume();
      await Future<void>.delayed(Duration.zero);
      expect(resumes, 1);
      sub.pause();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(cancels, 1);
      expect(values, [1]);
      sub.resume();
      await done.future;
      await sub.cancel();
      expect(values, [1, -1]);
      expect(cancels, 1);
    });

    test('should_cancel_source_exactly_once_and_discard_late_events', () async {
      var cancels = 0;
      final source = StreamController<int>(
        onCancel: () {
          cancels++;
        },
      );
      final values = <int>[];
      final sub = streamWithQueryTimeout(
        source: source.stream,
        queryTimeout: const Duration(seconds: 1),
        onTimeoutItem: -1,
      ).listen(values.add);
      await sub.cancel();
      source.add(2);
      await Future<void>.delayed(Duration.zero);
      expect(cancels, 1);
      expect(values, isEmpty);
    });

    test('should_pass_through_when_timeout_is_null', () async {
      final values = await streamWithQueryTimeout<int>(
        source: Stream<int>.fromIterable([1, 2, 3]),
        queryTimeout: null,
        onTimeoutItem: -1,
      ).toList();

      expect(values, [1, 2, 3]);
    });

    test('should_emit_timeout_item_and_cancel_source', () async {
      final controller = StreamController<int>();
      var cancelled = false;

      final timed = streamWithQueryTimeout<int>(
        source: controller.stream,
        queryTimeout: const Duration(milliseconds: 20),
        onTimeoutItem: -1,
      );

      final values = <int>[];
      final done = Completer<void>();
      timed.listen(
        values.add,
        onDone: () {
          if (!done.isCompleted) {
            done.complete();
          }
        },
      );

      controller.onCancel = () {
        cancelled = true;
      };

      await done.future.timeout(const Duration(seconds: 1));
      expect(values, [-1]);
      expect(cancelled, isTrue);
    });
  });
}
