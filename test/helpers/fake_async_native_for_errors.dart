/// Minimal `AsyncNativeOdbcConnection` fake for repository error-mapping
/// tests. Covers the subset of FFI methods exercised by `OdbcRepositoryImpl`
/// without booting a real ODBC environment.
library;

import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

/// Fake async native connection for repository unit tests. Each test toggles
/// the public fields to drive specific success / failure shapes through the
/// repository without a live driver.
///
/// The fake intentionally keeps the surface narrow — only methods actually
/// invoked by tests are overridden. New tests should extend this class
/// (locally) when they need additional FFI methods rather than growing the
/// shared fake.
class FakeAsyncNativeForRepositoryErrors extends AsyncNativeOdbcConnection {
  FakeAsyncNativeForRepositoryErrors() : super(requestTimeout: Duration.zero);

  bool initializeSuccess = true;
  bool disconnectSuccess = true;
  bool connectReturnsZero = false;
  bool cancelStatementSuccess = true;
  String? validateConnectionStringResult = 'rejected by fake';
  String errorMessage = 'disconnect failed';

  StructuredError? globalStructuredError;
  StructuredError? connectionStructuredError;

  int prepareResult = 100;
  int beginTransactionResult = 0;
  int bulkInsertResult = 0;
  int streamMultiStartBatchedResult = 0;
  Uint8List? executePreparedResult;
  Uint8List? executeQueryMultiResult;

  List<StreamFetchResponse> streamFetchResponses = const [];

  int _nextNativeConn = 50;
  var _streamFetchCall = 0;

  @override
  Future<bool> initialize() async => initializeSuccess;

  @override
  Future<int> connect(String connectionString, {int timeoutMs = 0}) async {
    if (connectReturnsZero) return 0;
    return ++_nextNativeConn;
  }

  @override
  Future<String?> validateConnectionString(String connectionString) async =>
      validateConnectionStringResult;

  @override
  Future<bool> disconnect(int connectionId) async => disconnectSuccess;

  @override
  Future<String> getError() async => errorMessage;

  @override
  Future<StructuredError?> getStructuredError() async => globalStructuredError;

  @override
  Future<StructuredError?> getStructuredErrorForConnection(
    int connectionId,
  ) async =>
      connectionStructuredError;

  @override
  Future<int> beginTransaction(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
    int accessMode = 0,
    int lockTimeoutMs = 0,
  }) async =>
      beginTransactionResult;

  @override
  Future<int> prepare(
    int connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async =>
      prepareResult;

  @override
  Future<Uint8List?> executePrepared(
    int stmtId,
    List<ParamValue>? params,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  }) async =>
      executePreparedResult;

  @override
  Future<bool> cancelStatement(int stmtId) async => cancelStatementSuccess;

  @override
  Future<int> bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) async =>
      bulkInsertResult;

  @override
  Future<Uint8List?> executeQueryMulti(
    int connectionId,
    String sql, {
    int? maxBufferBytes,
  }) async =>
      executeQueryMultiResult;

  @override
  Future<int> streamMultiStartBatched(
    int connectionId,
    String sql, {
    int chunkSize = 64 * 1024,
  }) async =>
      streamMultiStartBatchedResult;

  @override
  Future<StreamFetchResponse> streamFetch(int streamId) async {
    final responses = streamFetchResponses;
    if (responses.isEmpty) {
      return StreamFetchResponse(0, success: false, error: 'no fetch queued');
    }
    final index = _streamFetchCall++;
    if (index >= responses.length) {
      return StreamFetchResponse(0, success: false, error: 'fetch exhausted');
    }
    return responses[index];
  }

  @override
  Future<bool> streamClose(int streamId) async => true;

  @override
  void dispose() {}
}
