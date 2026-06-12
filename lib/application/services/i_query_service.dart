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
  /// Legacy convenience query after `connect()`.
  ///
  /// Migration: prefer [executeQueryParamValues] (or
  /// [executeQueryDirectedParams] for `OUT` / `INOUT`).
  @Deprecated(
    'Use executeQueryParamValues() with typed ParamValue parameters. '
    'Will be removed in a future major release.',
  )
  Future<Result<QueryResult>> executeQuery(
    String sql, {
    List<dynamic>? params,
    String? connectionId,
  });

  /// Legacy untyped positional parameters.
  ///
  /// Migration: prefer [executeQueryParamValues] or
  /// [executeQueryDirectedParams] for typed parameters.
  @Deprecated(
    'Use executeQueryParamValues() with typed ParamValue parameters. '
    'Will be removed in a future major release.',
  )
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
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

  /// Column-major opt-in variant of [executeQueryParams].
  ///
  /// Same FFI path as the row-major call (with `ResultEncoding.columnar`
  /// requested), but the returned [TypedColumnarResult] exposes typed
  /// primitive arrays per column (`Int32List`, `Int64List`,
  /// `Float64List`) so numeric pipelines avoid `dynamic` boxing.
  /// Strings, bytes and dates remain in `List<T?>`.
  ///
  /// Behaviour vs legacy positional `List<dynamic>` params:
  /// - Same validation, same error mapping.
  /// - Conversion overhead: one extra pass over the result; the win
  ///   comes from downstream reads in tight loops.
  ///
  /// Migration: prefer [executeQueryColumnarParamValues] when parameters
  /// are already [ParamValue] instances.
  ///
  /// Example:
  ///
  /// ```dart
  /// final r = await service.executeQueryColumnar(
  ///   connectionId,
  ///   'SELECT id, total_cents FROM orders WHERE region = ?',
  ///   params: ['SA'],
  /// );
  /// r.fold(
  ///   (typed) {
  ///     final ids = typed.column('id') as TypedColumnInt32;
  ///     final totals = typed.column('total_cents') as TypedColumnInt64;
  ///     for (var i = 0; i < typed.rowCount; i++) {
  ///       process(ids.values[i], totals.values[i]);
  ///     }
  ///   },
  ///   (err) => log.error(err.message),
  /// );
  /// ```
  @Deprecated(
    'Use executeQueryColumnarParamValues() with typed ParamValue parameters. '
    'Will be removed in a future major release.',
  )
  Future<Result<TypedColumnarResult>> executeQueryColumnar(
    String connectionId,
    String sql, {
    List<dynamic>? params,
  });

  /// Typed sibling of the legacy columnar query API.
  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  });

  /// Stream-shaped sibling of the legacy columnar query API. Each emitted item
  /// is a complete [TypedColumnarResult] (a single chunk for the named
  /// query API; multiple chunks when the underlying engine streams).
  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  );
}

/// Ergonomic overloads that take a [Connection] directly instead of a
/// raw `connectionId` string. Each method delegates to its
/// `String connectionId` counterpart, keeping the original API stable
/// while removing the manual `conn.id` plumbing at call sites.
///
/// The methods live in an extension so adding new ones is purely
/// additive — implementers of [IQueryService] do not need to override
/// anything.
///
/// Example:
///
/// ```dart
/// final connResult = await service.connect('DSN=mydsn');
/// final conn = connResult.getOrThrow();
///
/// // Before (still supported):
/// final a = await service.executeQuery(
///   'SELECT 1',
///   connectionId: conn.id,
/// );
///
/// // After (no manual conn.id plumbing):
/// final b = await service.executeQueryFor(conn, 'SELECT 1');
/// ```
extension IQueryServiceConnectionOverloads on IQueryService {
  /// `executeQuery` overload that accepts a [Connection].
  @Deprecated(
    'Use executeQueryParamValuesFor() with typed ParamValue parameters. '
    'Will be removed in a future major release.',
  )
  Future<Result<QueryResult>> executeQueryFor(
    Connection conn,
    String sql, {
    List<dynamic>? params,
  }) =>
      executeQuery(sql, connectionId: conn.id, params: params);

  /// `executeQueryParams` overload that accepts a [Connection].
  @Deprecated(
    'Use executeQueryParamValuesFor() with typed ParamValue parameters. '
    'Will be removed in a future major release.',
  )
  Future<Result<QueryResult>> executeQueryParamsFor(
    Connection conn,
    String sql,
    List<dynamic> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      executeQueryParams(
        conn.id,
        sql,
        params,
        resultEncoding: resultEncoding,
      );

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

  /// `executeQueryColumnar` overload that accepts a [Connection].
  @Deprecated(
    'Use executeQueryColumnarParamValuesFor() with typed ParamValue '
    'parameters. Will be removed in a future major release.',
  )
  Future<Result<TypedColumnarResult>> executeQueryColumnarFor(
    Connection conn,
    String sql, {
    List<dynamic>? params,
  }) =>
      executeQueryColumnar(conn.id, sql, params: params);

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
