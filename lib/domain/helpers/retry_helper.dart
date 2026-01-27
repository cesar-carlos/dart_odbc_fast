import 'package:odbc_fast/domain/entities/retry_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:result_dart/result_dart.dart';

/// Helper for retrying operations with exponential backoff.
///
/// Use [execute] to run an operation and retry on retryable [OdbcError]s
/// according to [RetryOptions].
class RetryHelper {
  RetryHelper._();

  /// Executes [operation] with retries and exponential backoff on retryable failures.
  ///
  /// Uses [options.shouldRetry] or [OdbcError.isRetryable] when the failure
  /// is an [OdbcError]. Non-[OdbcError] exceptions are not retried.
  /// Delays between attempts follow [options.initialDelay], [options.backoffMultiplier],
  /// and [options.maxDelay].
  static Future<Result<T>> execute<T extends Object>(
    Future<Result<T>> Function() operation,
    RetryOptions options,
  ) async {
    var attempt = 1;
    var delay = options.initialDelay;
    Result<T> result = await operation();

    while (true) {
      final err = result.exceptionOrNull();
      if (err == null) return result;

      if (attempt >= options.maxAttempts) return result;

      final retry = err is OdbcError &&
          (options.shouldRetry?.call(err) ?? err.isRetryable);
      if (!retry) return result;

      await Future<void>.delayed(delay);
      final nextMs = (delay.inMilliseconds * options.backoffMultiplier).round();
      delay = Duration(
        milliseconds: nextMs.clamp(0, options.maxDelay.inMilliseconds),
      );
      attempt++;
      result = await operation();
    }
  }
}
