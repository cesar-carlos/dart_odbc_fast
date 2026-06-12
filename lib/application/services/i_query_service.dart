import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:result_dart/result_dart.dart';

/// Query-shaped operations subset of `IOdbcService`.
///
/// Use this narrower interface in consumers that only need to read or
/// write data — they don't have to depend on transaction, pool, or
/// administrative concerns. The full `IOdbcService` `implements` this
/// type, so existing wiring keeps working unchanged.
///
/// Members are intentionally a subset; methods that bridge multiple
/// categories (e.g. `executeQueryParamBuffer`) stay on `IOdbcService`
/// for now and may be promoted here in a follow-up.
abstract interface class IQueryService {
  /// Convenience query after `connect()` using the active connection id.
  Future<Result<QueryResult>> executeQuery(
    String sql, {
    String? connectionId,
  });

  /// Typed positional parameters via [ParamValue] wire tags.
  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  });

  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  );

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  );

  Stream<Result<QueryResult>> streamQuery(String connectionId, String sql);

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  );

  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  );

  /// Column-major opt-in variant of [executeQueryParamValues].
  ///
  /// Same FFI path as the row-major call (with `ResultEncoding.columnar`
  /// requested), but the returned [TypedColumnarResult] exposes typed
  /// primitive arrays per column (`Int32List`, `Int64List`,
  /// `Float64List`) so numeric pipelines avoid `dynamic` boxing.
  /// Strings, bytes and dates remain in `List<T?>`.
  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  });

  /// Row-major streaming with a columnar Dart view.
  ///
  /// Under the hood this calls [streamQuery] (batched cursor streaming by
  /// default) and maps each [QueryResult] chunk through `toTypedColumnar`. The
  /// native wire format stays row-major; no columnar v2 header is requested on
  /// the FFI path.
  ///
  /// For a single-shot query that asks the engine for native columnar encoding,
  /// use [executeQueryColumnarParamValues] (`ResultEncoding.columnar`).
  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  );
}

/// Ergonomic overloads that take a [Connection] directly instead of a
/// raw `connectionId` string.
extension IQueryServiceConnectionOverloads on IQueryService {
  /// `executeQuery` overload that accepts a [Connection].
  Future<Result<QueryResult>> executeQueryFor(
    Connection conn,
    String sql,
  ) =>
      executeQuery(sql, connectionId: conn.id);

  /// `executeQueryParamValues` overload that accepts a [Connection].
  Future<Result<QueryResult>> executeQueryParamValuesFor(
    Connection conn,
    String sql,
    List<ParamValue> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      executeQueryParamValues(
        conn.id,
        sql,
        params,
        resultEncoding: resultEncoding,
      );

  /// `executeQueryNamed` overload that accepts a [Connection].
  Future<Result<QueryResult>> executeQueryNamedFor(
    Connection conn,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      executeQueryNamed(conn.id, sql, namedParams);

  /// `executeQueryColumnarParamValues` overload that accepts a [Connection].
  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValuesFor(
    Connection conn,
    String sql, {
    List<ParamValue>? params,
  }) =>
      executeQueryColumnarParamValues(conn.id, sql, params: params);

  /// `streamQuery` overload that accepts a [Connection].
  Stream<Result<QueryResult>> streamQueryFor(
    Connection conn,
    String sql,
  ) =>
      streamQuery(conn.id, sql);

  /// `streamQueryNamed` overload that accepts a [Connection].
  Stream<Result<QueryResult>> streamQueryNamedFor(
    Connection conn,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      streamQueryNamed(conn.id, sql, namedParams);

  /// `streamQueryColumnar` overload that accepts a [Connection].
  Stream<Result<TypedColumnarResult>> streamQueryColumnarFor(
    Connection conn,
    String sql,
  ) =>
      streamQueryColumnar(conn.id, sql);
}
