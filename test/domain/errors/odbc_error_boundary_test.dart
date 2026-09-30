import 'package:odbc_fast/application/services/odbc_query_service.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

class _ThrowingRepository implements IQueryRepository {
  @override
  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String id,
    String sql,
  ) =>
      throw StateError('injected implementation');

  @override
  Stream<Result<QueryResult>> streamQuery(
    String id,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      Stream.error(StateError('injected stream'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('boundary preserves an injected async error category and driver codes',
      () async {
    final result = await OdbcErrorBoundary.run<int>(
      'executeQuery',
      () async => throw const AsyncError(
        code: AsyncErrorCode.resourceExhausted,
        message: 'Queue full',
        sqlState: 'HY001',
        nativeCode: 4,
      ),
    );
    final error = result.exceptionOrNull()! as OdbcError;
    expect(error.code, OdbcErrorCode.resourceLimit);
    expect(error.sqlState, 'HY001');
    expect(error.nativeCode, 4);
    expect(error.details.operation, 'executeQuery');
    expect(error.details.stackTrace, isNotNull);
  });
  test('should_convert_errors_from_alternative_repository', () async {
    final service = OdbcQueryService(_ThrowingRepository());
    final result = await service.executeQueryMultiFull('1', 'secret SQL');
    final error = result.exceptionOrNull()! as OdbcError;
    expect(error.code, OdbcErrorCode.internal);
    expect(error.details.operation, 'executeQueryMultiFull');
    expect(error.details.cause, isA<StateError>());
    expect(error.details.stackTrace, isNotNull);
    expect(error.userMessage, isNot(contains('secret')));
    final stream = await service.streamQuery('1', 'secret SQL').toList();
    expect(stream, hasLength(1));
    expect(stream.single.exceptionOrNull(), isA<OdbcError>());
  });

  test('should_return_one_failure_and_preserve_cleanup_error', () async {
    Stream<Result<int>> source() async* {
      try {
        yield const Failure(
          QueryError(message: 'SQL failed', sqlState: '42000'),
        );
        yield const Success(99);
      } finally {
        Error.throwWithStackTrace(
          StateError('cleanup failed'),
          StackTrace.current,
        );
      }
    }

    final values = await OdbcErrorBoundary.stream('query', source).toList();
    expect(values, hasLength(1));
    final error = values.single.exceptionOrNull()! as OdbcError;
    expect(error.sqlState, '42000');
    expect(error.details.secondaryErrors, hasLength(1));
    expect(
      error.details.secondaryErrors.single.details.cause,
      isA<StateError>(),
    );
  });

  test('should_preserve_const_constructor_subtype_and_bulk_details', () {
    const original = BulkPartialFailureError(
      rowsInsertedBeforeFailure: 7,
      failedChunks: 2,
      detail: 'technical',
    );
    final error = normalizeOdbcError(original, operation: 'bulk')
        as BulkPartialFailureError;
    expect(error.rowsInsertedBeforeFailure, 7);
    expect(error.failedChunks, 2);
    expect(error.detail, original.detail);
  });

  test('should_replace_empty_diagnostics_and_no_error_sentinel', () async {
    for (final message in ['', '  ', 'No error']) {
      final result = await OdbcErrorBoundary.run<int>(
        'query',
        () async => Failure(QueryError(message: message)),
      );
      final error = result.exceptionOrNull()! as OdbcError;
      expect(error.message.trim(), isNotEmpty);
      expect(error.message, isNot('No error'));
      expect(error.userMessage, isNotEmpty);
    }
  });

  test('should_convert_type_error_at_result_boundary', () async {
    final result = await OdbcErrorBoundary.run<int>('query', () async {
      const Object value = 'invalid';
      return Success(value as int);
    });
    final error = result.exceptionOrNull()! as OdbcError;
    expect(error.details.cause, isA<TypeError>());
    expect(error.code, OdbcErrorCode.internal);
  });
}
