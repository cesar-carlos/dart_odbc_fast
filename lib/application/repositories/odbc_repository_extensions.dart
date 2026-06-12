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
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart'
    show paramValuesFromObjects;
import 'package:result_dart/result_dart.dart';

/// Columnar and streaming helpers missing from the raw repository contract.
///
/// Mirrors `OdbcQueryService` behaviour so repository consumers do not need
/// the service façade for column-major reads.
extension IOdbcRepositoryQueryExtensions on IOdbcRepository {
  /// Executes SQL and returns a typed column-major result.
  @Deprecated(
    'Use executeQueryColumnarParamValues() with typed ParamValue parameters. '
    'Will be removed in a future major release.',
  )
  Future<Result<TypedColumnarResult>> executeQueryColumnar(
    String connectionId,
    String sql, {
    List<dynamic>? params,
  }) =>
      executeQueryColumnarParamValues(
        connectionId,
        sql,
        params: params == null || params.isEmpty
            ? null
            : paramValuesFromObjects(params),
      );

  /// Typed columnar execute using [ParamValue] wire tags.
  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  }) async {
    final r = await executeQueryParamValues(
      connectionId,
      sql,
      params ?? const <ParamValue>[],
      resultEncoding: ResultEncoding.columnar,
    );
    return r.fold(
      (qr) => Success<TypedColumnarResult, OdbcError>(toTypedColumnar(qr)),
      (e) => Failure<TypedColumnarResult, OdbcError>(e as OdbcError),
    );
  }

  /// Converts untyped positional values to [ParamValue] tags before execute.
  Future<Result<TypedColumnarResult>> executeQueryColumnarFromObjects(
    String connectionId,
    String sql, {
    List<Object?>? params,
  }) =>
      executeQueryColumnarParamValues(
        connectionId,
        sql,
        params: params == null || params.isEmpty
            ? null
            : paramValuesFromObjects(params),
      );

  /// Streams row chunks and maps each to a [TypedColumnarResult].
  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  ) async* {
    await for (final chunk in streamQuery(connectionId, sql)) {
      yield chunk.fold(
        (qr) => Success<TypedColumnarResult, OdbcError>(toTypedColumnar(qr)),
        (e) => Failure<TypedColumnarResult, OdbcError>(e as OdbcError),
      );
    }
  }
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

/// Typed positional helpers that convert plain Dart values to wire tags.
///
/// Preferred over deprecated `List<dynamic>` repository methods for new code.
extension IOdbcRepositoryTypedParamExtensions on IOdbcRepository {
  /// Positional execute with automatic [ParamValue] conversion.
  Future<Result<QueryResult>> executeQueryParamValuesFromObjects(
    String connectionId,
    String sql,
    List<Object?> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
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
  } on Object catch (_) {
    // Best-effort cleanup; original error wins.
  }
}
