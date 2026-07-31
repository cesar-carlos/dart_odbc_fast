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
  bool closeStatementSuccess = true;
  bool commitTransactionSuccess = true;
  bool rollbackTransactionSuccess = true;
  bool createSavepointSuccess = true;
  bool rollbackToSavepointSuccess = true;
  bool releaseSavepointSuccess = true;
  String? validateConnectionStringResult = 'rejected by fake';
  String errorMessage = 'disconnect failed';

  StructuredError? globalStructuredError;
  StructuredError? connectionStructuredError;

  int prepareResult = 100;
  int beginTransactionResult = 0;
  int bulkInsertResult = 0;
  int streamMultiStartBatchedResult = 0;
  int? streamMultiStartAsyncResult;
  int? lastStreamMultiStartResultEncodingWire;
  int? lastStreamMultiStartFetchSize;
  int? lastStreamMultiStartChunkSize;
  bool lastStreamMultiStartWasAsync = false;
  int? lastStreamFetchBufferSize;
  Uint8List? executePreparedResult;
  Uint8List? executeQueryMultiResult;

  /// Recorded arguments for the most recent transaction-shaped call.
  /// Tests assert on these to confirm parameters reached the fake.
  int? lastTxnId;
  String? lastSavepointName;

  int streamStartBatchedResult = 0;
  Uint8List? lastStreamStartParamsBuffer;
  String? lastStreamStartSql;

  List<StreamFetchResponse> streamFetchResponses = const [];
  List<int>? streamPollAsyncResponses;
  int streamPollAndFetchCallCount = 0;

  int _nextNativeConn = 50;
  var _streamFetchCall = 0;
  var _streamPollCall = 0;

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
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) async =>
      executePreparedResult;

  @override
  Future<bool> cancelStatement(int stmtId) async => cancelStatementSuccess;

  @override
  Future<bool> closeStatement(int stmtId) async => closeStatementSuccess;

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
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) async =>
      executeQueryMultiResult;

  @override
  Future<int> streamMultiStartBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
  }) async {
    lastStreamMultiStartResultEncodingWire = resultEncodingWire;
    lastStreamMultiStartFetchSize = fetchSize;
    lastStreamMultiStartChunkSize = chunkSize;
    lastStreamMultiStartWasAsync = false;
    return streamMultiStartBatchedResult;
  }

  @override
  Future<int> streamMultiStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
  }) async {
    lastStreamMultiStartResultEncodingWire = resultEncodingWire;
    lastStreamMultiStartFetchSize = fetchSize;
    lastStreamMultiStartChunkSize = chunkSize;
    lastStreamMultiStartWasAsync = true;
    return streamMultiStartAsyncResult ?? streamMultiStartBatchedResult;
  }

  @override
  Future<int> streamPollAsync(int streamId) async {
    final scripted = streamPollAsyncResponses;
    if (scripted != null) {
      if (_streamPollCall >= scripted.length) {
        return 2; // Done
      }
      return scripted[_streamPollCall++];
    }
    // Auto: Ready while fetches remain, then Done.
    if (_streamFetchCall < streamFetchResponses.length) {
      return 1; // Ready
    }
    return 2; // Done
  }

  @override
  Future<StreamPollFetchResponse> streamPollAndFetch(
    int streamId, {
    int? bufferSize,
  }) async {
    streamPollAndFetchCallCount++;
    lastStreamFetchBufferSize = bufferSize;
    final status = await streamPollAsync(streamId);
    if (status != 1) {
      return StreamPollFetchResponse(0, status: status);
    }
    final fetched = await streamFetch(streamId, bufferSize: bufferSize);
    return StreamPollFetchResponse(
      0,
      status: status,
      success: fetched.success,
      data: fetched.data,
      hasMore: fetched.hasMore,
      error: fetched.error,
    );
  }

  @override
  Future<int> streamStartBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
    Uint8List? paramsBuffer,
  }) async {
    lastStreamStartSql = sql;
    lastStreamStartParamsBuffer = paramsBuffer;
    return streamStartBatchedResult;
  }

  @override
  Future<StreamFetchResponse> streamFetch(
    int streamId, {
    int? bufferSize,
  }) async {
    lastStreamFetchBufferSize = bufferSize;
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
  Future<bool> streamCancel(int streamId) async => true;

  @override
  Future<bool> commitTransaction(int txnId) async {
    lastTxnId = txnId;
    return commitTransactionSuccess;
  }

  @override
  Future<bool> rollbackTransaction(int txnId) async {
    lastTxnId = txnId;
    return rollbackTransactionSuccess;
  }

  @override
  Future<bool> createSavepoint(int txnId, String name) async {
    lastTxnId = txnId;
    lastSavepointName = name;
    return createSavepointSuccess;
  }

  @override
  Future<bool> rollbackToSavepoint(int txnId, String name) async {
    lastTxnId = txnId;
    lastSavepointName = name;
    return rollbackToSavepointSuccess;
  }

  @override
  Future<bool> releaseSavepoint(int txnId, String name) async {
    lastTxnId = txnId;
    lastSavepointName = name;
    return releaseSavepointSuccess;
  }

  @override
  void dispose() {}
}
