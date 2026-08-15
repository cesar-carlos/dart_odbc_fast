import 'dart:async';

import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/dart_side_metrics.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:result_dart/result_dart.dart';

/// Connection lifecycle: initialize, connect, disconnect, reconnect policy.
class OdbcConnectionRunner {
  OdbcConnectionRunner({
    required this.ffi,
    required this.state,
    required this.emit,
    required this.maybeEmitSlowQuery,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final EmitEventFn emit;
  final void Function({
    required String connectionId,
    required String? sql,
    required Stopwatch? stopwatch,
  }) maybeEmitSlowQuery;

  Future<Result<Unit>> initialize() async {
    try {
      final success =
          ffi.isAsync ? await ffi.async.initialize() : ffi.sync.initialize();

      if (success) {
        return const Success(unit);
      }
      return const Failure<Unit, OdbcError>(
        EnvironmentNotInitializedError(),
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) async {
    if (connectionString.trim().isEmpty) {
      return const Failure<Connection, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }
    final optionsValidation = options?.validate();
    if (optionsValidation != null) {
      return Failure<Connection, OdbcError>(
        ValidationError(message: optionsValidation),
      );
    }

    try {
      final timeoutMs = options?.loginTimeoutMs ?? 0;
      final connId = ffi.isAsync
          ? await ffi.async.connect(connectionString, timeoutMs: timeoutMs)
          : (timeoutMs > 0
              ? ffi.sync.connectWithTimeout(connectionString, timeoutMs)
              : ffi.sync.connect(connectionString));

      if (connId == 0) {
        return await ffi.convertNativeErrorToFailure<Connection>(
          errorFactory: odbcConnectionErrorFactory,
          fallbackMessage: 'Failed to connect to database',
        );
      }

      final connection = Connection(
        id: connId.toString(),
        connectionString: connectionString,
        createdAt: DateTime.now(),
        isActive: true,
      );

      state.connectionIds[connection.id] = connId;
      state.connectionOptions[connection.id] = options;
      state.connectionStrings[connection.id] = connectionString;

      return Success(connection);
    } on Exception catch (e) {
      return Failure<Connection, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> disconnect(String connectionId) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    if (state.connectionPoolId.containsKey(connectionId)) {
      return const Failure<Unit, OdbcError>(
        ValidationError(
          message: 'Cannot disconnect a pooled connection. '
              'Use poolReleaseConnection instead.',
        ),
      );
    }

    try {
      final success = ffi.isAsync
          ? await ffi.async.disconnect(nativeId)
          : ffi.sync.disconnect(nativeId);

      state.clearStatementMetadataForConnection(connectionId);
      state.connectionIds.remove(connectionId);
      state.connectionOptions.remove(connectionId);
      state.connectionStrings.remove(connectionId);

      if (success) {
        return const Success(unit);
      }
      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: odbcConnectionErrorFactory,
        fallbackMessage: 'Failed to disconnect from database',
        nativeConnectionId: nativeId,
      );
    } on Exception catch (e) {
      state.clearStatementMetadataForConnection(connectionId);
      state.connectionIds.remove(connectionId);
      state.connectionOptions.remove(connectionId);
      state.connectionStrings.remove(connectionId);
      return Failure<Unit, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  bool isInitialized() =>
      ffi.isAsync ? ffi.async.isInitialized : ffi.sync.isInitialized;

  void disposeNative() {
    if (ffi.isAsync) {
      ffi.async.dispose();
    } else {
      ffi.sync.dispose();
    }
  }

  void clearAllState() => state.clearAll();

  DartSideMetrics dartSideMetrics() => state.dartSideMetrics();

  void onWorkerRecovered() {
    state.clearAll();
    AppLogger.warning(
      'OdbcRepositoryImpl cleared all Dart-side state after underlying '
      'worker pool recovery; consumers must reconnect any prior connection.',
    );
    emit(WorkerRecovered(timestamp: DateTime.now().toUtc()));
  }

  Future<Result<Unit>> reconnect(
    String connectionId,
    String connectionString,
    ConnectionOptions? options,
  ) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId != null) {
      if (ffi.isAsync) {
        await ffi.async.disconnect(nativeId);
      } else {
        ffi.sync.disconnect(nativeId);
      }
      state.clearStatementMetadataForConnection(connectionId);
      state.connectionIds.remove(connectionId);
      state.connectionOptions.remove(connectionId);
      state.connectionStrings.remove(connectionId);
    }

    final timeoutMs = options?.loginTimeoutMs ?? 0;
    final connId = ffi.isAsync
        ? await ffi.async.connect(connectionString, timeoutMs: timeoutMs)
        : (timeoutMs > 0
            ? ffi.sync.connectWithTimeout(connectionString, timeoutMs)
            : ffi.sync.connect(connectionString));

    if (connId == 0) {
      return ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: odbcConnectionErrorFactory,
        fallbackMessage: 'Reconnect failed',
      );
    }

    state.connectionIds[connectionId] = connId;
    state.connectionOptions[connectionId] = options;
    state.connectionStrings[connectionId] = connectionString;
    return const Success(unit);
  }

  Future<Result<T>> withReconnect<T extends Object>(
    String connectionId,
    Future<Result<T>> Function() operation, {
    String? sqlForSlowQueryDetection,
  }) async {
    final stopwatch =
        sqlForSlowQueryDetection != null ? (Stopwatch()..start()) : null;
    var result = await operation();
    maybeEmitSlowQuery(
      connectionId: connectionId,
      sql: sqlForSlowQueryDetection,
      stopwatch: stopwatch,
    );
    if (result.isSuccess()) return result;

    final err = result.fold<OdbcError?>((_) => null, (e) => e as OdbcError);
    if (err == null || err.category != ErrorCategory.connectionLost) {
      return result;
    }

    emit(
      ConnectionLost(
        timestamp: DateTime.now().toUtc(),
        connectionId: connectionId,
        reason: err,
      ),
    );

    final opts = state.connectionOptions[connectionId];
    if (opts == null || !opts.autoReconnectOnConnectionLost) return result;

    final connectionString = state.connectionStrings[connectionId];
    if (connectionString == null || connectionString.isEmpty) return result;

    final maxAttempts = opts.effectiveMaxReconnectAttempts;
    final backoff = opts.effectiveReconnectBackoff;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) {
        await Future<void>.delayed(backoff);
      }
      emit(
        AutoReconnectAttempted(
          timestamp: DateTime.now().toUtc(),
          connectionId: connectionId,
          attempt: attempt,
          maxAttempts: maxAttempts,
        ),
      );
      final reconnected = await reconnect(connectionId, connectionString, opts);
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
}
