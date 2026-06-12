/// Unit tests for [IOdbcRepository] ergonomic extensions.
library;

import 'package:odbc_fast/application/repositories/odbc_repository_extensions.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

class _FakeRepository implements IOdbcRepository {
  String? capturedConnectionId;
  String? capturedSql;
  List<dynamic>? capturedPositionalParams;
  List<ParamValue>? capturedParamValues;
  ResultEncoding? capturedEncoding;
  IsolationLevel? capturedIsolationLevel;
  int? capturedTxnId;
  bool streamCalled = false;

  static const QueryResult _emptyResult = QueryResult(
    columns: ['c'],
    rows: [
      ['v'],
    ],
    rowCount: 1,
  );

  @override
  Future<Result<QueryResult>> executeQuery(
    String connectionId,
    String sql,
  ) async {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    return const Success(_emptyResult);
  }

  @override
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    capturedPositionalParams = params;
    capturedEncoding = resultEncoding;
    return const Success(_emptyResult);
  }

  @override
  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    capturedParamValues = params;
    capturedEncoding = resultEncoding;
    return const Success(_emptyResult);
  }

  @override
  Stream<Result<QueryResult>> streamQuery(String connectionId, String sql) {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    streamCalled = true;
    return Stream<Result<QueryResult>>.fromIterable(
      <Result<QueryResult>>[const Success(_emptyResult)],
    );
  }

  @override
  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel, {
    SavepointDialect savepointDialect = SavepointDialect.auto,
    TransactionAccessMode accessMode = TransactionAccessMode.readWrite,
    Duration? lockTimeout,
  }) async {
    capturedConnectionId = connectionId;
    capturedIsolationLevel = isolationLevel;
    return const Success(7);
  }

  @override
  Future<Result<Unit>> commitTransaction(String connectionId, int txnId) async {
    capturedConnectionId = connectionId;
    capturedTxnId = txnId;
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async {
    capturedConnectionId = connectionId;
    capturedTxnId = txnId;
    return const Success(unit);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late _FakeRepository fake;
  final conn = Connection(
    id: 'conn-repo',
    connectionString: 'DSN=test',
    createdAt: DateTime.utc(2026),
  );

  setUp(() {
    fake = _FakeRepository();
  });

  group('IOdbcRepositoryConnectionOverloads', () {
    test('should_forward_executeQueryFor', () async {
      await fake.executeQueryFor(conn, 'SELECT 1');
      expect(fake.capturedConnectionId, equals('conn-repo'));
      expect(fake.capturedSql, equals('SELECT 1'));
    });

    test('should_forward_executeQueryParamValuesFor', () async {
      await fake.executeQueryParamValuesFor(
        conn,
        'SELECT ?',
        const [ParamValueInt32(1)],
      );
      expect(fake.capturedConnectionId, equals('conn-repo'));
      expect(fake.capturedParamValues, equals(const [ParamValueInt32(1)]));
    });
  });

  group('IOdbcRepositoryTypedParamExtensions', () {
    test('should_convert_objects_before_executeQueryParamValues', () async {
      await fake.executeQueryParamValuesFromObjects(
        'conn-repo',
        'SELECT ?',
        [42],
      );
      expect(fake.capturedParamValues, isNotNull);
      expect(fake.capturedParamValues!.single, isA<ParamValueInt32>());
    });
  });

  group('IOdbcRepositoryQueryExtensions', () {
    test('should_use_columnar_encoding_for_columnar_param_values', () async {
      final result = await fake.executeQueryColumnarParamValues(
        'conn-repo',
        'SELECT c',
      );
      expect(fake.capturedEncoding, equals(ResultEncoding.columnar));
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull()!.rowCount, equals(1));
    });

    test('streamQueryColumnarFor should_map_stream_chunks', () async {
      final chunk = await fake.streamQueryColumnarFor(conn, 'SELECT 1').first;
      expect(fake.streamCalled, isTrue);
      expect(chunk.isSuccess(), isTrue);
      expect(chunk.getOrNull(), isA<TypedColumnarResult>());
    });
  });

  group('IOdbcRepositoryTransactionExtensions', () {
    test('beginTransactionFor should_apply_readCommitted_default', () async {
      await fake.beginTransactionFor(conn);
      expect(fake.capturedIsolationLevel, equals(IsolationLevel.readCommitted));
    });

    test('runInTransactionFor should_commit_on_success', () async {
      final result = await fake.runInTransactionFor<int>(
        conn,
        (txnId) async => Success<int, Exception>(txnId),
      );
      expect(result.getOrNull(), equals(7));
      expect(fake.capturedTxnId, equals(7));
    });
  });
}
