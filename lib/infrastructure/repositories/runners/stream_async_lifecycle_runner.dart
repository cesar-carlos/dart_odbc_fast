import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:result_dart/result_dart.dart';

/// Low-level async stream lifecycle and poll-based execute helpers.
class StreamAsyncLifecycleRunner {
  StreamAsyncLifecycleRunner({
    required this.ffi,
    required this.state,
    required this.parser,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final OdbcResultParser parser;

  Future<Result<Unit>> cancelStream(int streamId) async {
    if (streamId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid stream ID'),
      );
    }

    try {
      final cancelled = ffi.isAsync
          ? await ffi.async.streamCancel(streamId)
          : ffi.sync.streamCancel(streamId);

      if (cancelled) {
        return const Success(unit);
      }

      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to cancel stream',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        UnsupportedFeatureError(message: e.toString()),
      );
    }
  }

  Future<Result<int>> executeAsyncStart(String connectionId, String sql) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    try {
      final requestId = ffi.isAsync
          ? await ffi.async.executeAsyncStart(
              nativeId,
              sql,
            )
          : ffi.sync.executeAsyncStart(nativeId, sql);
      final resolved = requestId ?? 0;
      if (resolved > 0) {
        return Success(resolved);
      }
      return await ffi.convertNativeErrorToFailure<int>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to start async request',
      );
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<int>> asyncPoll(int requestId) async {
    if (requestId <= 0) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid async request ID'),
      );
    }

    try {
      final status = ffi.isAsync
          ? await ffi.async.asyncPoll(requestId)
          : ffi.sync.asyncPoll(requestId);
      final resolved = status ?? -1;
      return Success(resolved);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) async {
    if (requestId <= 0) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid async request ID'),
      );
    }

    try {
      final data = ffi.isAsync
          ? await ffi.async.asyncGetResult(
              requestId,
              maxBufferBytes: maxBufferBytes,
            )
          : ffi.sync.asyncGetResult(requestId);
      final parsed = parser.parseBufferToQueryResult(data);
      if (parsed == null) {
        return await ffi.convertNativeErrorToFailure<QueryResult>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Async result is unavailable',
        );
      }
      return Success(parsed);
    } on Exception catch (e) {
      return Failure<QueryResult, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> asyncCancel(int requestId) async {
    if (requestId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid async request ID'),
      );
    }

    try {
      final ok = ffi.isAsync
          ? await ffi.async.asyncCancel(requestId)
          : ffi.sync.asyncCancel(requestId);
      if (ok) {
        return const Success(unit);
      }
      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) => QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to cancel async request',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> asyncFree(int requestId) async {
    if (requestId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid async request ID'),
      );
    }

    try {
      final ok = ffi.isAsync
          ? await ffi.async.asyncFree(requestId)
          : ffi.sync.asyncFree(requestId);
      if (ok) {
        return const Success(unit);
      }
      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) => QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to free async request',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    final resultEncodingWire = state.defaultResultEncoding.wireCode;

    try {
      final streamId = ffi.isAsync
          ? await ffi.async.streamStartAsync(
              nativeId,
              sql,
              fetchSize: fetchSize,
              chunkSize: chunkSize,
              resultEncodingWire: resultEncodingWire,
            )
          : ffi.sync.streamStartAsync(
              nativeId,
              sql,
              fetchSize: fetchSize,
              chunkSize: chunkSize,
              resultEncodingWire: resultEncodingWire,
            );
      final resolved = streamId ?? 0;
      if (resolved > 0) {
        return Success(resolved);
      }
      return await ffi.convertNativeErrorToFailure<int>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to start async stream',
      );
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<int>> streamPollAsync(int streamId) async {
    if (streamId <= 0) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid stream ID'),
      );
    }

    try {
      final status = ffi.isAsync
          ? await ffi.async.streamPollAsync(
              streamId,
            )
          : ffi.sync.streamPollAsync(streamId);
      final resolved = status ?? -1;
      return Success(resolved);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }
}
