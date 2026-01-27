import 'package:odbc_fast/domain/entities/retry_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/helpers/retry_helper.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RetryHelper', () {
    test('should return success when operation succeeds on first attempt', () async {
      var callCount = 0;
      Future<Result<int>> operation() async {
        callCount++;
        return Success(42);
      }

      final result = await RetryHelper.execute(
        operation,
        RetryOptions.defaultOptions,
      );

      expect(result.exceptionOrNull(), isNull);
      expect(result.getOrElse((_) => -1), 42);
      expect(callCount, 1);
    });

    test('should retry on retryable OdbcError and return success on second attempt',
        () async {
      var attempts = 0;
      Future<Result<int>> operation() async {
        attempts++;
        if (attempts == 1) {
          return Failure(
            ConnectionError(
              message: 'transient',
              sqlState: '08xxx',
              nativeCode: 0,
            ),
          );
        }
        return Success(99);
      }

      final result = await RetryHelper.execute(
        operation,
        const RetryOptions(
          maxAttempts: 3,
          initialDelay: Duration(milliseconds: 10),
          maxDelay: Duration(seconds: 5),
          backoffMultiplier: 2.0,
        ),
      );

      expect(result.exceptionOrNull(), isNull);
      expect(result.getOrElse((_) => -1), 99);
      expect(attempts, 2);
    });

    test('should stop after maxAttempts when all attempts fail with retryable error',
        () async {
      var attempts = 0;
      Future<Result<int>> operation() async {
        attempts++;
        return Failure(
          ConnectionError(
            message: 'transient',
            sqlState: '08xxx',
          ),
        );
      }

      final result = await RetryHelper.execute(
        operation,
        const RetryOptions(
          maxAttempts: 3,
          initialDelay: Duration(milliseconds: 5),
          maxDelay: Duration(seconds: 5),
          backoffMultiplier: 2.0,
        ),
      );

      expect(result.exceptionOrNull(), isNotNull);
      expect(result.exceptionOrNull(), isA<ConnectionError>());
      expect(attempts, 3);
    });

    test('should not retry when error is ValidationError (non-retryable)', () async {
      var attempts = 0;
      Future<Result<int>> operation() async {
        attempts++;
        return Failure(const ValidationError(message: 'invalid'));
      }

      final result = await RetryHelper.execute(
        operation,
        const RetryOptions(
          maxAttempts: 5,
          initialDelay: Duration(milliseconds: 10),
          maxDelay: Duration(seconds: 5),
          backoffMultiplier: 2.0,
        ),
      );

      expect(result.exceptionOrNull(), isNotNull);
      expect(result.exceptionOrNull(), isA<ValidationError>());
      expect(attempts, 1);
    });

    test('should use custom shouldRetry when provided', () async {
      var attempts = 0;
      Future<Result<int>> operation() async {
        attempts++;
        if (attempts < 2) {
          return Failure(
            ConnectionError(message: 'x', sqlState: '42xxx'),
          );
        }
        return Success(1);
      }

      final result = await RetryHelper.execute(
        operation,
        RetryOptions(
          maxAttempts: 3,
          initialDelay: Duration.zero,
          maxDelay: const Duration(seconds: 5),
          backoffMultiplier: 2.0,
          shouldRetry: (e) => e.message == 'x',
        ),
      );

      expect(result.exceptionOrNull(), isNull);
      expect(result.getOrElse((_) => -1), 1);
      expect(attempts, 2);
    });

    test('should not retry when custom shouldRetry returns false', () async {
      var attempts = 0;
      Future<Result<int>> operation() async {
        attempts++;
        return Failure(
          ConnectionError(message: 'x', sqlState: '08xxx'),
        );
      }

      final result = await RetryHelper.execute(
        operation,
        RetryOptions(
          maxAttempts: 5,
          initialDelay: Duration.zero,
          maxDelay: const Duration(seconds: 5),
          backoffMultiplier: 2.0,
          shouldRetry: (_) => false,
        ),
      );

      expect(result.exceptionOrNull(), isNotNull);
      expect(attempts, 1);
    });
  });
}
