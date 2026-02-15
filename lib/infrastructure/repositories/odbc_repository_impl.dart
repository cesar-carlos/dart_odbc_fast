import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser, ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart'
    show MultiResultItem, MultiResultParser;
import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart'
    show NamedParameterParser, ParameterMissingException;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:result_dart/result_dart.dart';

/// Implementation of [IOdbcRepository] using native ODBC connection.
///
/// Provides the concrete implementation of the repository interface,
/// translating domain operations into native ODBC calls and converting
/// native errors into domain error types.
///
/// This implementation can work with both sync [NativeOdbcConnection] and
/// async [AsyncNativeOdbcConnection] backends. When using async backend,
/// operations automatically execute in background isolates for non-blocking
/// behavior (ideal for Flutter apps).
///
/// This implementation manages connection ID mapping between domain
/// connection IDs (strings) and native connection IDs (integers).
///
/// Example (sync):
/// ```dart
/// final native = NativeOdbcConnection();
/// final repository = OdbcRepositoryImpl(native);
/// await repository.initialize();
/// ```
///
/// Example (async via ServiceLocator):
/// ```dart
/// final locator = ServiceLocator();
/// locator.initialize(useAsync: true);
/// final repository = locator.repository; // Uses AsyncNativeOdbcConnection
/// await repository.initialize();
/// ```
class OdbcRepositoryImpl implements IOdbcRepository {
  /// Creates a new [OdbcRepositoryImpl] instance.
  ///
  /// The `native` parameter can be either [NativeOdbcConnection] or
  /// [AsyncNativeOdbcConnection]. When using async connection, all operations
  /// execute in background isolates for non-blocking behavior.
  OdbcRepositoryImpl(this._native);

  /// Can be either sync or async connection.
  /// Use [NativeOdbcConnection] for blocking operations (CLI tools).
  /// Use [AsyncNativeOdbcConnection] for non-blocking operations (Flutter
  /// apps).
  final dynamic _native;
  final Map<String, int> _connectionIds = {};
  final Map<String, ConnectionOptions?> _connectionOptions = {};
  final Map<String, String> _connectionStrings = {};
  final Map<int, List<String>> _namedParamOrderByStmtId = {};

  /// Message used when a query times out (ConnectionOptions.queryTimeout).
  static const String _queryTimedOutMessage = 'Query timed out';

  /// Whether this repository uses async backend (non-blocking operations).
  bool get _isAsync => _native is AsyncNativeOdbcConnection;

  /// Converts native error to Failure with proper error type.
  ///
  /// Tries to get structured error first (with SQLSTATE and native code),
  /// then falls back to simple error message, then to fallback message.
  Future<Failure<T, OdbcError>> _convertNativeErrorToFailure<T extends Object>({
    required OdbcError Function({
      required String message,
      String? sqlState,
      int? nativeCode,
    }) errorFactory,
    String? fallbackMessage,
  }) async {
    final structuredError = _isAsync
        ? await (_native as AsyncNativeOdbcConnection).getStructuredError()
        : (_native as NativeOdbcConnection).getStructuredError();

    if (structuredError != null) {
      return Failure<T, OdbcError>(
        errorFactory(
          message: structuredError.message,
          sqlState: structuredError.sqlStateString,
          nativeCode: structuredError.nativeCode,
        ),
      );
    }

    final errorMsg = _isAsync
        ? await (_native as AsyncNativeOdbcConnection).getError()
        : (_native as NativeOdbcConnection).getError();

    final finalMessage =
        errorMsg.isNotEmpty ? errorMsg : (fallbackMessage ?? 'Unknown error');

    return Failure<T, OdbcError>(
      errorFactory(message: finalMessage),
    );
  }

  /// Reconnects using [connectionString] and reassigns the same [connectionId].
  /// Call after disconnect when auto-reconnecting on connectionLost.
  Future<Result<Unit>> _reconnect(
    String connectionId,
    String connectionString,
    ConnectionOptions? options,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId != null) {
      if (_isAsync) {
        await (_native as AsyncNativeOdbcConnection).disconnect(nativeId);
      } else {
        (_native as NativeOdbcConnection).disconnect(nativeId);
      }
      _connectionIds.remove(connectionId);
      _connectionOptions.remove(connectionId);
      _connectionStrings.remove(connectionId);
    }

    final timeoutMs = options?.loginTimeoutMs ?? 0;
    final connId = _isAsync
        ? await (_native as AsyncNativeOdbcConnection)
            .connect(connectionString, timeoutMs: timeoutMs)
        : (timeoutMs > 0
            ? (_native as NativeOdbcConnection)
                .connectWithTimeout(connectionString, timeoutMs)
            : (_native as NativeOdbcConnection).connect(connectionString));

    if (connId == 0) {
      return _convertNativeErrorToFailure<Unit>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            ConnectionError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Reconnect failed',
      );
    }

    _connectionIds[connectionId] = connId;
    _connectionOptions[connectionId] = options;
    _connectionStrings[connectionId] = connectionString;
    return const Success(unit);
  }

  /// Runs [operation]; on Failure with connection-lost error and
  /// [ConnectionOptions.autoReconnectOnConnectionLost], attempts reconnect
  /// and re-runs once per attempt up to
  /// [ConnectionOptions.effectiveMaxReconnectAttempts].
  Future<Result<T>> _withReconnect<T extends Object>(
    String connectionId,
    Future<Result<T>> Function() operation,
  ) async {
    var result = await operation();
    if (result.isSuccess()) return result;

    final err = result.fold<OdbcError?>((_) => null, (e) => e as OdbcError);
    if (err == null || err.category != ErrorCategory.connectionLost) {
      return result;
    }

    final opts = _connectionOptions[connectionId];
    if (opts == null || !opts.autoReconnectOnConnectionLost) return result;

    final connectionString = _connectionStrings[connectionId];
    if (connectionString == null || connectionString.isEmpty) return result;

    final maxAttempts = opts.effectiveMaxReconnectAttempts;
    final backoff = opts.effectiveReconnectBackoff;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) {
        await Future<void>.delayed(backoff);
      }
      final reconnected = await _reconnect(
        connectionId,
        connectionString,
        opts,
      );
      if (reconnected.isError()) {
        return reconnected as Failure<T, OdbcError>;
      }
      result = await operation();
      if (result.isSuccess()) return result;
      final retryErr =
          result.fold<OdbcError?>((_) => null, (e) => e as OdbcError);
      if (retryErr == null ||
          retryErr.category != ErrorCategory.connectionLost) {
        return result;
      }
    }
    return result;
  }

  @override
  Future<Result<Unit>> initialize() async {
    try {
      final success = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).initialize()
          : (_native as NativeOdbcConnection).initialize();

      if (success) {
        return const Success(unit);
      } else {
        return const Failure<Unit, OdbcError>(
          EnvironmentNotInitializedError(),
        );
      }
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) async {
    if (connectionString.isEmpty) {
      return const Failure<Connection, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }

    try {
      final timeoutMs = options?.loginTimeoutMs ?? 0;
      final connId = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .connect(connectionString, timeoutMs: timeoutMs)
          : (timeoutMs > 0
              ? (_native as NativeOdbcConnection)
                  .connectWithTimeout(connectionString, timeoutMs)
              : (_native as NativeOdbcConnection).connect(connectionString));

      if (connId == 0) {
        return await _convertNativeErrorToFailure<Connection>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              ConnectionError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to connect to database',
        );
      }

      final connection = Connection(
        id: connId.toString(),
        connectionString: connectionString,
        createdAt: DateTime.now(),
        isActive: true,
      );

      _connectionIds[connection.id] = connId;
      _connectionOptions[connection.id] = options;
      _connectionStrings[connection.id] = connectionString;

      return Success(connection);
    } on Exception catch (e) {
      return Failure<Connection, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> disconnect(String connectionId) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    try {
      final success = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).disconnect(nativeId)
          : (_native as NativeOdbcConnection).disconnect(nativeId);

      if (success) {
        _connectionIds.remove(connectionId);
        _connectionOptions.remove(connectionId);
        _connectionStrings.remove(connectionId);
        return const Success(unit);
      } else {
        return await _convertNativeErrorToFailure<Unit>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              ConnectionError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to disconnect from database',
        );
      }
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<QueryResult>> executeQuery(
    String connectionId,
    String sql,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    Future<Result<QueryResult>> run() async {
      try {
        final allRows = <List<dynamic>>[];
        final columns = <String>[];
        final maxBytes = _connectionOptions[connectionId]?.maxResultBufferBytes;

        Stream<ParsedRowBuffer> stream;
        try {
          stream = _isAsync
              ? (_native as AsyncNativeOdbcConnection)
                  .streamQueryBatched(nativeId, sql, maxBufferBytes: maxBytes)
              : (_native as NativeOdbcConnection)
                  .streamQueryBatched(nativeId, sql);
        } on Exception {
          stream = _isAsync
              ? (_native as AsyncNativeOdbcConnection)
                  .streamQuery(nativeId, sql, maxBufferBytes: maxBytes)
              : (_native as NativeOdbcConnection).streamQuery(nativeId, sql);
        }

        await for (final chunk in stream) {
          if (columns.isEmpty && chunk.columns.isNotEmpty) {
            columns.addAll(chunk.columns.map((c) => c.name));
          }
          allRows.addAll(chunk.rows);
        }

        final result = QueryResult(
          columns: columns,
          rows: allRows,
          rowCount: allRows.length,
        );

        return Success(result);
      } on Exception catch (e) {
        return _convertNativeErrorToFailure<QueryResult>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: e.toString(),
        );
      }
    }

    final queryTimeout = _connectionOptions[connectionId]?.queryTimeout;
    Future<Result<QueryResult>> runWithTimeout() {
      if (queryTimeout != null && queryTimeout != Duration.zero) {
        return run().timeout(
          queryTimeout,
          onTimeout: () => const Failure<QueryResult, OdbcError>(
            QueryError(message: _queryTimedOutMessage),
          ),
        );
      }
      return run();
    }

    return _withReconnect(connectionId, runWithTimeout);
  }

  @override
  bool isInitialized() => _isAsync
      ? (_native as AsyncNativeOdbcConnection).isInitialized
      : (_native as NativeOdbcConnection).isInitialized;

  QueryResult? _parseBufferToQueryResult(Uint8List? buf) {
    if (buf == null) return null;
    if (buf.isEmpty) {
      return const QueryResult(
        columns: [],
        rows: [],
        rowCount: 0,
      );
    }
    try {
      final p = BinaryProtocolParser.parse(buf);
      return QueryResult(
        columns: p.columns.map((c) => c.name).toList(),
        rows: p.rows,
        rowCount: p.rowCount,
      );
    } on Exception catch (_) {
      return null;
    }
  }

  QueryResult _toQueryResult(ParsedRowBuffer buffer) {
    return QueryResult(
      columns: buffer.columnNames,
      rows: buffer.rows,
      rowCount: buffer.rowCount,
    );
  }

  QueryResultMulti _toQueryResultMulti(List<MultiResultItem> items) {
    final mapped = items.map((item) {
      final resultSet = item.resultSet;
      if (resultSet != null) {
        return QueryResultMultiItem.resultSet(_toQueryResult(resultSet));
      }
      return QueryResultMultiItem.rowCount(item.rowCount ?? 0);
    }).toList(growable: false);

    return QueryResultMulti(items: mapped);
  }

  List<ParamValue> _toParamValues(List<dynamic> params) {
    return params.map((o) {
      if (o == null) return const ParamValueNull();
      if (o is ParamValue) return o;
      if (o is int) {
        if (o >= -0x80000000 && o <= 0x7FFFFFFF) {
          return ParamValueInt32(o);
        }
        return ParamValueInt64(o);
      }
      if (o is String) return ParamValueString(o);
      if (o is List<int>) return ParamValueBinary(o);
      return ParamValueString(o.toString());
    }).toList();
  }

  @override
  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    try {
      final txnId = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .beginTransaction(nativeId, isolationLevel.value)
          : (_native as NativeOdbcConnection)
              .beginTransaction(nativeId, isolationLevel.value);

      if (txnId == 0) {
        return await _convertNativeErrorToFailure<int>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to begin transaction',
        );
      }
      return Success(txnId);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> commitTransaction(
    String connectionId,
    int txnId,
  ) async {
    try {
      final ok = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .commitTransaction(txnId)
          : (_native as NativeOdbcConnection).commitTransaction(txnId);

      if (ok) return const Success(unit);
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to commit transaction',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(QueryError(message: e.toString()));
    }
  }

  @override
  Future<Result<Unit>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async {
    try {
      final ok = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .rollbackTransaction(txnId)
          : (_native as NativeOdbcConnection).rollbackTransaction(txnId);

      if (ok) return const Success(unit);
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to rollback transaction',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(QueryError(message: e.toString()));
    }
  }

  @override
  Future<Result<Unit>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    try {
      final ok = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .createSavepoint(txnId, name)
          : (_native as NativeOdbcConnection).createSavepoint(txnId, name);

      if (ok) return const Success(unit);
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to create savepoint',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(QueryError(message: e.toString()));
    }
  }

  @override
  Future<Result<Unit>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    try {
      final ok = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .rollbackToSavepoint(txnId, name)
          : (_native as NativeOdbcConnection).rollbackToSavepoint(txnId, name);

      if (ok) return const Success(unit);
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to rollback to savepoint',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(QueryError(message: e.toString()));
    }
  }

  @override
  Future<Result<Unit>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    try {
      final ok = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .releaseSavepoint(txnId, name)
          : (_native as NativeOdbcConnection).releaseSavepoint(txnId, name);

      if (ok) return const Success(unit);
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to release savepoint',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(QueryError(message: e.toString()));
    }
  }

  @override
  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    try {
      final stmtId = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .prepare(nativeId, sql, timeoutMs: timeoutMs)
          : (_native as NativeOdbcConnection)
              .prepare(nativeId, sql, timeoutMs: timeoutMs);

      if (stmtId == 0) {
        return await _convertNativeErrorToFailure<int>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to prepare statement',
        );
      }
      return Success(stmtId);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(QueryError(message: e.toString()));
    }
  }

  @override
  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    try {
      final extract = NamedParameterParser.extract(sql);
      final prepared = await prepare(
        connectionId,
        extract.cleanedSql,
        timeoutMs: timeoutMs,
      );
      final stmtId = prepared.getOrElse((_) => 0);
      if (stmtId > 0) {
        _namedParamOrderByStmtId[stmtId] = extract.paramNames;
      }
      return prepared;
    } on Exception catch (e) {
      return Failure<int, OdbcError>(QueryError(message: e.toString()));
    }
  }

  @override
  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId, [
    List<dynamic>? params,
    StatementOptions? options,
  ]) async {
    try {
      final list = params ?? [];
      final pv = list.isEmpty ? null : _toParamValues(list);
      final timeoutMs = options?.timeout?.inMilliseconds ?? 0;
      final fetchSizeVal = options?.fetchSize ?? 1000;
      final maxBuf = options?.maxBufferSize;
      final buf = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).executePrepared(
              stmtId,
              pv,
              timeoutMs,
              fetchSizeVal,
              maxBufferBytes: maxBuf,
            )
          : (_native as NativeOdbcConnection).executePrepared(
              stmtId,
              pv,
              timeoutMs,
              fetchSizeVal,
              maxBufferBytes: maxBuf,
            );

      final qr = _parseBufferToQueryResult(buf);
      if (qr == null) {
        return await _convertNativeErrorToFailure<QueryResult>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to execute prepared statement',
        );
      }
      return Success(qr);
    } on Exception catch (e) {
      return _convertNativeErrorToFailure<QueryResult>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: e.toString(),
      );
    }
  }

  @override
  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) async {
    final paramOrder = _namedParamOrderByStmtId[stmtId];
    if (paramOrder == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(
          message: 'Statement was not prepared with prepareNamed',
        ),
      );
    }

    try {
      final positional = NamedParameterParser.toPositionalParams(
        namedParams: namedParams,
        paramNames: paramOrder,
      );
      return executePrepared(connectionId, stmtId, positional, options);
    } on ParameterMissingException catch (e) {
      return Failure<QueryResult, OdbcError>(
        ValidationError(message: e.message),
      );
    } on Exception catch (e) {
      return Failure<QueryResult, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> closeStatement(String connectionId, int stmtId) async {
    try {
      final ok = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).closeStatement(stmtId)
          : (_native as NativeOdbcConnection).closeStatement(stmtId);

      if (ok) return const Success(unit);
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to close statement',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(QueryError(message: e.toString()));
    } finally {
      _namedParamOrderByStmtId.remove(stmtId);
    }
  }

  @override
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    Future<Result<QueryResult>> run() async {
      try {
        final pv = _toParamValues(params);
        final maxBytes = _connectionOptions[connectionId]?.maxResultBufferBytes;
        final buf = _isAsync
            ? await (_native as AsyncNativeOdbcConnection).executeQueryParams(
                nativeId,
                sql,
                pv,
                maxBufferBytes: maxBytes,
              )
            : (_native as NativeOdbcConnection).executeQueryParams(
                nativeId,
                sql,
                pv,
                maxBufferBytes: maxBytes,
              );

        final qr = _parseBufferToQueryResult(buf);
        if (qr == null) {
          return await _convertNativeErrorToFailure<QueryResult>(
            errorFactory: ({
              required message,
              sqlState,
              nativeCode,
            }) =>
                QueryError(
              message: message,
              sqlState: sqlState,
              nativeCode: nativeCode,
            ),
            fallbackMessage: 'Failed to execute parameterized query',
          );
        }
        return Success(qr);
      } on Exception catch (e) {
        return _convertNativeErrorToFailure<QueryResult>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: e.toString(),
        );
      }
    }

    final queryTimeout = _connectionOptions[connectionId]?.queryTimeout;
    Future<Result<QueryResult>> runWithTimeout() {
      if (queryTimeout != null && queryTimeout != Duration.zero) {
        return run().timeout(
          queryTimeout,
          onTimeout: () => const Failure<QueryResult, OdbcError>(
            QueryError(message: _queryTimedOutMessage),
          ),
        );
      }
      return run();
    }

    return _withReconnect(connectionId, runWithTimeout);
  }

  @override
  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) async {
    try {
      final extract = NamedParameterParser.extract(sql);
      final positional = NamedParameterParser.toPositionalParams(
        namedParams: namedParams,
        paramNames: extract.paramNames,
      );
      return executeQueryParams(connectionId, extract.cleanedSql, positional);
    } on ParameterMissingException catch (e) {
      return Failure<QueryResult, OdbcError>(
        ValidationError(message: e.message),
      );
    } on Exception catch (e) {
      return Failure<QueryResult, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) async {
    final full = await executeQueryMultiFull(connectionId, sql);
    return full.fold(
      (success) => Success(success.firstResultSet),
      (error) => Failure<QueryResult, OdbcError>(
        error is OdbcError ? error : QueryError(message: error.toString()),
      ),
    );
  }

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResultMulti, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    Future<Result<QueryResultMulti>> run() async {
      try {
        final maxBytes = _connectionOptions[connectionId]?.maxResultBufferBytes;
        final buf = _isAsync
            ? await (_native as AsyncNativeOdbcConnection)
                .executeQueryMulti(nativeId, sql, maxBufferBytes: maxBytes)
            : (_native as NativeOdbcConnection)
                .executeQueryMulti(nativeId, sql, maxBufferBytes: maxBytes);

        if (buf == null || buf.isEmpty) {
          return const Success(
            QueryResultMulti(items: []),
          );
        }

        final items = MultiResultParser.parse(buf);
        return Success(_toQueryResultMulti(items));
      } on Exception catch (e) {
        return _convertNativeErrorToFailure<QueryResultMulti>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: e.toString(),
        );
      }
    }

    final queryTimeout = _connectionOptions[connectionId]?.queryTimeout;
    Future<Result<QueryResultMulti>> runWithTimeout() {
      if (queryTimeout != null && queryTimeout != Duration.zero) {
        return run().timeout(
          queryTimeout,
          onTimeout: () => const Failure<QueryResultMulti, OdbcError>(
            QueryError(message: _queryTimedOutMessage),
          ),
        );
      }
      return run();
    }

    return _withReconnect(connectionId, runWithTimeout);
  }

  @override
  Future<Result<QueryResult>> catalogTables(
    String connectionId, {
    String catalog = '',
    String schema = '',
  }) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    try {
      final buf = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).catalogTables(
              nativeId,
              catalog: catalog,
              schema: schema,
            )
          : (_native as NativeOdbcConnection).catalogTables(
              nativeId,
              catalog: catalog,
              schema: schema,
            );

      final qr = _parseBufferToQueryResult(buf);
      if (qr == null) {
        return await _convertNativeErrorToFailure<QueryResult>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to list catalog tables',
        );
      }
      return Success(qr);
    } on Exception catch (e) {
      return _convertNativeErrorToFailure<QueryResult>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: e.toString(),
      );
    }
  }

  @override
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    try {
      final buf = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .catalogColumns(nativeId, table)
          : (_native as NativeOdbcConnection).catalogColumns(nativeId, table);

      final qr = _parseBufferToQueryResult(buf);
      if (qr == null) {
        return await _convertNativeErrorToFailure<QueryResult>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to list catalog columns',
        );
      }
      return Success(qr);
    } on Exception catch (e) {
      return _convertNativeErrorToFailure<QueryResult>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: e.toString(),
      );
    }
  }

  @override
  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    try {
      final buf = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .catalogTypeInfo(nativeId)
          : (_native as NativeOdbcConnection).catalogTypeInfo(nativeId);

      final qr = _parseBufferToQueryResult(buf);
      if (qr == null) {
        return await _convertNativeErrorToFailure<QueryResult>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to get catalog type info',
        );
      }
      return Success(qr);
    } on Exception catch (e) {
      return _convertNativeErrorToFailure<QueryResult>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: e.toString(),
      );
    }
  }

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize,
  ) async {
    if (!_isAsync && !(_native as NativeOdbcConnection).isInitialized) {
      final r = await initialize();
      final err = r.exceptionOrNull();
      if (err != null) {
        return Failure<int, OdbcError>(
          err is OdbcError ? err : const EnvironmentNotInitializedError(),
        );
      }
    }
    try {
      final poolId = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .poolCreate(connectionString, maxSize)
          : (_native as NativeOdbcConnection)
              .poolCreate(connectionString, maxSize);

      if (poolId == 0) {
        return await _convertNativeErrorToFailure<int>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              ConnectionError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to create pool',
        );
      }
      return Success(poolId);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(ConnectionError(message: e.toString()));
    }
  }

  @override
  Future<Result<Connection>> poolGetConnection(int poolId) async {
    try {
      final connId = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .poolGetConnection(poolId)
          : (_native as NativeOdbcConnection).poolGetConnection(poolId);

      if (connId == 0) {
        return await _convertNativeErrorToFailure<Connection>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              ConnectionError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to get connection from pool',
        );
      }
      final c = Connection(
        id: connId.toString(),
        connectionString: '',
        createdAt: DateTime.now(),
        isActive: true,
      );
      _connectionIds[c.id] = connId;
      return Success(c);
    } on Exception catch (e) {
      return Failure<Connection, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> poolReleaseConnection(String connectionId) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    try {
      final ok = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .poolReleaseConnection(nativeId)
          : (_native as NativeOdbcConnection).poolReleaseConnection(nativeId);

      if (ok) {
        _connectionIds.remove(connectionId);
        return const Success(unit);
      }
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            ConnectionError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to release connection to pool',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<bool>> poolHealthCheck(int poolId) async {
    try {
      final result = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).poolHealthCheck(poolId)
          : (_native as NativeOdbcConnection).poolHealthCheck(poolId);

      return Success(result);
    } on Exception catch (e) {
      return Failure<bool, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<PoolState>> poolGetState(int poolId) async {
    try {
      final s = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).poolGetState(poolId)
          : (_native as NativeOdbcConnection).poolGetState(poolId);

      if (s == null) {
        return await _convertNativeErrorToFailure<PoolState>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              ConnectionError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to get pool state',
        );
      }
      return Success(PoolState(size: s.size, idle: s.idle));
    } on Exception catch (e) {
      return Failure<PoolState, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> poolClose(int poolId) async {
    try {
      final ok = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).poolClose(poolId)
          : (_native as NativeOdbcConnection).poolClose(poolId);

      if (ok) return const Success(unit);
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            ConnectionError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to close pool',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    try {
      final n = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).bulkInsertArray(
              nativeId,
              table,
              columns,
              Uint8List.fromList(dataBuffer),
              rowCount,
            )
          : (_native as NativeOdbcConnection).bulkInsertArray(
              nativeId,
              table,
              columns,
              Uint8List.fromList(dataBuffer),
              rowCount,
            );

      if (n < 0) {
        return await _convertNativeErrorToFailure<int>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to bulk insert',
        );
      }
      return Success(n);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(QueryError(message: e.toString()));
    }
  }

  @override
  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  }) async {
    final buffer = Uint8List.fromList(dataBuffer);

    if (parallelism <= 1) {
      final connId = _isAsync
          ? await (_native as AsyncNativeOdbcConnection)
              .poolGetConnection(poolId)
          : (_native as NativeOdbcConnection).poolGetConnection(poolId);
      if (connId == 0) {
        return _convertNativeErrorToFailure<int>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage:
              'Failed to get pool connection for bulk insert fallback',
        );
      }

      try {
        final n = _isAsync
            ? await (_native as AsyncNativeOdbcConnection).bulkInsertArray(
                connId,
                table,
                columns,
                buffer,
                rowCount,
              )
            : (_native as NativeOdbcConnection).bulkInsertArray(
                connId,
                table,
                columns,
                buffer,
                rowCount,
              );

        if (n < 0) {
          return await _convertNativeErrorToFailure<int>(
            errorFactory: ({required message, sqlState, nativeCode}) =>
                QueryError(
              message: message,
              sqlState: sqlState,
              nativeCode: nativeCode,
            ),
            fallbackMessage: 'Failed to bulk insert in fallback mode',
          );
        }
        return Success(n);
      } on Exception catch (e) {
        return Failure<int, OdbcError>(QueryError(message: e.toString()));
      } finally {
        if (_isAsync) {
          await (_native as AsyncNativeOdbcConnection)
              .poolReleaseConnection(connId);
        } else {
          (_native as NativeOdbcConnection).poolReleaseConnection(connId);
        }
      }
    }

    try {
      final n = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).bulkInsertParallel(
              poolId,
              table,
              columns,
              buffer,
              parallelism,
            )
          : (_native as NativeOdbcConnection).bulkInsertParallel(
              poolId,
              table,
              columns,
              buffer,
              parallelism,
            );

      if (n < 0) {
        return await _convertNativeErrorToFailure<int>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to execute parallel bulk insert',
        );
      }
      return Success(n);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(QueryError(message: e.toString()));
    }
  }

  @override
  Future<Result<OdbcMetrics>> getMetrics() async {
    try {
      if (_isAsync) {
        final m = await (_native as AsyncNativeOdbcConnection).getMetrics();
        if (m == null) {
          return await _convertNativeErrorToFailure<OdbcMetrics>(
            errorFactory: ({required message, sqlState, nativeCode}) =>
                QueryError(
              message: message,
              sqlState: sqlState,
              nativeCode: nativeCode,
            ),
            fallbackMessage: 'Failed to get metrics',
          );
        }
        return Success(m);
      } else {
        final m = (_native as NativeOdbcConnection).getMetrics();
        if (m == null) {
          return await _convertNativeErrorToFailure<OdbcMetrics>(
            errorFactory: ({required message, sqlState, nativeCode}) =>
                QueryError(
              message: message,
              sqlState: sqlState,
              nativeCode: nativeCode,
            ),
            fallbackMessage: 'Failed to get metrics',
          );
        }
        // Sync backend returns infrastructure OdbcMetrics, convert to domain
        final infraMetrics = m;
        return Success(
          OdbcMetrics(
            queryCount: infraMetrics.queryCount,
            errorCount: infraMetrics.errorCount,
            uptimeSecs: infraMetrics.uptimeSecs,
            totalLatencyMillis: infraMetrics.totalLatencyMillis,
            avgLatencyMillis: infraMetrics.avgLatencyMillis,
          ),
        );
      }
    } on Exception catch (e) {
      return Failure<OdbcMetrics, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> clearStatementCache() async {
    try {
      final cleared = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).clearStatementCache()
          : (_native as NativeOdbcConnection).clearStatementCache();

      if (!cleared) {
        return await _convertNativeErrorToFailure<Unit>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to clear statement cache',
        );
      }
      return const Success(unit);
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<PreparedStatementMetrics>>
      getPreparedStatementsMetrics() async {
    try {
      final metrics = _isAsync
          ? await (_native as AsyncNativeOdbcConnection).getCacheMetrics()
          : (_native as NativeOdbcConnection).getCacheMetrics();

      if (metrics == null) {
        return await _convertNativeErrorToFailure<PreparedStatementMetrics>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to get statement metrics',
        );
      }
      return Success(
        PreparedStatementMetrics(
          cacheSize: metrics.cacheSize,
          cacheMaxSize: metrics.cacheMaxSize,
          cacheHits: metrics.cacheHits,
          cacheMisses: metrics.cacheMisses,
          totalPrepares: metrics.totalPrepares,
          totalExecutions: metrics.totalExecutions,
          memoryUsageBytes: metrics.memoryUsageBytes,
          avgExecutionsPerStmt: metrics.avgExecutionsPerStmt,
        ),
      );
    } on Exception catch (e) {
      return Failure<PreparedStatementMetrics, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<String?> detectDriver(String connectionString) async {
    if (connectionString.trim().isEmpty) {
      return null;
    }
    return _isAsync
        ? await (_native as AsyncNativeOdbcConnection)
            .detectDriver(connectionString)
        : (_native as NativeOdbcConnection).detectDriver(connectionString);
  }
}
