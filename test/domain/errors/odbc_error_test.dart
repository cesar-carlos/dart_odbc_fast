import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcError', () {
    test('formats message with optional diagnostic fields', () {
      const error = QueryError(
        message: 'syntax error',
        sqlState: '42000',
        nativeCode: 102,
      );

      expect(
        error.toString(),
        'OdbcError: syntax error (SQLSTATE: 42000) (Code: 102)',
      );
    });

    test('categorizes validation, connection and fatal errors', () {
      const validation = ValidationError(message: 'bad input');
      const connection = ConnectionError(message: 'lost');
      const query = QueryError(message: 'bad sql', sqlState: '42000');

      expect(validation.category, ErrorCategory.validation);
      expect(connection.category, ErrorCategory.connectionLost);
      expect(query.category, ErrorCategory.fatal);
    });

    test('detects retryable connection SQLSTATE values', () {
      const error = QueryError(
        message: 'network failure',
        sqlState: '08006',
      );

      expect(error.isRetryable, isTrue);
      expect(error.isConnectionError, isTrue);
      expect(error.category, ErrorCategory.connectionLost);
    });
  });

  group('structured ODBC errors', () {
    test('expose specialized categories and messages', () {
      const environment = EnvironmentNotInitializedError();
      const noMoreResults = NoMoreResultsError();
      const malformed = MalformedPayloadError(message: 'truncated');
      const resourceLimit = ResourceLimitReachedError(message: 'queue full');
      const cancelled = CancelledError();
      const worker = WorkerCrashedError(message: 'port closed');

      expect(environment.message, 'ODBC environment not initialized');
      expect(noMoreResults.category, ErrorCategory.fatal);
      expect(malformed.category, ErrorCategory.validation);
      expect(resourceLimit.category, ErrorCategory.transient);
      expect(cancelled.message, 'Operation cancelled');
      expect(cancelled.category, ErrorCategory.fatal);
      expect(worker.category, ErrorCategory.fatal);
    });

    test('bulk partial failure includes recovery details', () {
      const error = BulkPartialFailureError(
        rowsInsertedBeforeFailure: 10,
        failedChunks: 2,
        detail: 'chunk 3 failed',
      );

      expect(error.category, ErrorCategory.fatal);
      expect(error.toString(), contains('rowsInsertedBeforeFailure=10'));
      expect(error.toString(), contains('failedChunks=2'));
      expect(error.toString(), contains('chunk 3 failed'));
    });

    test('rollback and unsupported feature errors keep diagnostics', () {
      const rollback = RollbackFailedError(
        message: 'rollback failed',
        sqlState: 'HY000',
        nativeCode: 99,
      );
      const unsupported = UnsupportedFeatureError(message: 'not available');

      expect(rollback.sqlState, 'HY000');
      expect(rollback.nativeCode, 99);
      expect(unsupported.category, ErrorCategory.fatal);
    });
  });
}
