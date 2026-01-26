import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/wrappers/catalog_query.dart';
import 'package:odbc_fast/infrastructure/native/wrappers/connection_pool.dart';
import 'package:odbc_fast/infrastructure/native/wrappers/prepared_statement.dart';
import 'package:odbc_fast/infrastructure/native/wrappers/transaction_handle.dart';
import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';

class NativeOdbcConnection implements OdbcConnectionBackend {
  final OdbcNative _native;
  bool _isInitialized = false;

  NativeOdbcConnection() : _native = OdbcNative();

  bool initialize() {
    if (_isInitialized) return true;

    final result = _native.init();
    if (result) {
      _isInitialized = true;
    }
    return result;
  }

  int connect(String connectionString) {
    if (!_isInitialized) {
      throw StateError('Environment not initialized');
    }
    return _native.connect(connectionString);
  }

  bool disconnect(int connectionId) {
    return _native.disconnect(connectionId);
  }

  String getError() => _native.getError();

  StructuredError? getStructuredError() => _native.getStructuredError();

  bool get isInitialized => _isInitialized;

  int beginTransaction(int connectionId, int isolationLevel) =>
      _native.transactionBegin(connectionId, isolationLevel);

  TransactionHandle? beginTransactionHandle(
    int connectionId,
    int isolationLevel,
  ) {
    final txnId = beginTransaction(connectionId, isolationLevel);
    if (txnId == 0) return null;
    return TransactionHandle(this, txnId);
  }

  bool commitTransaction(int txnId) => _native.transactionCommit(txnId);

  bool rollbackTransaction(int txnId) => _native.transactionRollback(txnId);

  int prepare(int connectionId, String sql, {int timeoutMs = 0}) =>
      _native.prepare(connectionId, sql, timeoutMs: timeoutMs);

  PreparedStatement? prepareStatement(
    int connectionId,
    String sql, {
    int timeoutMs = 0,
  }) {
    final stmtId = prepare(connectionId, sql, timeoutMs: timeoutMs);
    if (stmtId == 0) return null;
    return PreparedStatement(this, stmtId);
  }

  Uint8List? executePrepared(int stmtId, [List<ParamValue>? params]) =>
      _native.executeTyped(stmtId, params);

  bool closeStatement(int stmtId) => _native.closeStatement(stmtId);

  Uint8List? executeQueryParams(
    int connectionId,
    String sql,
    List<ParamValue> params,
  ) =>
      _native.execQueryParamsTyped(connectionId, sql, params);

  Uint8List? executeQueryMulti(int connectionId, String sql) =>
      _native.execQueryMulti(connectionId, sql);

  Uint8List? catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  }) =>
      _native.catalogTables(
        connectionId,
        catalog: catalog,
        schema: schema,
      );

  CatalogQuery catalogQuery(int connectionId) =>
      CatalogQuery(this, connectionId);

  Uint8List? catalogColumns(int connectionId, String table) =>
      _native.catalogColumns(connectionId, table);

  Uint8List? catalogTypeInfo(int connectionId) =>
      _native.catalogTypeInfo(connectionId);

  int poolCreate(String connectionString, int maxSize) =>
      _native.poolCreate(connectionString, maxSize);

  ConnectionPool? createConnectionPool(String connectionString, int maxSize) {
    final poolId = poolCreate(connectionString, maxSize);
    if (poolId == 0) return null;
    return ConnectionPool(this, poolId);
  }

  int poolGetConnection(int poolId) => _native.poolGetConnection(poolId);

  bool poolReleaseConnection(int connectionId) =>
      _native.poolReleaseConnection(connectionId);

  bool poolHealthCheck(int poolId) => _native.poolHealthCheck(poolId);

  ({int size, int idle})? poolGetState(int poolId) =>
      _native.poolGetState(poolId);

  bool poolClose(int poolId) => _native.poolClose(poolId);

  int bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) =>
      _native.bulkInsertArray(
        connectionId,
        table,
        columns,
        dataBuffer,
        rowCount,
      );

  OdbcMetrics? getMetrics() => _native.getMetrics();

  Stream<ParsedRowBuffer> streamQuery(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
  }) async* {
    final streamId =
        _native.streamStart(connectionId, sql, chunkSize: chunkSize);

    if (streamId == 0) {
      throw Exception('Failed to start stream: ${_native.getError()}');
    }

    try {
      while (true) {
        final result = _native.streamFetch(streamId);

        if (!result.success) {
          throw Exception('Stream fetch failed: ${_native.getError()}');
        }

        if (result.data == null || result.data!.isEmpty) {
          break;
        }

        final chunk = Uint8List.fromList(result.data!);
        final parsed = BinaryProtocolParser.parse(chunk);
        yield parsed;

        if (!result.hasMore) {
          break;
        }
      }
    } finally {
      _native.streamClose(streamId);
    }
  }

  void dispose() {
    _native.dispose();
  }
}
