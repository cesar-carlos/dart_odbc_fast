import 'dart:async';

import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/odbc_error_translator.dart';
import 'package:result_dart/result_dart.dart';

/// Per-operation diagnostics. Each repository invocation owns a separate zone.
class NativeCallContext {
  NativeCallContext._();

  static final Object _key = Object();
  OdbcError? failure;
  int? completionStatus;
  bool receivedResponse = false;

  static NativeCallContext? get current =>
      Zone.current[_key] as NativeCallContext?;

  static Future<Result<T>> run<T extends Object>(
    String operation,
    Future<Result<T>> Function() action,
  ) async {
    final context = NativeCallContext._();
    try {
      final result = await runZoned(action, zoneValues: {_key: context});
      final pending = context.failure;
      if (pending != null) {
        final primary = result.exceptionOrNull();
        if (primary is OdbcError && !identical(primary, pending)) {
          return Failure(primary.withSecondary(pending));
        }
        return Failure(pending);
      }
      return result;
    } on AsyncError catch (error, stack) {
      throw translateOdbcError(
        error,
        operation: operation,
        stackTrace: stack,
      );
    }
  }

  int? nativeConnectionId;
  static T capture<T>(T Function() action, {int? nativeConnectionId}) =>
      runZoned(
        action,
        zoneValues: {
          _key: NativeCallContext._()..nativeConnectionId = nativeConnectionId,
        },
      );

  static Stream<T> stream<T>(Stream<T> Function() source) {
    final context = NativeCallContext._();
    final zone = Zone.current.fork(zoneValues: {_key: context});
    StreamSubscription<T>? subscription;
    late StreamController<T> controller;
    controller = StreamController<T>(
      onListen: () => zone.run(() {
        subscription = source().listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      }),
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  static OdbcError? takeFailure() {
    final context = current;
    final failure = context?.failure;
    if (context != null) context.failure = null;
    return failure;
  }

  static void record(OdbcError error) {
    final context = current;
    if (context == null) return;
    context.failure = context.failure?.withSecondary(error) ?? error;
  }
}
