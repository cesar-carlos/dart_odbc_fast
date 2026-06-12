import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('AsyncError', () {
    test('should convert to ConnectionError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: 'Connection failed',
        sqlState: '08001',
        nativeCode: 1,
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<ConnectionError>());
      expect(odbcError.message, equals('Connection failed'));
      expect(odbcError.sqlState, equals('08001'));
      expect(odbcError.nativeCode, equals(1));
    });

    test('should convert to QueryError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: 'Query failed',
        sqlState: '42000',
        nativeCode: 102,
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<QueryError>());
      expect(odbcError.message, equals('Query failed'));
      expect(odbcError.sqlState, equals('42000'));
      expect(odbcError.nativeCode, equals(102));
    });

    test('should convert to ValidationError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.invalidParameter,
        message: 'Invalid parameter',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<ValidationError>());
      expect(odbcError.message, equals('Invalid parameter'));
    });

    test('should convert to EnvironmentNotInitializedError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.notInitialized,
        message: 'Not initialized',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<EnvironmentNotInitializedError>());
    });

    test('should convert requestTimeout to QueryError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.requestTimeout,
        message: 'Worker did not respond within 5s',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<QueryError>());
      expect(odbcError.message, equals('Worker did not respond within 5s'));
    });

    test('should convert workerTerminated to QueryError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.workerTerminated,
        message: 'Connection disposed; worker shutting down',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<QueryError>());
      expect(
        odbcError.message,
        equals('Connection disposed; worker shutting down'),
      );
    });

    test('should convert resourceExhausted to ResourceLimitReachedError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.resourceExhausted,
        message: 'Async worker pool queue is full',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<ResourceLimitReachedError>());
      expect(odbcError.message, equals('Async worker pool queue is full'));
    });

    test('should provide readable toString', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: 'Test error',
        sqlState: '08001',
        nativeCode: 1,
      );

      final str = asyncError.toString();

      expect(str, contains('AsyncError'));
      expect(str, contains('connectionFailed'));
      expect(str, contains('Test error'));
      expect(str, contains('SQLSTATE: 08001'));
      expect(str, contains('Native: 1'));
    });
  });
  group('AsyncError Integration', () {
    test('should preserve all error information across isolate boundary', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: 'Syntax error near SELECT',
        sqlState: '42000',
        nativeCode: 156,
      );

      final odbcError = asyncError.toOdbcError();

      // Verify all information is preserved
      expect(odbcError, isA<QueryError>());
      expect(odbcError.message, equals('Syntax error near SELECT'));
      expect(odbcError.sqlState, equals('42000'));
      expect(odbcError.nativeCode, equals(156));
    });

    test('should handle error without SQLSTATE or native code', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: 'Connection timeout',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<ConnectionError>());
      expect(odbcError.message, equals('Connection timeout'));
      expect(odbcError.sqlState, isNull);
      expect(odbcError.nativeCode, isNull);
    });
  });
}
