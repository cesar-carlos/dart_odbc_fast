import 'package:odbc_fast/core/utils/logger.dart';
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
import 'package:odbc_fast/domain/errors/odbc_error.dart';
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
      executeQueryColumnarParamValues(
        connectionId,
        sql,
        params == null || params.isEmpty
            ? const <ParamValue>[]
            : paramValuesFromObjects(params),
      );

  /// Explicit alias for [streamQueryColumnar] when callers want to stress the
  /// native columnar wire path (`odbc_stream_start_batched_options`).
  Stream<Result<TypedColumnarResult>> streamQueryColumnarNative(
    String connectionId,
    String sql,
  ) =>
      streamQueryColumnar(connectionId, sql);
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
      executeQuery(conn.id, sql);

  /// `executeQueryParamValues` overload that accepts a [Connection].
  Future<Result<QueryResult>> executeQueryParamValuesFor(
    Connection conn,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  }) =>
      executeQueryParamValues(
        conn.id,
        sql,
        params,
        resultEncoding: resultEncoding,
      );

  /// `executeQueryParamValuesFromObjects` overload that accepts a [Connection].
  Future<Result<QueryResult>> executeQueryParamValuesFromObjectsFor(
    Connection conn,
    String sql,
    List<Object?> params, {
    ResultEncoding? resultEncoding,
  }) =>
      executeQueryParamValuesFromObjects(
        conn.id,
        sql,
        params,
        resultEncoding: resultEncoding,
      );

  /// `executeQueryDirectedParams` overload that accepts a [Connection].
  Future<Result<QueryResult>> executeQueryDirectedParamsFor(
    Connection conn,
    String sql,
    List<DirectedParam> params,
  ) =>
      executeQueryDirectedParams(conn.id, sql, params);

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
      executeQueryColumnarParamValues(
        conn.id,
        sql,
        params ?? const <ParamValue>[],
      );

  /// `executeQueryColumnarFromObjects` overload that accepts a [Connection].
  Future<Result<TypedColumnarResult>> executeQueryColumnarFromObjectsFor(
    Connection conn,
    String sql, {
    List<Object?>? params,
  }) =>
      executeQueryColumnarFromObjects(conn.id, sql, params: params);

  /// `executePreparedParamValuesFromObjects` overload for a [Connection].
  Future<Result<QueryResult>> executePreparedParamValuesFromObjectsFor(
    Connection conn,
    int stmtId,
    List<Object?>? params,
    StatementOptions? options,
  ) =>
      executePreparedParamValuesFromObjects(
        conn.id,
        stmtId,
        params,
        options,
      );

  /// `executeQueryMultiParamValuesFromObjects` overload for a [Connection].
  Future<Result<QueryResultMulti>> executeQueryMultiParamValuesFromObjectsFor(
    Connection conn,
    String sql,
    List<Object?> params,
  ) =>
      executeQueryMultiParamValuesFromObjects(conn.id, sql, params);

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
      executeQueryParamValues(
        connectionId,
        sql,
        paramValuesFromObjects(params),
        resultEncoding: resultEncoding,
      );

  /// Prepared positional execute with automatic [ParamValue] conversion.
  Future<Result<QueryResult>> executePreparedParamValuesFromObjects(
    String connectionId,
    int stmtId,
    List<Object?>? params,
    StatementOptions? options,
  ) =>
      executePreparedParamValues(
        connectionId,
        stmtId,
        params == null || params.isEmpty
            ? null
            : paramValuesFromObjects(params),
        options,
      );

  /// Multi-result positional execute with automatic [ParamValue] conversion.
  Future<Result<QueryResultMulti>> executeQueryMultiParamValuesFromObjects(
    String connectionId,
    String sql,
    List<Object?> params,
  ) =>
      executeQueryMultiParamValues(
        connectionId,
        sql,
        paramValuesFromObjects(params),
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
      beginTransaction(
        connectionId,
        isolationLevel ?? IsolationLevel.readCommitted,
        savepointDialect: savepointDialect ?? SavepointDialect.auto,
        accessMode: accessMode ?? TransactionAccessMode.readWrite,
        lockTimeout: lockTimeout,
      );

  /// `beginTransactionWithDefaults` overload that accepts a connection.
  Future<Result<int>> beginTransactionFor(
    Connection conn, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      beginTransactionWithDefaults(
        conn.id,
        isolationLevel: isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeout: lockTimeout,
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
  }) async {
    final beginResult = await beginTransactionWithDefaults(
      connectionId,
      isolationLevel: isolationLevel,
      savepointDialect: savepointDialect,
      accessMode: accessMode,
      lockTimeout: lockTimeout,
    );
    if (beginResult.isError()) {
      return Failure(beginResult.exceptionOrNull()!);
    }
    final txnId = beginResult.getOrNull()!;

    Result<T> userResult;
    try {
      userResult = await action(txnId);
    } on Object catch (e, st) {
      await _safelyRollbackRepository(this, connectionId, txnId);
      return Failure(
        QueryError(
          message: 'runInTransaction: action threw ${e.runtimeType}: $e\n$st',
        ),
      );
    }

    if (userResult.isError()) {
      await _safelyRollbackRepository(this, connectionId, txnId);
      return userResult;
    }

    final commitResult = await commitTransaction(connectionId, txnId);
    if (commitResult.isError()) {
      return Failure(commitResult.exceptionOrNull()!);
    }
    return userResult;
  }

  /// `runInTransaction` overload that accepts a [Connection].
  Future<Result<T>> runInTransactionFor<T extends Object>(
    Connection conn,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      runInTransaction(
        conn.id,
        action,
        isolationLevel: isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeout: lockTimeout,
      );
}

Future<void> _safelyRollbackRepository(
  IOdbcRepository repository,
  String connectionId,
  int txnId,
) async {
  try {
    await repository.rollbackTransaction(connectionId, txnId);
  } on Object catch (rollbackError, rollbackSt) {
    AppLogger.warning(
      'Rollback cleanup failed for connection $connectionId txn $txnId',
      rollbackError,
      rollbackSt,
    );
  }
}
