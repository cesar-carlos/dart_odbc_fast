import 'package:odbc_fast/domain/errors/odbc_error.dart';

/// Configuration for automatic retry with exponential backoff.
///
/// Used by [RetryHelper.execute] to decide when and how to retry failed operations.
class RetryOptions {
  const RetryOptions({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.backoffMultiplier = 2.0,
    this.shouldRetry,
  });

  /// Maximum number of attempts (including the first).
  final int maxAttempts;

  /// Delay before the first retry.
  final Duration initialDelay;

  /// Upper bound for delay between retries.
  final Duration maxDelay;

  /// Multiplier applied to delay after each failed attempt.
  final double backoffMultiplier;

  /// Optional custom predicate. If null, uses [OdbcError.isRetryable].
  final bool Function(OdbcError)? shouldRetry;

  /// Default options: 3 attempts, 1s initial delay, 2x backoff, 30s cap.
  static const RetryOptions defaultOptions = RetryOptions();
}
