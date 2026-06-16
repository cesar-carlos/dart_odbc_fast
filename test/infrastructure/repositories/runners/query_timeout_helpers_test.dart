import 'dart:async';

import 'package:odbc_fast/infrastructure/repositories/runners/query_timeout_helpers.dart';
import 'package:test/test.dart';

void main() {
  group('streamWithQueryTimeout', () {
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
