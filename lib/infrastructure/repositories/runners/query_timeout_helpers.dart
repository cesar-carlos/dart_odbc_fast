import 'dart:async';

/// Applies [queryTimeout] to [source], yielding [onTimeoutItem] and cancelling
/// the underlying subscription so native cleanup runs.
Stream<T> streamWithQueryTimeout<T>({
  required Stream<T> source,
  required Duration? queryTimeout,
  required T onTimeoutItem,
}) async* {
  if (queryTimeout == null || queryTimeout == Duration.zero) {
    yield* source;
    return;
  }

  StreamSubscription<T>? subscription;
  final controller = StreamController<T>();
  Timer? timer;
  var done = false;

  void finish() {
    if (done) {
      return;
    }
    done = true;
    timer?.cancel();
    if (!controller.isClosed) {
      unawaited(controller.close());
    }
    unawaited(subscription?.cancel());
  }

  timer = Timer(queryTimeout, () {
    if (done) {
      return;
    }
    controller.add(onTimeoutItem);
    finish();
  });

  subscription = source.listen(
    controller.add,
    onError: (Object error, StackTrace stackTrace) {
      if (!controller.isClosed) {
        controller.addError(error, stackTrace);
      }
      finish();
    },
    onDone: finish,
    cancelOnError: true,
  );

  try {
    yield* controller.stream;
  } finally {
    finish();
  }
}
