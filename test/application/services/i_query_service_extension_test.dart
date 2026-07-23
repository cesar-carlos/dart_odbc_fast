/// Unit tests for [IQueryServiceConnectionOverloads].
library;

import 'package:odbc_fast/application/services/i_query_service.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

class _FakeQueryService implements IQueryService {
  String? capturedSql;
  String? capturedConnectionId;
  List<Object?>? capturedPositionalParams;
  List<DirectedParam>? capturedDirectedParams;
  Map<String, Object?>? capturedNamedParams;
  ResultEncoding? capturedEncoding;
  bool streamCalled = false;
  bool streamNamedCalled = false;
  bool streamMultiCalled = false;
  bool streamColumnarCalled = false;

  static const QueryResult _emptyResult = QueryResult(
    columns: [],
    rows: [],
    rowCount: 0,
  );

  static QueryResult get _stubResult => _emptyResult;
  static TypedColumnarResult get _stubColumnar => TypedColumnarResult(
        columns: const [],
        rowCount: 0,
      );

  @override
  Future<Result<QueryResult>> executeQuery(
    String sql, {
    String? connectionId,
  }) async {
    capturedSql = sql;
    capturedConnectionId = connectionId;
    return Success(_stubResult);
  }

  @override
  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  }) async {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    capturedPositionalParams = params;
    capturedEncoding = resultEncoding;
    return Success(_stubResult);
  }

  @override
  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  ) async {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    capturedDirectedParams = params;
    return Success(_stubResult);
  }

  @override
  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) async {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    capturedNamedParams = namedParams;
    return Success(_stubResult);
  }

  @override
  Stream<Result<QueryResult>> streamQuery(String connectionId, String sql) {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    streamCalled = true;
    return Stream<Result<QueryResult>>.fromIterable(
      <Result<QueryResult>>[Success(_stubResult)],
    );
  }

  @override
  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    capturedNamedParams = namedParams;
    streamNamedCalled = true;
    return Stream<Result<QueryResult>>.fromIterable(
      <Result<QueryResult>>[Success(_stubResult)],
    );
  }

  @override
  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    streamMultiCalled = true;
    return const Stream<Result<QueryResultMultiItem>>.empty();
  }

  @override
  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  }) async {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    capturedPositionalParams = params;
    return Success(_stubColumnar);
  }

  @override
  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  ) {
    capturedConnectionId = connectionId;
    capturedSql = sql;
    streamColumnarCalled = true;
    return Stream<Result<TypedColumnarResult>>.fromIterable(
      <Result<TypedColumnarResult>>[Success(_stubColumnar)],
    );
  }
}

void main() {
  late _FakeQueryService fake;
  final conn = Connection(
    id: 'conn-42',
    connectionString: 'DSN=test',
    createdAt: DateTime.utc(2026),
  );

  setUp(() {
    fake = _FakeQueryService();
  });

  group('IQueryServiceConnectionOverloads.executeQueryFor', () {
    test('should_forward_sql_and_connection_id', () async {
      await fake.executeQueryFor(conn, 'SELECT 1');
      expect(fake.capturedSql, equals('SELECT 1'));
      expect(fake.capturedConnectionId, equals('conn-42'));
    });
  });

  group('IQueryServiceConnectionOverloads.executeQueryParamValuesFor', () {
    test('should_forward_null_encoding_for_repository_default', () async {
      await fake.executeQueryParamValuesFor(
        conn,
        'SELECT ?',
        const [ParamValueInt32(1)],
      );
      expect(fake.capturedConnectionId, equals('conn-42'));
      expect(fake.capturedEncoding, isNull);
    });

    test('should_forward_columnar_encoding_override', () async {
      await fake.executeQueryParamValuesFor(
        conn,
        'SELECT ?',
        const [ParamValueInt32(1)],
        resultEncoding: ResultEncoding.columnar,
      );
      expect(fake.capturedEncoding, equals(ResultEncoding.columnar));
    });
  });

  group('IQueryServiceConnectionOverloads.executeQueryNamedFor', () {
    test('should_forward_named_params_map', () async {
      await fake.executeQueryNamedFor(
        conn,
        'SELECT :id',
        <String, Object?>{':id': 7},
      );
      expect(fake.capturedConnectionId, equals('conn-42'));
      expect(fake.capturedNamedParams, equals(<String, Object?>{':id': 7}));
    });
  });

  group('IQueryServiceConnectionOverloads.executeQueryColumnarParamValuesFor',
      () {
    test('should_forward_typed_param_values', () async {
      await fake.executeQueryColumnarParamValuesFor(
        conn,
        'SELECT col FROM t WHERE id = ?',
        params: const [ParamValueString('x')],
      );
      expect(fake.capturedConnectionId, equals('conn-42'));
      expect(
        fake.capturedPositionalParams,
        equals(<ParamValue>[const ParamValueString('x')]),
      );
    });
  });

  group('IQueryServiceConnectionOverloads stream overloads', () {
    test('streamQueryFor should_route_to_streamQuery', () async {
      await fake.streamQueryFor(conn, 'SELECT 1').first;
      expect(fake.streamCalled, isTrue);
      expect(fake.capturedConnectionId, equals('conn-42'));
    });

    test('streamQueryNamedFor should_route_to_streamQueryNamed', () async {
      await fake.streamQueryNamedFor(
        conn,
        'SELECT :id',
        <String, Object?>{':id': 1},
      ).first;
      expect(fake.streamNamedCalled, isTrue);
      expect(fake.capturedNamedParams, equals(<String, Object?>{':id': 1}));
    });

    test('streamQueryColumnarFor should_route_to_streamQueryColumnar',
        () async {
      await fake.streamQueryColumnarFor(conn, 'SELECT 1').first;
      expect(fake.streamColumnarCalled, isTrue);
      expect(fake.capturedConnectionId, equals('conn-42'));
    });
  });
}
