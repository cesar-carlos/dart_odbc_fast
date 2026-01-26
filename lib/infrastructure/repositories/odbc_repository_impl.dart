import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser, ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:result_dart/result_dart.dart';

/// Implementation of [IOdbcRepository] using native ODBC connection.
///
/// Provides the concrete implementation of the repository interface,
/// translating domain operations into native ODBC calls and converting
/// native errors into domain error types.
///
/// This implementation manages connection ID mapping between domain
/// connection IDs (strings) and native connection IDs (integers).
///
/// Example:
/// ```dart
/// final native = NativeOdbcConnection();
/// final repository = OdbcRepositoryImpl(native);
/// await repository.initialize();
/// ```
class OdbcRepositoryImpl implements IOdbcRepository {
  /// Creates a new [OdbcRepositoryImpl] instance.
  ///
  /// The native parameter must be a valid native ODBC connection instance.
  OdbcRepositoryImpl(this._native);
  final NativeOdbcConnection _native;
  final Map<String, int> _connectionIds = {};

  /// Converts native error to Failure with proper error type.
  ///
  /// Tries to get structured error first (with SQLSTATE and native code),
  /// then falls back to simple error message, then to fallback message.
  Failure<T, OdbcError> _convertNativeErrorToFailure<T extends Object>({
    required OdbcError Function({
      required String message,
      String? sqlState,
      int? nativeCode,
    }) errorFactory,
    String? fallbackMessage,
  }) {
    final structuredError = _native.getStructuredError();
    if (structuredError != null) {
      return Failure<T, OdbcError>(
        errorFactory(
          message: structuredError.message,
          sqlState: structuredError.sqlStateString,
          nativeCode: structuredError.nativeCode,
        ),
      );
    }

    final errorMsg = _native.getError();
    final finalMessage =
        errorMsg.isNotEmpty ? errorMsg : (fallbackMessage ?? 'Unknown error');

    return Failure<T, OdbcError>(
      errorFactory(message: finalMessage),
    );
  }

  @override
  Future<Result<Unit>> initialize() async {
    try {
      final success = _native.initialize();
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
    String connectionString,
  ) async {
    if (connectionString.isEmpty) {
      return const Failure<Connection, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }

    try {
      final connId = _native.connect(connectionString);
      if (connId == 0) {
        return _convertNativeErrorToFailure<Connection>(
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
      final success = _native.disconnect(nativeId);
      if (success) {
        _connectionIds.remove(connectionId);
        return const Success(unit);
      } else {
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

    try {
      final allRows = <List<dynamic>>[];
      final columns = <String>[];

      Stream<ParsedRowBuffer> stream;
      try {
        stream = _native.streamQueryBatched(nativeId, sql);
      } on Exception {
        stream = _native.streamQuery(nativeId, sql);
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

  @override
  bool isInitialized() => _native.isInitialized;

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
      final txnId = _native.beginTransaction(nativeId, isolationLevel.value);
      if (txnId == 0) {
        return _convertNativeErrorToFailure<int>(
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
      final ok = _native.commitTransaction(txnId);
      if (ok) return const Success(unit);
      return _convertNativeErrorToFailure<Unit>(
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
      final ok = _native.rollbackTransaction(txnId);
      if (ok) return const Success(unit);
      return _convertNativeErrorToFailure<Unit>(
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
      final stmtId = _native.prepare(nativeId, sql, timeoutMs: timeoutMs);
      if (stmtId == 0) {
        return _convertNativeErrorToFailure<int>(
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
  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId, [
    List<dynamic>? params,
  ]) async {
    try {
      final list = params ?? [];
      final pv = list.isEmpty ? null : _toParamValues(list);
      final buf = _native.executePrepared(stmtId, pv);
      final qr = _parseBufferToQueryResult(buf);
      if (qr == null) {
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
  Future<Result<Unit>> closeStatement(String connectionId, int stmtId) async {
    try {
      final ok = _native.closeStatement(stmtId);
      if (ok) return const Success(unit);
      return _convertNativeErrorToFailure<Unit>(
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
    try {
      final pv = _toParamValues(params);
      final buf = _native.executeQueryParams(nativeId, sql, pv);
      final qr = _parseBufferToQueryResult(buf);
      if (qr == null) {
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

  @override
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    try {
      final buf = _native.executeQueryMulti(nativeId, sql);
      final qr = _parseBufferToQueryResult(buf);
      if (qr == null) {
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
          fallbackMessage: 'Failed to execute multi-result query',
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
      final buf = _native.catalogTables(
        nativeId,
        catalog: catalog,
        schema: schema,
      );
      final qr = _parseBufferToQueryResult(buf);
      if (qr == null) {
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
      final buf = _native.catalogColumns(nativeId, table);
      final qr = _parseBufferToQueryResult(buf);
      if (qr == null) {
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
      final buf = _native.catalogTypeInfo(nativeId);
      final qr = _parseBufferToQueryResult(buf);
      if (qr == null) {
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
    if (!_native.isInitialized) {
      final r = await initialize();
      final err = r.exceptionOrNull();
      if (err != null) {
        return Failure<int, OdbcError>(
          err is OdbcError ? err : const EnvironmentNotInitializedError(),
        );
      }
    }
    try {
      final poolId = _native.poolCreate(connectionString, maxSize);
      if (poolId == 0) {
        return _convertNativeErrorToFailure<int>(
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
      final connId = _native.poolGetConnection(poolId);
      if (connId == 0) {
        return _convertNativeErrorToFailure<Connection>(
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
      final ok = _native.poolReleaseConnection(nativeId);
      if (ok) {
        _connectionIds.remove(connectionId);
        return const Success(unit);
      }
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
      return Success(_native.poolHealthCheck(poolId));
    } on Exception catch (e) {
      return Failure<bool, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<PoolState>> poolGetState(int poolId) async {
    try {
      final s = _native.poolGetState(poolId);
      if (s == null) {
        return _convertNativeErrorToFailure<PoolState>(
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
      final ok = _native.poolClose(poolId);
      if (ok) return const Success(unit);
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
      final n = _native.bulkInsertArray(
        nativeId,
        table,
        columns,
        Uint8List.fromList(dataBuffer),
        rowCount,
      );
      if (n < 0) {
        return _convertNativeErrorToFailure<int>(
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
  Future<Result<OdbcMetrics>> getMetrics() async {
    try {
      final m = _native.getMetrics();
      if (m == null) {
        return _convertNativeErrorToFailure<OdbcMetrics>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to get metrics',
        );
      }
      return Success(
        OdbcMetrics(
          queryCount: m.queryCount,
          errorCount: m.errorCount,
          uptimeSecs: m.uptimeSecs,
          totalLatencyMillis: m.totalLatencyMillis,
          avgLatencyMillis: m.avgLatencyMillis,
        ),
      );
    } on Exception catch (e) {
      return Failure<OdbcMetrics, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }
}
