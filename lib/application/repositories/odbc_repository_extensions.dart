import 'package:odbc_fast/application/services/odbc_transaction_service.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:odbc_fast/domain/helpers/param_value_conversion.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:result_dart/result_dart.dart';

/// Columnar and streaming helpers missing from the raw repository contract.
///
/// Mirrors `OdbcQueryService` behaviour so repository consumers do not need
/// the service façade for column-major reads.
extension IOdbcRepositoryQueryExtensions on IOdbcRepository {
  /// Converts untyped positional values to [ParamValue] tags before execute.
  Future<Result<TypedColumnarResult>> executeQueryColumnarFromObjects(
    String connectionId,
    String sql, {
    List<Object?>? params,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryColumnarFromObjects',
        () => executeQueryColumnarParamValues(
          connectionId,
          sql,
          params == null || params.isEmpty
              ? const <ParamValue>[]
              : paramValuesFromObjects(params),
        ),
      );

  /// Explicit alias for [streamQueryColumnar] when callers want to stress the
  /// native columnar wire path (`odbc_stream_start_batched_options`).
  Stream<Result<TypedColumnarResult>> streamQueryColumnarNative(
    String connectionId,
    String sql,
  ) =>
      OdbcErrorBoundary.stream(
        'streamQueryColumnarNative',
        () => streamQueryColumnar(connectionId, sql),
      );
}

/// Ergonomic overloads that accept a [Connection] instead of a raw id.
///
/// Mirrors `IQueryServiceConnectionOverloads` for repository consumers.
extension IOdbcRepositoryConnectionOverloads on IOdbcRepository {
  /// `executeQuery` overload that accepts a [Connection].
  Future<Result<QueryResult>> executeQueryFor(
    Connection conn,
    String sql,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryFor',
        () => executeQuery(conn.id, sql),
      );

  /// `executeQueryParamValues` overload that accepts a [Connection].
  Future<Result<QueryResult>> executeQueryParamValuesFor(
    Connection conn,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryParamValuesFor',
        () => executeQueryParamValues(
          conn.id,
          sql,
          params,
          resultEncoding: resultEncoding,
        ),
      );

  /// `executeQueryParamValuesFromObjects` overload that accepts a [Connection].
  Future<Result<QueryResult>> executeQueryParamValuesFromObjectsFor(
    Connection conn,
    String sql,
    List<Object?> params, {
    ResultEncoding? resultEncoding,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryParamValuesFromObjectsFor',
        () => executeQueryParamValuesFromObjects(
          conn.id,
          sql,
          params,
          resultEncoding: resultEncoding,
        ),
      );

  /// `executeQueryDirectedParams` overload that accepts a [Connection].
  Future<Result<QueryResult>> executeQueryDirectedParamsFor(
    Connection conn,
    String sql,
    List<DirectedParam> params,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryDirectedParamsFor',
        () => executeQueryDirectedParams(conn.id, sql, params),
      );

  /// `executeQueryNamed` overload that accepts a [Connection].
  Future<Result<QueryResult>> executeQueryNamedFor(
    Connection conn,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryNamedFor',
        () => executeQueryNamed(conn.id, sql, namedParams),
      );

  /// `executeQueryColumnarParamValues` overload that accepts a [Connection].
  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValuesFor(
    Connection conn,
    String sql, {
    List<ParamValue>? params,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryColumnarParamValuesFor',
        () => executeQueryColumnarParamValues(
          conn.id,
          sql,
          params ?? const <ParamValue>[],
        ),
      );

  /// `executeQueryColumnarFromObjects` overload that accepts a [Connection].
  Future<Result<TypedColumnarResult>> executeQueryColumnarFromObjectsFor(
    Connection conn,
    String sql, {
    List<Object?>? params,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryColumnarFromObjectsFor',
        () => executeQueryColumnarFromObjects(conn.id, sql, params: params),
      );

  /// `executePreparedParamValuesFromObjects` overload for a [Connection].
  Future<Result<QueryResult>> executePreparedParamValuesFromObjectsFor(
    Connection conn,
    int stmtId,
    List<Object?>? params,
    StatementOptions? options,
  ) =>
      OdbcErrorBoundary.run(
        'executePreparedParamValuesFromObjectsFor',
        () => executePreparedParamValuesFromObjects(
          conn.id,
          stmtId,
          params,
          options,
        ),
      );

  /// `executeQueryMultiParamValuesFromObjects` overload for a [Connection].
  Future<Result<QueryResultMulti>> executeQueryMultiParamValuesFromObjectsFor(
    Connection conn,
    String sql,
    List<Object?> params,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryMultiParamValuesFromObjectsFor',
        () => executeQueryMultiParamValuesFromObjects(conn.id, sql, params),
      );

  /// `streamQuery` overload that accepts a [Connection].
  Stream<Result<QueryResult>> streamQueryFor(
    Connection conn,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryFor',
        () => streamQuery(
          conn.id,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  /// `streamQueryNamed` overload that accepts a [Connection].
  Stream<Result<QueryResult>> streamQueryNamedFor(
    Connection conn,
    String sql,
    Map<String, Object?> namedParams, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryNamedFor',
        () => streamQueryNamed(
          conn.id,
          sql,
          namedParams,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  /// `streamQueryColumnar` overload that accepts a [Connection].
  Stream<Result<TypedColumnarResult>> streamQueryColumnarFor(
    Connection conn,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryColumnarFor',
        () => streamQueryColumnar(
          conn.id,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  /// `streamQueryMultiBatches` overload that accepts a [Connection].
  Stream<Result<QueryResultMultiBatchItem>> streamQueryMultiBatchesFor(
    Connection conn,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMultiBatchesFor',
        () => streamQueryMultiBatches(
          conn.id,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );
}

/// Typed positional helpers that convert plain Dart values to wire tags.
///
/// Typed positional helpers that convert plain Dart values to wire tags.
extension IOdbcRepositoryTypedParamExtensions on IOdbcRepository {
  /// Positional execute with automatic [ParamValue] conversion.
  Future<Result<QueryResult>> executeQueryParamValuesFromObjects(
    String connectionId,
    String sql,
    List<Object?> params, {
    ResultEncoding? resultEncoding,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryParamValuesFromObjects',
        () => executeQueryParamValues(
          connectionId,
          sql,
          paramValuesFromObjects(params),
          resultEncoding: resultEncoding,
        ),
      );

  /// Prepared positional execute with automatic [ParamValue] conversion.
  Future<Result<QueryResult>> executePreparedParamValuesFromObjects(
    String connectionId,
    int stmtId,
    List<Object?>? params,
    StatementOptions? options,
  ) =>
      OdbcErrorBoundary.run(
        'executePreparedParamValuesFromObjects',
        () => executePreparedParamValues(
          connectionId,
          stmtId,
          params == null || params.isEmpty
              ? null
              : paramValuesFromObjects(params),
          options,
        ),
      );

  /// Multi-result positional execute with automatic [ParamValue] conversion.
  Future<Result<QueryResultMulti>> executeQueryMultiParamValuesFromObjects(
    String connectionId,
    String sql,
    List<Object?> params,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryMultiParamValuesFromObjects',
        () => executeQueryMultiParamValues(
          connectionId,
          sql,
          paramValuesFromObjects(params),
        ),
      );
}

/// Transaction helpers with service-level defaults and `runInTransaction`.
///
/// Mirrors `OdbcTransactionService` for repository consumers.
extension IOdbcRepositoryTransactionExtensions on IOdbcRepository {
  /// `beginTransaction` with optional isolation and access-mode defaults.
  Future<Result<int>> beginTransactionWithDefaults(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      OdbcErrorBoundary.run(
        'beginTransactionWithDefaults',
        () => beginTransaction(
          connectionId,
          isolationLevel ?? IsolationLevel.readCommitted,
          savepointDialect: savepointDialect ?? SavepointDialect.auto,
          accessMode: accessMode ?? TransactionAccessMode.readWrite,
          lockTimeout: lockTimeout,
        ),
      );

  /// `beginTransactionWithDefaults` overload that accepts a connection.
  Future<Result<int>> beginTransactionFor(
    Connection conn, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      OdbcErrorBoundary.run(
        'beginTransactionFor',
        () => beginTransactionWithDefaults(
          conn.id,
          isolationLevel: isolationLevel,
          savepointDialect: savepointDialect,
          accessMode: accessMode,
          lockTimeout: lockTimeout,
        ),
      );

  /// Runs [action] inside a freshly opened transaction with automatic
  /// commit-on-success / rollback-on-failure semantics.
  Future<Result<T>> runInTransaction<T extends Object>(
    String connectionId,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      OdbcErrorBoundary.run(
        'runInTransaction',
        () => OdbcTransactionService(this).runInTransaction(
          connectionId,
          action,
          isolationLevel: isolationLevel,
          savepointDialect: savepointDialect,
          accessMode: accessMode,
          lockTimeout: lockTimeout,
        ),
      );

  /// `runInTransaction` overload that accepts a [Connection].
  Future<Result<T>> runInTransactionFor<T extends Object>(
    Connection conn,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      OdbcErrorBoundary.run(
        'runInTransactionFor',
        () => runInTransaction(
          conn.id,
          action,
          isolationLevel: isolationLevel,
          savepointDialect: savepointDialect,
          accessMode: accessMode,
          lockTimeout: lockTimeout,
        ),
      );
}
