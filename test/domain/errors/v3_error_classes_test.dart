import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:test/test.dart';

void main() {
  group('v3.0 OdbcError variants', () {
    test('NoMoreResultsError has fixed message and fatal category', () {
      const e = NoMoreResultsError();
      expect(e.message, 'No more result sets available');
      expect(e.category, ErrorCategory.fatal);
    });

    test('MalformedPayloadError surfaces validation category', () {
      const e = MalformedPayloadError(message: 'bad header');
      expect(e.category, ErrorCategory.validation);
      expect(e.message, 'bad header');
    });

    test('RollbackFailedError exposes message + sqlState', () {
      const e = RollbackFailedError(
        message: 'rollback failed: deadlock',
        sqlState: '40001',
      );
      expect(e.message, contains('deadlock'));
      expect(e.sqlState, '40001');
    });

    test('ResourceLimitReachedError is transient', () {
      const e = ResourceLimitReachedError(message: 'pool full');
      expect(e.category, ErrorCategory.transient);
    });

    test('CancelledError has fixed message and fatal category', () {
      const e = CancelledError();
      expect(e.message, 'Operation cancelled');
      expect(e.category, ErrorCategory.fatal);
    });

    test('WorkerCrashedError is fatal', () {
      const e = WorkerCrashedError(message: 'worker disconnected');
      expect(e.category, ErrorCategory.fatal);
    });

    test('BulkPartialFailureError carries structured fields', () {
      const e = BulkPartialFailureError(
        rowsInsertedBeforeFailure: 1234,
        failedChunks: 2,
        detail: 'chunk[3]: timeout; chunk[7]: deadlock',
      );
      expect(e.rowsInsertedBeforeFailure, 1234);
      expect(e.failedChunks, 2);
      expect(e.detail, contains('timeout'));
      expect(e.toString(), contains('rowsInsertedBeforeFailure=1234'));
      expect(e.toString(), contains('failedChunks=2'));
    });
  });
}
