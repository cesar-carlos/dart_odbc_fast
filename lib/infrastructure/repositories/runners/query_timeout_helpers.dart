import 'dart:async';

import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';

/// Total deadline measured from subscription, including consumer pauses.
Stream<T> streamWithQueryTimeout<T>({
  required Stream<T> source,
  required Duration? queryTimeout,
  required T onTimeoutItem,
  T Function(T primary, Object error, StackTrace stack)? onCleanupError,
}) {
  if (queryTimeout == null || queryTimeout == Duration.zero) return source;
  StreamSubscription<T>? subscription;
  late StreamController<T> controller;
  Timer? timer;
  var done = false;
  Future<void>? cancellation;

  Future<void> cancelSource() =>
      cancellation ??= subscription?.cancel() ?? Future<void>.value();

  void finish() {
    if (done) return;
    done = true;
    timer?.cancel();
    unawaited(controller.close());
  }

  controller = StreamController<T>(
    onListen: () {
      timer = Timer(queryTimeout, () {
        if (done) return;
        done = true;
        unawaited(() async {
          var item = onTimeoutItem;
          try {
            await cancelSource();
          } on Object catch (error, stack) {
            final enrich = onCleanupError;
            if (enrich != null) {
              item = enrich(item, error, stack);
            } else {
              AppLogger.warning(
                'Stream cancellation failed after timeout',
                error,
                stack,
              );
            }
          } finally {
            controller.add(item);
            unawaited(controller.close());
          }
        }());
      });
      subscription = source.listen(
        (value) {
          if (!done) controller.add(value);
        },
        onError: (Object error, StackTrace stack) {
          if (done) return;
          done = true;
          timer?.cancel();
          unawaited(() async {
            var primary = error;
            try {
              await cancelSource();
            } on Object catch (cleanup, trace) {
              primary = normalizeOdbcError(
                error,
                operation: 'streamQuery',
                stackTrace: stack,
              ).withSecondary(
                normalizeOdbcError(
                  cleanup,
                  operation: 'streamCleanup',
                  stackTrace: trace,
                ),
              );
            }
            controller.addError(primary, stack);
            unawaited(controller.close());
          }());
        },
        onDone: finish,
        cancelOnError: false,
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () {
      done = true;
      timer?.cancel();
      return cancelSource();
    },
  );
  return controller.stream;
}
