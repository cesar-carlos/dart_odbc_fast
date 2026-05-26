import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/dart_side_metrics.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/entities/query_result.dart'
    show
        DirectedMultiItem,
        DirectedResultItem,
        DirectedRowCountItem,
        QueryResult;
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser, ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart'
    show
        MultiResultItem,
        MultiResultItemResultSet,
        MultiResultItemRowCount,
        MultiResultParser,
        multiResultMagic;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart'
    show MultiResultStreamDecoder;
import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart'
    show NamedParameterParser, ParameterMissingException;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/native/wrappers/xa_transaction_handle.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_bulk_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_catalog_runner.dart';
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
  ///
  /// Internally the connection is wrapped in a typed [OdbcBackend] sealed
  /// hierarchy ([SyncBackend] / [AsyncBackend]) so dispatch happens via
  /// exhaustive pattern matching instead of runtime casts.
  OdbcRepositoryImpl(Object native)
      : _backend = OdbcBackend.fromNative(native) {
    // When the underlying async pool auto-recovers from a worker crash, all
    // captured native ids become invalid. Wire the callback so the repository
    // wipes its own state instead of operating against zombie ids.
    if (_backend case AsyncBackend(:final connection)) {
      connection.onWorkerRecovered = _onUnderlyingWorkerRecovered;
    }
  }

  /// Direct construction from a typed [OdbcBackend] for callers that already
  /// hold one (e.g. tests, advanced DI). Skips the runtime type-check inside
  /// [OdbcBackend.fromNative].
  OdbcRepositoryImpl.fromBackend(this._backend) {
    if (_backend case AsyncBackend(:final connection)) {
      connection.onWorkerRecovered = _onUnderlyingWorkerRecovered;
    }
  }

  void _onUnderlyingWorkerRecovered() {
    _connectionIds.clear();
    _connectionOptions.clear();
    _connectionStrings.clear();
    _connectionPoolId.clear();
    _poolCheckouts.clear();
    _clearAllStatementMetadata();
    AppLogger.warning(
      'OdbcRepositoryImpl cleared all Dart-side state after underlying '
      'worker pool recovery; consumers must reconnect any prior connection.',
    );
    _emit(WorkerRecovered(timestamp: DateTime.now().toUtc()));
  }

  /// Broadcast event bus for connection-lifecycle signals. Created lazily
  /// on first access to [events] / first emission so single-shot users
  /// of the repository pay nothing.
  StreamController<OdbcEvent>? _eventsController;

  StreamController<OdbcEvent> _ensureEventsController() {
    return _eventsController ??=
        StreamController<OdbcEvent>.broadcast(sync: true);
  }

  void _emit(OdbcEvent event) {
    final c = _eventsController;
    if (c == null || c.isClosed) return;
    c.add(event);
  }

  /// If [stopwatch] is non-null and the connection's effective
  /// slow-query threshold is configured, emits
  /// [SlowQueryDetected] when the elapsed time crosses the threshold.
  /// Best effort — never throws and never blocks the caller.
  void _maybeEmitSlowQuery({
    required String connectionId,
    required String? sql,
    required Stopwatch? stopwatch,
  }) {
    if (stopwatch == null || sql == null) return;
    stopwatch.stop();
    final threshold =
        _connectionOptions[connectionId]?.effectiveSlowQueryThreshold;
    if (threshold == null) return;
    final elapsed = stopwatch.elapsed;
    if (elapsed < threshold) return;
    _emit(
      SlowQueryDetected(
        timestamp: DateTime.now().toUtc(),
        connectionId: connectionId,
        sql: sql,
        durationMs: elapsed.inMilliseconds,
      ),
    );
  }

  @override
  Stream<OdbcEvent> get events => _ensureEventsController().stream;

  /// Typed handle to the underlying ODBC connection. Always pattern-match
  /// to dispatch sync vs async; never cast directly.
  final OdbcBackend _backend;

  /// Sync connection accessor; throws if this repository is in async mode.
  NativeOdbcConnection get _sync => switch (_backend) {
        SyncBackend(:final connection) => connection,
        AsyncBackend() => throw StateError(
            'OdbcRepositoryImpl: sync access on async backend',
          ),
      };

  /// Async connection accessor; throws if this repository is in sync mode.
  AsyncNativeOdbcConnection get _async => switch (_backend) {
        AsyncBackend(:final connection) => connection,
        SyncBackend() => throw StateError(
            'OdbcRepositoryImpl: async access on sync backend',
          ),
      };

  /// Catalog / metadata runner. Step 2 of the repository split: the six
  /// `catalog*` public methods delegate here. The runner is stateless;
  /// it reaches the repository's private state via injected closures.
  late final OdbcCatalogRunner _catalogRunner = OdbcCatalogRunner(
    backend: _backend,
    nativeIdLookup: (id) => _connectionIds[id],
    parseBuffer: _parseBufferToQueryResult,
    convertQueryError: ({
      required fallbackMessage,
      nativeConnectionId,
    }) =>
        _convertNativeErrorToFailure<QueryResult>(
      errorFactory: _queryErrorFactory,
      fallbackMessage: fallbackMessage,
      nativeConnectionId: nativeConnectionId,
    ),
  );

  /// Bulk-insert runner. Step 3 of the repository split: `bulkInsert`
  /// and `bulkInsertParallel` delegate here. Same stateless / injected-
  /// closure pattern as [_catalogRunner].
  late final OdbcBulkRunner _bulkRunner = OdbcBulkRunner(
    backend: _backend,
    nativeIdLookup: (id) => _connectionIds[id],
    convertIntError: ({
      required fallbackMessage,
      nativeConnectionId,
    }) =>
        _convertNativeErrorToFailure<int>(
      errorFactory: _queryErrorFactory,
      fallbackMessage: fallbackMessage,
      nativeConnectionId: nativeConnectionId,
    ),
  );
  final Map<String, int> _connectionIds = {};
  final Map<String, ConnectionOptions?> _connectionOptions = {};
  final Map<String, String> _connectionStrings = {};
  final Map<int, List<String>> _namedParamOrderByStmtId = {};
  final Map<int, String> _statementConnectionByStmtId = {};

  /// Maps poolId → set of connectionIds checked out from that pool.
  /// Used to clean up Dart-side state when a pool is closed.
  final Map<int, Set<String>> _poolCheckouts = {};

  /// Maps connectionId → poolId for pool-acquired connections.
  /// Enables O(1) pool membership check and prevents calling disconnect()
  /// on pooled handles.
  final Map<String, int> _connectionPoolId = {};

  /// Message used when a query times out (ConnectionOptions.queryTimeout).
  static const String _queryTimedOutMessage = 'Query timed out';
  static const String _streamProtocolErrorPrefix = 'Streaming protocol error';
  static const String _streamInterruptedPrefix = 'Streaming interrupted';
  static const String _unsupportedCancelSqlState = '0A000';
  static const int _unsupportedCancelNativeCode = 5001;

  /// Whether this repository uses async backend (non-blocking operations).
  bool get _isAsync => _backend.isAsync;

  bool _isUnsupportedCancellation({
    required String message,
    required String? sqlState,
    required int? nativeCode,
  }) {
    final normalizedSqlState = (sqlState ?? '').replaceAll('\x00', '').trim();
    if (normalizedSqlState == _unsupportedCancelSqlState ||
        nativeCode == _unsupportedCancelNativeCode) {
      return true;
    }

    // Compatibility fallback for older native binaries that only expose text.
    final lower = message.toLowerCase();
    return lower.contains('unsupported feature') &&
        lower.contains('statement cancellation');
  }

  Failure<T, OdbcError>? _validateStatementOwnership<T extends Object>({
    required String connectionId,
    required int stmtId,
    required String operationName,
  }) {
    if (!_connectionIds.containsKey(connectionId)) {
      return Failure<T, OdbcError>(
        const ValidationError(message: 'Invalid connection ID'),
      );
    }
    final ownerConnectionId = _statementConnectionByStmtId[stmtId];
    if (ownerConnectionId == null) {
      return Failure<T, OdbcError>(
        ValidationError(
          message: 'Unknown statement ID for $operationName. '
              'Prepare statement first.',
        ),
      );
    }
    if (ownerConnectionId != connectionId) {
      return Failure<T, OdbcError>(
        ValidationError(
          message: 'Statement ID $stmtId does not belong '
              'to connection ID $connectionId',
        ),
      );
    }
    return null;
  }

  void _clearStatementMetadataForConnection(String connectionId) {
    final stmtIdsToRemove = _statementConnectionByStmtId.entries
        .where((entry) => entry.value == connectionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final stmtId in stmtIdsToRemove) {
      _statementConnectionByStmtId.remove(stmtId);
      _namedParamOrderByStmtId.remove(stmtId);
    }
  }

  void _clearAllStatementMetadata() {
    _statementConnectionByStmtId.clear();
    _namedParamOrderByStmtId.clear();
  }

  /// Returns the [ConnectionOptions] for [connectionId] in a single map
  /// lookup so callers that need multiple option fields don't pay the hash
  /// cost twice.
  ConnectionOptions? _optionsFor(String connectionId) =>
      _connectionOptions[connectionId];

  /// Pre-built error factory for query-shaped failures. Use as
  /// `errorFactory: _queryErrorFactory` to avoid repeating the inline
  /// closure at every call site.
  static OdbcError _queryErrorFactory({
    required String message,
    String? sqlState,
    int? nativeCode,
  }) =>
      QueryError(message: message, sqlState: sqlState, nativeCode: nativeCode);

  /// Pre-built error factory for connection-shaped failures.
  static OdbcError _connectionErrorFactory({
    required String message,
    String? sqlState,
    int? nativeCode,
  }) =>
      ConnectionError(
        message: message,
        sqlState: sqlState,
        nativeCode: nativeCode,
      );

  /// Wraps a sync-or-async backend call returning `bool` for success.
  ///
  /// Centralises the recurring pattern:
  /// 1. Switch on [_backend] to invoke the right variant.
  /// 2. On `false`, build a typed failure via [_convertNativeErrorToFailure].
  /// 3. On thrown [Exception], wrap with the same [errorFactory].
  ///
  /// Provides ~6 lines of boilerplate elimination per call site for the
  /// commit/rollback/savepoint/release family of operations.
  Future<Result<Unit>> _runBoolFfi({
    required bool Function(NativeOdbcConnection) sync,
    required Future<bool> Function(AsyncNativeOdbcConnection) async,
    required OdbcError Function({
      required String message,
      String? sqlState,
      int? nativeCode,
    }) errorFactory,
    String? fallbackMessage,
    int? nativeConnectionId,
  }) async {
    try {
      final ok = switch (_backend) {
        SyncBackend(:final connection) => sync(connection),
        AsyncBackend(:final connection) => await async(connection),
      };
      if (ok) return const Success(unit);
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: errorFactory,
        fallbackMessage: fallbackMessage,
        nativeConnectionId: nativeConnectionId,
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(errorFactory(message: e.toString()));
    }
  }

  /// Same scaffolding as [_runBoolFfi], plus an [onSuccess] callback
  /// invoked synchronously on the success path before returning
  /// `Success(unit)`. Use for FFI bool-shaped calls that must clean up
  /// Dart-side state on success — e.g. `closeStatement` removing
  /// metadata maps, `poolReleaseConnection` clearing checkout records.
  ///
  /// The callback is **not** invoked on failure: by contract the
  /// underlying native handle is still valid (or already gone), and
  /// the Dart-side state should match what the runtime sees.
  Future<Result<Unit>> _runBoolFfiWithCleanup({
    required bool Function(NativeOdbcConnection) sync,
    required Future<bool> Function(AsyncNativeOdbcConnection) async,
    required void Function() onSuccess,
    required OdbcError Function({
      required String message,
      String? sqlState,
      int? nativeCode,
    }) errorFactory,
    String? fallbackMessage,
    int? nativeConnectionId,
  }) async {
    try {
      final ok = switch (_backend) {
        SyncBackend(:final connection) => sync(connection),
        AsyncBackend(:final connection) => await async(connection),
      };
      if (ok) {
        onSuccess();
        return const Success(unit);
      }
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: errorFactory,
        fallbackMessage: fallbackMessage,
        nativeConnectionId: nativeConnectionId,
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(errorFactory(message: e.toString()));
    }
  }

  /// Variant of [_runBoolFfi] for FFI calls that return `int` where a
  /// negative value (or zero, depending on caller) signals failure.
  /// The [isSuccess] predicate decides per-call which integers count as
  /// success; the integer itself is returned on success.
  ///
  /// Centralises the `try / call native / branch on int / convert error`
  /// pattern that several call sites previously duplicated inline.
  Future<Result<int>> _runIntFfi({
    required int Function(NativeOdbcConnection) sync,
    required Future<int> Function(AsyncNativeOdbcConnection) async,
    required bool Function(int code) isSuccess,
    required OdbcError Function({
      required String message,
      String? sqlState,
      int? nativeCode,
    }) errorFactory,
    String? fallbackMessage,
    int? nativeConnectionId,
  }) async {
    try {
      final code = switch (_backend) {
        SyncBackend(:final connection) => sync(connection),
        AsyncBackend(:final connection) => await async(connection),
      };
      if (isSuccess(code)) return Success(code);
      return await _convertNativeErrorToFailure<int>(
        errorFactory: errorFactory,
        fallbackMessage: fallbackMessage,
        nativeConnectionId: nativeConnectionId,
      );
    } on Exception catch (e) {
      return Failure<int, OdbcError>(errorFactory(message: e.toString()));
    }
  }

  Future<StructuredError?> _getStructuredNativeError({
    int? nativeConnectionId,
  }) async {
    return switch (_backend) {
      SyncBackend(:final connection) => () {
          if (nativeConnectionId != null) {
            final scoped =
                connection.getStructuredErrorForConnection(nativeConnectionId);
            if (scoped != null) return scoped;
          }
          return connection.getStructuredError();
        }(),
      AsyncBackend(:final connection) => () async {
          if (nativeConnectionId != null) {
            final scoped = await connection
                .getStructuredErrorForConnection(nativeConnectionId);
            if (scoped != null) return scoped;
          }
          return connection.getStructuredError();
        }(),
    };
  }

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
    int? nativeConnectionId,
  }) async {
    final structuredError = await _getStructuredNativeError(
      nativeConnectionId: nativeConnectionId,
    );

    if (structuredError != null) {
      return Failure<T, OdbcError>(
        errorFactory(
          message: structuredError.message,
          sqlState: structuredError.sqlStateString,
          nativeCode: structuredError.nativeCode,
        ),
      );
    }

    final errorMsg = _isAsync ? await _async.getError() : _sync.getError();

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
        await _async.disconnect(nativeId);
      } else {
        _sync.disconnect(nativeId);
      }
      _clearStatementMetadataForConnection(connectionId);
      _connectionIds.remove(connectionId);
      _connectionOptions.remove(connectionId);
      _connectionStrings.remove(connectionId);
    }

    final timeoutMs = options?.loginTimeoutMs ?? 0;
    final connId = _isAsync
        ? await _async.connect(connectionString, timeoutMs: timeoutMs)
        : (timeoutMs > 0
            ? _sync.connectWithTimeout(connectionString, timeoutMs)
            : _sync.connect(connectionString));

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
  ///
  /// When [sqlForSlowQueryDetection] is provided and the connection has
  /// an effective slow-query threshold, also emits
  /// `SlowQueryDetected` if the operation's wall-clock duration crosses
  /// the threshold (regardless of success/failure). The check is best
  /// effort and never blocks the caller.
  Future<Result<T>> _withReconnect<T extends Object>(
    String connectionId,
    Future<Result<T>> Function() operation, {
    String? sqlForSlowQueryDetection,
  }) async {
    final stopwatch = sqlForSlowQueryDetection != null
        ? (Stopwatch()..start())
        : null;
    var result = await operation();
    _maybeEmitSlowQuery(
      connectionId: connectionId,
      sql: sqlForSlowQueryDetection,
      stopwatch: stopwatch,
    );
    if (result.isSuccess()) return result;

    final err = result.fold<OdbcError?>((_) => null, (e) => e as OdbcError);
    if (err == null || err.category != ErrorCategory.connectionLost) {
      return result;
    }

    // Emit ConnectionLost as soon as we see the symptom, regardless of
    // whether auto-reconnect is wired. Consumers may want to react
    // (e.g. drop a transaction) even when no retry policy is active.
    _emit(
      ConnectionLost(
        timestamp: DateTime.now().toUtc(),
        connectionId: connectionId,
        reason: err,
      ),
    );

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
      _emit(
        AutoReconnectAttempted(
          timestamp: DateTime.now().toUtc(),
          connectionId: connectionId,
          attempt: attempt,
          maxAttempts: maxAttempts,
        ),
      );
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
      final success = _isAsync ? await _async.initialize() : _sync.initialize();

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
      final connId = _isAsync
          ? await _async.connect(connectionString, timeoutMs: timeoutMs)
          : (timeoutMs > 0
              ? _sync.connectWithTimeout(connectionString, timeoutMs)
              : _sync.connect(connectionString));

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

    if (_connectionPoolId.containsKey(connectionId)) {
      return const Failure<Unit, OdbcError>(
        ValidationError(
          message: 'Cannot disconnect a pooled connection. '
              'Use poolReleaseConnection instead.',
        ),
      );
    }

    try {
      final success = _isAsync
          ? await _async.disconnect(nativeId)
          : _sync.disconnect(nativeId);

      // On both success and native failure, drop Dart-side state. After a
      // failed disconnect the native connection may be half-dead but
      // unreachable through the Dart layer; keeping stale maps causes later
      // operations to hit confusing errors instead of failing fast.
      _clearStatementMetadataForConnection(connectionId);
      _connectionIds.remove(connectionId);
      _connectionOptions.remove(connectionId);
      _connectionStrings.remove(connectionId);

      if (success) {
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
        fallbackMessage: 'Failed to disconnect from database',
        nativeConnectionId: nativeId,
      );
    } on Exception catch (e) {
      // Same rationale: drop Dart-side state on thrown errors too so the next
      // operation sees a clean "no such connection" failure.
      _clearStatementMetadataForConnection(connectionId);
      _connectionIds.remove(connectionId);
      _connectionOptions.remove(connectionId);
      _connectionStrings.remove(connectionId);
      return Failure<Unit, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  Stream<ParsedRowBuffer> _streamNativeQueryWithFallback(
    int nativeId,
    String sql, {
    int? maxBufferBytes,
  }) async* {
    var emittedFromBatched = false;

    try {
      final batched = _isAsync
          ? _async.streamQueryBatched(
              nativeId,
              sql,
              maxBufferBytes: maxBufferBytes,
            )
          : _sync.streamQueryBatched(nativeId, sql);

      await for (final chunk in batched) {
        emittedFromBatched = true;
        yield chunk;
      }
      return;
    } on Exception {
      if (emittedFromBatched) {
        rethrow;
      }
    }

    final fallback = _isAsync
        ? _async.streamQuery(nativeId, sql, maxBufferBytes: maxBufferBytes)
        : _sync.streamQuery(nativeId, sql);

    await for (final chunk in fallback) {
      yield chunk;
    }
  }

  bool _isStreamingTimeoutException(
    Exception error,
    String normalizedMessage,
  ) {
    if (error is TimeoutException) {
      return true;
    }
    if (error is AsyncError && error.code == AsyncErrorCode.requestTimeout) {
      return true;
    }
    final lower = normalizedMessage.toLowerCase();
    return lower.contains('timeout') || lower.contains('timed out');
  }

  bool _isStreamingProtocolException(
    Exception error,
    String normalizedMessage,
  ) {
    if (error is FormatException) {
      return true;
    }
    final lower = normalizedMessage.toLowerCase();
    return lower.contains('protocol') ||
        lower.contains('leftover bytes') ||
        lower.contains('invalid magic') ||
        lower.contains('buffer too small');
  }

  bool _isStreamingInterruptionException(Exception error) {
    return error is AsyncError && error.code == AsyncErrorCode.workerTerminated;
  }

  Future<Failure<QueryResult, OdbcError>> _streamingFailureFromException(
    Exception error,
  ) async {
    final normalizedMessage = error.toString();
    if (_isStreamingTimeoutException(error, normalizedMessage)) {
      return const Failure<QueryResult, OdbcError>(
        QueryError(message: _queryTimedOutMessage),
      );
    }

    if (_isStreamingProtocolException(error, normalizedMessage)) {
      return Failure<QueryResult, OdbcError>(
        QueryError(message: '$_streamProtocolErrorPrefix: $normalizedMessage'),
      );
    }

    if (_isStreamingInterruptionException(error)) {
      return Failure<QueryResult, OdbcError>(
        QueryError(message: '$_streamInterruptedPrefix: $normalizedMessage'),
      );
    }

    final structuredError = _isAsync
        ? await _async.getStructuredError()
        : _sync.getStructuredError();
    if (structuredError != null) {
      return Failure<QueryResult, OdbcError>(
        QueryError(
          message: 'Streaming SQL error: ${structuredError.message}',
          sqlState: structuredError.sqlStateString,
          nativeCode: structuredError.nativeCode,
        ),
      );
    }

    final nativeError = _isAsync ? await _async.getError() : _sync.getError();
    final message = nativeError.isNotEmpty && nativeError != 'No error'
        ? nativeError
        : normalizedMessage;
    return Failure<QueryResult, OdbcError>(QueryError(message: message));
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

    final opts = _optionsFor(connectionId);

    Future<Result<QueryResult>> run() async {
      try {
        // Single-chunk fast path: when the entire result arrives in one chunk
        // (the common case for buffer-mode queries), reuse chunk.rows directly
        // and skip the addAll copy. Only allocate a growable accumulator when a
        // second chunk arrives.
        List<List<dynamic>>? firstRows;
        List<List<dynamic>>? multiRows;
        final columns = <String>[];

        await for (final chunk in _streamNativeQueryWithFallback(
          nativeId,
          sql,
          maxBufferBytes: opts?.maxResultBufferBytes,
        )) {
          if (columns.isEmpty && chunk.columnCount > 0) {
            columns.addAll(chunk.columnNames);
          }
          if (firstRows == null) {
            firstRows = chunk.rows;
          } else {
            (multiRows ??= List.of(firstRows)).addAll(chunk.rows);
          }
        }

        final rows = multiRows ?? firstRows ?? const <List<dynamic>>[];
        return Success(
          QueryResult(columns: columns, rows: rows, rowCount: rows.length),
        );
      } on Exception catch (e) {
        return _streamingFailureFromException(e);
      }
    }

    final queryTimeout = opts?.queryTimeout;
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

    return _withReconnect(
      connectionId,
      runWithTimeout,
      sqlForSlowQueryDetection: sql,
    );
  }

  @override
  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  ) async* {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      yield const Failure<QueryResultMultiItem, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
      return;
    }

    // The streaming multi-result FFIs were added in v3.3.0. On older native
    // libraries, or when the async worker reports streaming unavailable, we
    // degrade gracefully to executeQueryMultiFull (single batch in memory) so
    // the API contract keeps working even without M8 binaries.
    final supportsStreaming = _isAsync || _sync.supportsStreamQueryMulti;
    if (!supportsStreaming) {
      final fallback = await executeQueryMultiFull(connectionId, sql);
      if (fallback.isError()) {
        final err = fallback.exceptionOrNull();
        yield Failure<QueryResultMultiItem, OdbcError>(
          err is OdbcError ? err : QueryError(message: err.toString()),
        );
        return;
      }
      final items = fallback.getOrNull()!.items;
      for (final item in items) {
        yield Success<QueryResultMultiItem, OdbcError>(item);
      }
      return;
    }

    var streamId = 0;
    try {
      streamId = _isAsync
          ? await _async.streamMultiStartBatched(nativeId, sql)
          : _sync.streamMultiStartBatched(nativeId, sql) ?? 0;
      if (streamId == 0) {
        final fallback = await executeQueryMultiFull(connectionId, sql);
        if (fallback.isSuccess()) {
          for (final item in fallback.getOrNull()!.items) {
            yield Success<QueryResultMultiItem, OdbcError>(item);
          }
          return;
        }
        final structuredError = await _getStructuredNativeError(
          nativeConnectionId: nativeId,
        );
        final nativeErr = structuredError?.message ??
            (_isAsync ? await _async.getError() : _sync.getError());
        final fallbackErr = fallback.exceptionOrNull();
        final message = nativeErr.isNotEmpty && nativeErr != 'No error'
            ? nativeErr
            : (fallbackErr?.toString() ?? 'Streaming unavailable');
        yield Failure<QueryResultMultiItem, OdbcError>(
          QueryError(
            message: 'Failed to start streaming multi-result: $message',
            sqlState: structuredError?.sqlStateString,
            nativeCode: structuredError?.nativeCode,
          ),
        );
        return;
      }

      final decoder = MultiResultStreamDecoder();
      while (true) {
        final bool ok;
        final Uint8List? data;
        final bool hasMore;
        final String? errMsg;
        if (_isAsync) {
          final fetched = await _async.streamFetch(streamId);
          ok = fetched.success;
          data = fetched.data;
          hasMore = fetched.hasMore;
          errMsg = fetched.error;
        } else {
          final fetched = _sync.streamFetch(streamId);
          ok = fetched.success;
          data = fetched.data;
          hasMore = fetched.hasMore;
          errMsg = ok ? null : _sync.getError();
        }

        if (!ok) {
          yield Failure<QueryResultMultiItem, OdbcError>(
            QueryError(message: errMsg ?? 'Stream fetch failed'),
          );
          return;
        }
        if (data != null && data.isNotEmpty) {
          for (final item in decoder.feed(data)) {
            yield Success<QueryResultMultiItem, OdbcError>(
              _toQueryResultMultiItem(item),
            );
          }
        }
        if (!hasMore) {
          break;
        }
      }

      try {
        decoder.assertExhausted();
      } on FormatException catch (e) {
        yield Failure<QueryResultMultiItem, OdbcError>(
          MalformedPayloadError(message: e.message),
        );
        return;
      }
    } on Exception catch (e) {
      yield Failure<QueryResultMultiItem, OdbcError>(
        QueryError(message: e.toString()),
      );
    } finally {
      if (streamId != 0) {
        if (_isAsync) {
          await _async.streamClose(streamId);
        } else {
          _sync.streamClose(streamId);
        }
      }
    }
  }

  QueryResultMultiItem _toQueryResultMultiItem(MultiResultItem item) {
    final rs = item.resultSet;
    if (rs != null) {
      return QueryResultMultiItem.resultSet(_toQueryResult(rs));
    }
    return QueryResultMultiItem.rowCount(item.rowCount ?? 0);
  }

  @override
  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql,
  ) async* {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      yield const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
      return;
    }

    final opts = _optionsFor(connectionId);
    final maxBytes = opts?.maxResultBufferBytes;
    final queryTimeout = opts?.queryTimeout;

    Stream<Result<QueryResult>> createSource() async* {
      try {
        await for (final chunk in _streamNativeQueryWithFallback(
          nativeId,
          sql,
          maxBufferBytes: maxBytes,
        )) {
          yield Success(_toQueryResult(chunk));
        }
      } on Exception catch (e) {
        yield await _streamingFailureFromException(e);
      }
    }

    final source = createSource();

    if (queryTimeout != null && queryTimeout != Duration.zero) {
      await for (final item in source.timeout(
        queryTimeout,
        onTimeout: (sink) {
          sink
            ..add(
              const Failure<QueryResult, OdbcError>(
                QueryError(message: _queryTimedOutMessage),
              ),
            )
            ..close();
        },
      )) {
        yield item;
      }
      return;
    }

    await for (final item in source) {
      yield item;
    }
  }

  @override
  bool isInitialized() => _isAsync ? _async.isInitialized : _sync.isInitialized;

  @override
  void dispose() {
    if (_isAsync) {
      _async.dispose();
    } else {
      _sync.dispose();
    }
    // Clear all Dart-side state. Native handles are gone; reusing stale ids
    // through these maps after dispose would surface confusing errors instead
    // of a clean "disposed" contract.
    _connectionIds.clear();
    _connectionOptions.clear();
    _connectionStrings.clear();
    _connectionPoolId.clear();
    _poolCheckouts.clear();
    _clearAllStatementMetadata();
  }

  /// Snapshot of all Dart-side counters held by this repository.
  ///
  /// Useful for production debugging of id leaks: if `connectionCount` or
  /// `statementCount` keeps climbing across a long-running process, the
  /// caller is forgetting to disconnect / closeStatement somewhere.
  ///
  /// Cheap to call (only `Map.length` reads); safe to wire into health
  /// endpoints or telemetry exporters.
  DartSideMetrics dartSideMetrics() {
    final poolCheckoutTotal = _poolCheckouts.values.fold<int>(
      0,
      (sum, set) => sum + set.length,
    );
    return DartSideMetrics(
      connectionCount: _connectionIds.length,
      statementCount: _statementConnectionByStmtId.length,
      namedParamMetadataCount: _namedParamOrderByStmtId.length,
      pooledConnectionCount: _connectionPoolId.length,
      poolCheckoutCount: poolCheckoutTotal,
      connectionOptionsCount: _connectionOptions.length,
    );
  }

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
      // Detect the MULT envelope emitted by the DRT1 multi-result engine path.
      // When a directed OUT call returns additional result sets or row-counts
      // (from SQLMoreResults), the engine wraps everything in a MULT frame and
      // then appends the OUT1 trailer. The first item maps to the primary
      // result fields; the remaining items go to additionalResults.
      if (buf.length >= 4) {
        final firstWord =
            ByteData.sublistView(buf, 0, 4).getUint32(0, Endian.little);
        if (firstWord == multiResultMagic) {
          return _parseMultiDirectedBuffer(buf);
        }
      }
      final p = BinaryProtocolParser.parseWithOutputs(buf);
      return QueryResult(
        columns: p.rowBuffer.columnNames,
        columnsMetadata: p.rowBuffer.columns,
        rows: p.rowBuffer.rows,
        rowCount: p.rowBuffer.rowCount,
        outputParamValues: p.outputParamValues,
        refCursorResults: p.refCursorRowBuffers
            .map(
              (b) => QueryResult(
                columns: b.columnNames,
                columnsMetadata: b.columns,
                rows: b.rows,
                rowCount: b.rowCount,
              ),
            )
            .toList(growable: false),
      );
    } on FormatException catch (e, st) {
      // Surface the underlying parse failure to logs so production corruption
      // is debuggable. We still return null to preserve the existing
      // contract: callers map this to a generic QueryError via
      // _convertNativeErrorToFailure with the actual native error message.
      AppLogger.warning(
        'BinaryProtocolParser failed (buf len=${buf.length}): ${e.message}',
        e,
        st,
      );
      return null;
    }
  }

  /// Decodes a directed OUT buffer that begins with a MULT envelope, mapping
  /// the first item to the primary [QueryResult] fields and the remaining
  /// items to [QueryResult.additionalResults].
  QueryResult _parseMultiDirectedBuffer(Uint8List buf) {
    final parsed = MultiResultParser.parseMultiWithOutputs(buf);
    final items = parsed.items;
    final outputParamValues = parsed.outputParamValues;

    // Determine if the first logical item is a ResultSet or a RowCount.
    // When the initial execute returned no cursor (DML-first procedures) Rust
    // now emits RowCount as item[0].  In that case the primary QueryResult has
    // no columns/rows, and ALL items are surfaced in additionalResults so no
    // information is lost.  When item[0] is a ResultSet, the existing behaviour
    // is preserved: columns/rows come from the first item and the tail goes to
    // additionalResults.
    final firstIsResultSet =
        items.isNotEmpty && items[0] is MultiResultItemResultSet;

    var columns = const <String>[];
    var rows = const <List<dynamic>>[];
    var rowCount = 0;
    int startTailAt;

    if (firstIsResultSet) {
      final rb = (items[0] as MultiResultItemResultSet).value;
      columns = rb.columnNames;
      rows = rb.rows;
      rowCount = rb.rowCount;
      startTailAt = 1;
    } else {
      // RowCount-first: keep primary fields empty and expose everything in
      // additionalResults (including item[0]) so callers can inspect it.
      startTailAt = 0;
    }

    final additional = <DirectedMultiItem>[];
    for (var i = startTailAt; i < items.length; i++) {
      final item = items[i];
      if (item is MultiResultItemResultSet) {
        final rb = item.value;
        additional.add(
          DirectedResultItem(
            columns: rb.columnNames,
            rows: rb.rows,
            rowCount: rb.rowCount,
          ),
        );
      } else if (item is MultiResultItemRowCount) {
        additional.add(DirectedRowCountItem(item.value));
      }
    }

    return QueryResult(
      columns: columns,
      rows: rows,
      rowCount: rowCount,
      outputParamValues: outputParamValues,
      additionalResults: additional,
    );
  }

  QueryResult _toQueryResult(ParsedRowBuffer buffer) {
    return QueryResult(
      columns: buffer.columnNames,
      rows: buffer.rows,
      rowCount: buffer.rowCount,
    );
  }

  QueryResultMulti _toQueryResultMulti(List<MultiResultItem> items) {
    final mapped = List<QueryResultMultiItem>.generate(
      items.length,
      (i) {
        final item = items[i];
        final resultSet = item.resultSet;
        return resultSet != null
            ? QueryResultMultiItem.resultSet(_toQueryResult(resultSet))
            : QueryResultMultiItem.rowCount(item.rowCount ?? 0);
      },
      growable: false,
    );
    return QueryResultMulti(items: mapped);
  }

  List<ParamValue> _toParamValues(List<dynamic> params) =>
      paramValuesFromObjects(params);

  Map<String, Object?>? _decodeJsonMap(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    return decoded.map<String, Object?>(
      MapEntry<String, Object?>.new,
    );
  }

  List<Map<String, Object?>>? _decodeJsonMapList(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! List<dynamic>) {
      return null;
    }
    final items = <Map<String, Object?>>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) {
        return null;
      }
      items.add(
        item.map<String, Object?>(
          MapEntry<String, Object?>.new,
        ),
      );
    }
    return items;
  }

  @override
  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel, {
    SavepointDialect savepointDialect = SavepointDialect.auto,
    TransactionAccessMode accessMode = TransactionAccessMode.readWrite,
    Duration? lockTimeout,
  }) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    // Convert Duration → ms at the FFI boundary. `null` means engine
    // default (wire `0`). Sub-millisecond positive durations round up
    // to 1ms so the caller's intent ("wait a tiny bit") is preserved
    // — same policy as `LockTimeout::from_duration` on the Rust side.
    final lockTimeoutMs = lockTimeout == null
        ? 0
        : (lockTimeout.inMilliseconds == 0 && lockTimeout > Duration.zero
            ? 1
            : lockTimeout.inMilliseconds.clamp(0, 0xFFFFFFFF));
    try {
      final txnId = _isAsync
          ? await _async.beginTransaction(
              nativeId,
              isolationLevel.value,
              savepointDialect: savepointDialect.code,
              accessMode: accessMode.code,
              lockTimeoutMs: lockTimeoutMs,
            )
          : _sync.beginTransaction(
              nativeId,
              isolationLevel.value,
              savepointDialect: savepointDialect.code,
              accessMode: accessMode.code,
              lockTimeoutMs: lockTimeoutMs,
            );

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
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    if (txnId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid transaction ID'),
      );
    }
    return _runBoolFfi(
      sync: (n) => n.commitTransaction(txnId),
      async: (a) => a.commitTransaction(txnId),
      errorFactory: _queryErrorFactory,
      fallbackMessage: 'Failed to commit transaction',
      nativeConnectionId: nativeId,
    );
  }

  @override
  Future<Result<Unit>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    if (txnId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid transaction ID'),
      );
    }
    return _runBoolFfi(
      sync: (n) => n.rollbackTransaction(txnId),
      async: (a) => a.rollbackTransaction(txnId),
      errorFactory: _queryErrorFactory,
      fallbackMessage: 'Failed to rollback transaction',
      nativeConnectionId: nativeId,
    );
  }

  @override
  Future<Result<XaTransactionHandle>> xaStart(
    String connectionId,
    Xid xid,
  ) async {
    try {
      if (!_connectionIds.containsKey(connectionId)) {
        return const Failure<XaTransactionHandle, OdbcError>(
          ValidationError(message: 'Invalid connection ID'),
        );
      }
      if (_isAsync) {
        return const Failure<XaTransactionHandle, OdbcError>(
          ValidationError(
            message:
                'XA / 2PC is not supported on the async ODBC repository backend',
          ),
        );
      }
      final native = _sync;
      if (!native.supportsXa) {
        return const Failure<XaTransactionHandle, OdbcError>(
          ValidationError(
            message: 'The loaded native library does not export the XA FFI '
                'entry points',
          ),
        );
      }
      final cid = _connectionIds[connectionId]!;
      final h = native.xaStart(cid, xid);
      if (h == null) {
        final structured = native.getStructuredErrorForConnection(cid);
        if (structured != null) {
          return Failure<XaTransactionHandle, OdbcError>(
            QueryError(
              message: structured.message,
              sqlState: structured.sqlStateString,
              nativeCode: structured.nativeCode,
            ),
          );
        }
        final msg = native.getError();
        return Failure<XaTransactionHandle, OdbcError>(
          QueryError(
            message: msg.isNotEmpty ? msg : 'xa_start failed (null handle)',
          ),
        );
      }
      return Success(h);
    } on Exception catch (e) {
      return Failure<XaTransactionHandle, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    if (txnId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid transaction ID'),
      );
    }
    if (name.trim().isEmpty) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Savepoint name cannot be empty'),
      );
    }
    return _runBoolFfi(
      sync: (n) => n.createSavepoint(txnId, name),
      async: (a) => a.createSavepoint(txnId, name),
      errorFactory: _queryErrorFactory,
      fallbackMessage: 'Failed to create savepoint',
      nativeConnectionId: nativeId,
    );
  }

  @override
  Future<Result<Unit>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    if (txnId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid transaction ID'),
      );
    }
    if (name.trim().isEmpty) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Savepoint name cannot be empty'),
      );
    }
    return _runBoolFfi(
      sync: (n) => n.rollbackToSavepoint(txnId, name),
      async: (a) => a.rollbackToSavepoint(txnId, name),
      errorFactory: _queryErrorFactory,
      fallbackMessage: 'Failed to rollback to savepoint',
      nativeConnectionId: nativeId,
    );
  }

  @override
  Future<Result<Unit>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    if (txnId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid transaction ID'),
      );
    }
    if (name.trim().isEmpty) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Savepoint name cannot be empty'),
      );
    }
    return _runBoolFfi(
      sync: (n) => n.releaseSavepoint(txnId, name),
      async: (a) => a.releaseSavepoint(txnId, name),
      errorFactory: _queryErrorFactory,
      fallbackMessage: 'Failed to release savepoint',
      nativeConnectionId: nativeId,
    );
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
          ? await _async.prepare(nativeId, sql, timeoutMs: timeoutMs)
          : _sync.prepare(nativeId, sql, timeoutMs: timeoutMs);

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
      // TOCTOU guard: while prepare was running, a concurrent disconnect()
      // may have removed connectionId from _connectionIds. If so, the native
      // statement is now orphaned (the worker still has it). Close it
      // proactively to prevent a native handle leak and surface the race.
      if (!_connectionIds.containsKey(connectionId)) {
        try {
          if (_isAsync) {
            await _async.closeStatement(stmtId);
          } else {
            _sync.closeStatement(stmtId);
          }
        } on Exception {
          // Best effort: native handle is unreachable anyway after disconnect.
        }
        return const Failure<int, OdbcError>(
          ValidationError(
            message: 'Connection was closed during prepare; statement freed',
          ),
        );
      }
      _statementConnectionByStmtId[stmtId] = connectionId;
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
      // Use pattern-match instead of getOrElse((_) => 0): the latter conflates
      // a real stmtId of 0 (impossible today) with failure, and would silently
      // mis-register named-param metadata if the contract changed.
      prepared.fold(
        (stmtId) => _namedParamOrderByStmtId[stmtId] = extract.paramNames,
        (_) {},
      );
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
    final ownership = _validateStatementOwnership<QueryResult>(
      connectionId: connectionId,
      stmtId: stmtId,
      operationName: 'executePrepared',
    );
    if (ownership != null) return ownership;

    try {
      final list = params ?? [];
      final pv = list.isEmpty ? null : _toParamValues(list);
      final timeoutMs = options?.timeout?.inMilliseconds ?? 0;
      final fetchSizeVal = options?.fetchSize ?? 1000;
      final maxBuf = options?.maxBufferSize;
      final buf = _isAsync
          ? await _async.executePrepared(
              stmtId,
              pv,
              timeoutMs,
              fetchSizeVal,
              maxBufferBytes: maxBuf,
            )
          : _sync.executePrepared(
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
    final ownership = _validateStatementOwnership<Unit>(
      connectionId: connectionId,
      stmtId: stmtId,
      operationName: 'closeStatement',
    );
    if (ownership != null) return ownership;

    // Dart-side metadata is dropped unconditionally — even on a failed
    // close the native handle is past usable. Mirrors the original
    // `finally` block before the helper migration.
    void clearMetadata() {
      _namedParamOrderByStmtId.remove(stmtId);
      _statementConnectionByStmtId.remove(stmtId);
    }

    try {
      return await _runBoolFfiWithCleanup(
        sync: (n) => n.closeStatement(stmtId),
        async: (a) => a.closeStatement(stmtId),
        onSuccess: clearMetadata,
        errorFactory: _queryErrorFactory,
        fallbackMessage: 'Failed to close statement',
      );
    } finally {
      clearMetadata();
    }
  }

  @override
  Future<Result<Unit>> cancelStatement(String connectionId, int stmtId) async {
    final ownership = _validateStatementOwnership<Unit>(
      connectionId: connectionId,
      stmtId: stmtId,
      operationName: 'cancelStatement',
    );
    if (ownership != null) return ownership;

    try {
      final ok = _isAsync
          ? await _async.cancelStatement(stmtId)
          : _sync.cancelStatement(stmtId);
      if (ok) return const Success(unit);

      final structuredError = _isAsync
          ? await _async.getStructuredError()
          : _sync.getStructuredError();
      final errorMsg = _isAsync ? await _async.getError() : _sync.getError();
      final message = (errorMsg.isNotEmpty && errorMsg != 'No error')
          ? errorMsg
          : (structuredError?.message.isNotEmpty ?? false)
              ? structuredError!.message
              : 'Failed to cancel statement';
      final sqlState = structuredError?.sqlStateString;
      final nativeCode = structuredError?.nativeCode;

      if (_isUnsupportedCancellation(
        message: message,
        sqlState: sqlState,
        nativeCode: nativeCode,
      )) {
        return Failure<Unit, OdbcError>(
          UnsupportedFeatureError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
        );
      }

      if (message.contains('Invalid statement ID')) {
        return Failure<Unit, OdbcError>(
          ValidationError(message: message),
        );
      }

      return Failure<Unit, OdbcError>(
        QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(QueryError(message: e.toString()));
    }
  }

  @override
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    final opts = _optionsFor(connectionId);

    Future<Result<QueryResult>> run() async {
      try {
        final pv = _toParamValues(params);
        final maxBytes = opts?.maxResultBufferBytes;
        final queryTimeout = opts?.queryTimeout;
        final buf = _isAsync
            ? await _async.executeQueryParams(
                nativeId,
                sql,
                pv,
                maxBufferBytes: maxBytes,
                timeout: queryTimeout,
                resultEncoding: resultEncoding,
              )
            : _sync.executeQueryParams(
                nativeId,
                sql,
                pv,
                maxBufferBytes: maxBytes,
                resultEncoding: resultEncoding,
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

    final queryTimeout = _optionsFor(connectionId)?.queryTimeout;
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

    return _withReconnect(
      connectionId,
      runWithTimeout,
      sqlForSlowQueryDetection: sql,
    );
  }

  @override
  Future<Result<QueryResult>> executeQueryParamBuffer(
    String connectionId,
    String sql,
    Uint8List? paramBuffer, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    final opts = _optionsFor(connectionId);

    Future<Result<QueryResult>> run() async {
      try {
        final maxBytes = opts?.maxResultBufferBytes;
        final queryTimeout = opts?.queryTimeout;
        final buf = _isAsync
            ? await _async.executeQueryParamBuffer(
                nativeId,
                sql,
                paramBuffer,
                maxBufferBytes: maxBytes,
                timeout: queryTimeout,
                resultEncoding: resultEncoding,
              )
            : _sync.executeQueryParamsRaw(
                nativeId,
                sql,
                paramBuffer,
                maxBufferBytes: maxBytes,
                resultEncoding: resultEncoding,
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

    final queryTimeout = _optionsFor(connectionId)?.queryTimeout;
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

    return _withReconnect(
      connectionId,
      runWithTimeout,
      sqlForSlowQueryDetection: sql,
    );
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
  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) async* {
    // The parameterized execute path does not support incremental batched
    // streaming at the FFI level. The full result is buffered and yielded as
    // a single chunk — consistent with the non-streaming execute contract but
    // wrapped in a Stream for API uniformity.
    yield await executeQueryNamed(connectionId, sql, namedParams);
  }

  @override
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) async {
    final full = await executeQueryMultiFull(connectionId, sql);
    return full.fold(
      (success) => Success(
        success.firstResultSetOrNull ??
            const QueryResult(columns: [], rows: [], rowCount: 0),
      ),
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

    final maxBytes = _optionsFor(connectionId)?.maxResultBufferBytes;

    Future<Result<QueryResultMulti>> run() async {
      try {
        final buf = _isAsync
            ? await _async.executeQueryMulti(
                nativeId,
                sql,
                maxBufferBytes: maxBytes,
              )
            : _sync.executeQueryMulti(nativeId, sql, maxBufferBytes: maxBytes);

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
          nativeConnectionId: nativeId,
        );
      }
    }

    final queryTimeout = _optionsFor(connectionId)?.queryTimeout;
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

    return _withReconnect(
      connectionId,
      runWithTimeout,
      sqlForSlowQueryDetection: sql,
    );
  }

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResultMulti, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    final opts = _optionsFor(connectionId);

    Future<Result<QueryResultMulti>> run() async {
      try {
        final paramValues = _toParamValues(params);
        final paramsBuffer =
            paramValues.isEmpty ? null : serializeParams(paramValues);
        final buf = _isAsync
            ? await _async.executeQueryMultiParams(
                nativeId,
                sql,
                paramsBuffer,
                maxBufferBytes: opts?.maxResultBufferBytes,
              )
            : _sync.executeQueryMultiParams(
                nativeId,
                sql,
                paramsBuffer,
                maxBufferBytes: opts?.maxResultBufferBytes,
              );

        if (buf == null || buf.isEmpty) {
          return const Success(QueryResultMulti(items: []));
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
          nativeConnectionId: nativeId,
        );
      }
    }

    final queryTimeout = opts?.queryTimeout;
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

    return _withReconnect(
      connectionId,
      runWithTimeout,
      sqlForSlowQueryDetection: sql,
    );
  }

  @override
  Future<Result<QueryResult>> catalogTables(
    String connectionId, {
    String catalog = '',
    String schema = '',
  }) =>
      _catalogRunner.catalogTables(
        connectionId,
        catalog: catalog,
        schema: schema,
      );

  @override
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) =>
      _catalogRunner.catalogColumns(connectionId, table);

  @override
  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) =>
      _catalogRunner.catalogTypeInfo(connectionId);

  @override
  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) =>
      _catalogRunner.catalogPrimaryKeys(connectionId, table);

  @override
  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) =>
      _catalogRunner.catalogForeignKeys(connectionId, table);

  @override
  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) =>
      _catalogRunner.catalogIndexes(connectionId, table);

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) async {
    if (connectionString.trim().isEmpty) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }
    if (maxSize <= 0) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Pool maxSize must be greater than zero'),
      );
    }
    if (!_isAsync && !_sync.isInitialized) {
      final r = await initialize();
      final err = r.exceptionOrNull();
      if (err != null) {
        return Failure<int, OdbcError>(
          err is OdbcError ? err : const EnvironmentNotInitializedError(),
        );
      }
    }
    return _runIntFfi(
      sync: (n) => n.poolCreate(connectionString, maxSize, options: options),
      async: (a) =>
          a.poolCreate(connectionString, maxSize, options: options),
      isSuccess: (id) => id != 0,
      errorFactory: _connectionErrorFactory,
      fallbackMessage: 'Failed to create pool',
    );
  }

  @override
  Future<Result<Unit>> poolSetSize(int poolId, int newMaxSize) async {
    if (poolId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid pool ID'),
      );
    }
    if (newMaxSize <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Pool maxSize must be greater than zero'),
      );
    }
    // Capture old size for the PoolResize event below; failure to read
    // it should not block the resize itself.
    final priorState = _isAsync
        ? await _async.poolGetState(poolId)
        : _sync.poolGetState(poolId);
    final result = await _runBoolFfi(
      sync: (n) => n.poolSetSize(poolId, newMaxSize),
      async: (a) => a.poolSetSize(poolId, newMaxSize),
      errorFactory: _connectionErrorFactory,
      fallbackMessage: 'Failed to resize pool',
    );
    if (result.isSuccess() && priorState != null) {
      _emit(
        PoolResize(
          timestamp: DateTime.now().toUtc(),
          poolId: poolId,
          oldSize: priorState.size,
          newSize: newMaxSize,
        ),
      );
    }
    return result;
  }

  @override
  Future<Result<Connection>> poolGetConnection(int poolId) async {
    if (poolId <= 0) {
      return const Failure<Connection, OdbcError>(
        ValidationError(message: 'Invalid pool ID'),
      );
    }
    try {
      final connId = _isAsync
          ? await _async.poolGetConnection(poolId)
          : _sync.poolGetConnection(poolId);

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
      _connectionStrings[c.id] = 'pool://$poolId';
      _connectionPoolId[c.id] = poolId;
      _poolCheckouts.putIfAbsent(poolId, () => <String>{}).add(c.id);
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
    return _runBoolFfiWithCleanup(
      sync: (n) => n.poolReleaseConnection(nativeId),
      async: (a) => a.poolReleaseConnection(nativeId),
      onSuccess: () {
        _clearStatementMetadataForConnection(connectionId);
        _connectionIds.remove(connectionId);
        _connectionStrings.remove(connectionId);
        final pid = _connectionPoolId.remove(connectionId);
        if (pid != null) {
          _poolCheckouts[pid]?.remove(connectionId);
        }
      },
      errorFactory: _connectionErrorFactory,
      fallbackMessage: 'Failed to release connection to pool',
    );
  }

  @override
  Future<Result<bool>> poolHealthCheck(int poolId) async {
    if (poolId <= 0) {
      return const Failure<bool, OdbcError>(
        ValidationError(message: 'Invalid pool ID'),
      );
    }
    try {
      final result = _isAsync
          ? await _async.poolHealthCheck(poolId)
          : _sync.poolHealthCheck(poolId);

      if (result) return const Success(true);
      return await _convertNativeErrorToFailure<bool>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            ConnectionError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Pool health check failed or pool does not exist',
      );
    } on Exception catch (e) {
      return Failure<bool, OdbcError>(
        ConnectionError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<PoolState>> poolGetState(int poolId) async {
    if (poolId <= 0) {
      return const Failure<PoolState, OdbcError>(
        ValidationError(message: 'Invalid pool ID'),
      );
    }
    try {
      final s = _isAsync
          ? await _async.poolGetState(poolId)
          : _sync.poolGetState(poolId);

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
    if (poolId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid pool ID'),
      );
    }
    return _runBoolFfiWithCleanup(
      sync: (n) => n.poolClose(poolId),
      async: (a) => a.poolClose(poolId),
      onSuccess: () {
        final checkouts = _poolCheckouts.remove(poolId) ?? const <String>{};
        for (final cId in checkouts) {
          _clearStatementMetadataForConnection(cId);
          _connectionIds.remove(cId);
          _connectionStrings.remove(cId);
          _connectionOptions.remove(cId);
          _connectionPoolId.remove(cId);
        }
      },
      errorFactory: _connectionErrorFactory,
      fallbackMessage: 'Failed to close pool',
    );
  }

  @override
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) =>
      _bulkRunner.bulkInsert(
        connectionId,
        table,
        columns,
        dataBuffer,
        rowCount,
      );

  @override
  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  }) =>
      _bulkRunner.bulkInsertParallel(
        poolId,
        table,
        columns,
        dataBuffer,
        rowCount,
        parallelism: parallelism,
      );

  @override
  Future<Result<OdbcMetrics>> getMetrics() async {
    try {
      if (_isAsync) {
        final m = await _async.getMetrics();
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
        final m = _sync.getMetrics();
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
  @Deprecated(
    'Use getWorkerPoolStats() — returns null in sync mode. '
    'Will be removed in a future major release.',
  )
  Future<Result<AsyncWorkerPoolStats>> getAsyncWorkerPoolStats() async {
    if (!_isAsync) {
      return const Failure(
        UnsupportedFeatureError(
          message: 'Async worker-pool stats require async native backend',
        ),
      );
    }

    return Success(
      _async.getWorkerPoolStats(),
    );
  }

  @override
  Future<AsyncWorkerPoolStats?> getWorkerPoolStats() async {
    return switch (_backend) {
      SyncBackend() => null,
      AsyncBackend(:final connection) => connection.getWorkerPoolStats(),
    };
  }

  @override
  Future<Result<Unit>> clearStatementCache() async {
    try {
      final cleared = _isAsync
          ? await _async.clearStatementCache()
          : _sync.clearStatementCache();

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
  Future<Result<Unit>> clearAllStatements() async {
    final r = await _runIntFfi(
      sync: (n) => n.clearAllStatements(),
      async: (a) => a.clearAllStatements(),
      isSuccess: (code) => code == 0,
      errorFactory: _queryErrorFactory,
      fallbackMessage: 'Failed to clear all statements',
    );
    return r.fold(
      (_) {
        _clearAllStatementMetadata();
        return const Success<Unit, OdbcError>(unit);
      },
      (e) => Failure<Unit, OdbcError>(e as OdbcError),
    );
  }

  @override
  Future<Result<PreparedStatementMetrics>>
      getPreparedStatementsMetrics() async {
    try {
      final metrics =
          _isAsync ? await _async.getCacheMetrics() : _sync.getCacheMetrics();

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
  Future<Result<Map<String, String>>> getVersion() async {
    try {
      final version = _isAsync ? await _async.getVersion() : _sync.getVersion();
      if (version == null ||
          (version['api'] ?? '').isEmpty && (version['abi'] ?? '').isEmpty) {
        return await _convertNativeErrorToFailure<Map<String, String>>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to get native engine version',
        );
      }
      return Success(version);
    } on Exception catch (e) {
      return Failure<Map<String, String>, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> validateConnectionString(String connectionString) async {
    if (connectionString.trim().isEmpty) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }
    try {
      final validationError = _isAsync
          ? await _async.validateConnectionString(connectionString)
          : _sync.validateConnectionString(connectionString);
      if (validationError == null || validationError.trim().isEmpty) {
        return const Success(unit);
      }
      return Failure<Unit, OdbcError>(
        ValidationError(message: validationError),
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        ValidationError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) async {
    if (connectionString.trim().isEmpty) {
      return const Failure<Map<String, Object?>, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }
    try {
      final payload = _isAsync
          ? await _async.getDriverCapabilitiesJson(connectionString)
          : _sync.getDriverCapabilitiesJson(connectionString);

      if (payload == null || payload.isEmpty) {
        return await _convertNativeErrorToFailure<Map<String, Object?>>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              UnsupportedFeatureError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Driver capabilities API is unavailable',
        );
      }

      final decoded = _decodeJsonMap(payload);
      if (decoded == null) {
        return const Failure<Map<String, Object?>, OdbcError>(
          QueryError(message: 'Invalid driver capabilities payload format'),
        );
      }
      return Success(decoded);
    } on FormatException catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: 'Invalid driver capabilities JSON: ${e.message}'),
      );
    } on Exception catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<DbmsInfo, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    try {
      final payload = _isAsync
          ? await _async.getConnectionDbmsInfoJson(nativeId)
          : _sync.getConnectionDbmsInfoJson(nativeId);

      if (payload == null || payload.isEmpty) {
        return await _convertNativeErrorToFailure<DbmsInfo>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              UnsupportedFeatureError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Connection DBMS info API is unavailable',
        );
      }

      final decoded = _decodeJsonMap(payload);
      if (decoded == null) {
        return const Failure<DbmsInfo, OdbcError>(
          QueryError(message: 'Invalid connection DBMS info payload format'),
        );
      }
      return Success(DbmsInfo.fromJson(decoded));
    } on FormatException catch (e) {
      return Failure<DbmsInfo, OdbcError>(
        QueryError(message: 'Invalid connection DBMS info JSON: ${e.message}'),
      );
    } on Exception catch (e) {
      return Failure<DbmsInfo, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> setLogLevel(int level) async {
    if (level < 0 || level > 5) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Log level must be between 0 and 5'),
      );
    }
    try {
      if (_isAsync) {
        await _async.setLogLevel(level);
      } else {
        _sync.setLogLevel(level);
      }
      return const Success(unit);
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> setAuditEnabled({required bool enabled}) async {
    try {
      final ok = _isAsync
          ? await _async.setAuditEnabled(
              enabled: enabled,
            )
          : _sync.setAuditEnabled(enabled: enabled);
      if (ok) {
        return const Success(unit);
      }
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to update audit state',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        UnsupportedFeatureError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Map<String, Object?>>> getAuditStatus() async {
    try {
      final payload = _isAsync
          ? await _async.getAuditStatusJson()
          : _sync.getAuditStatusJson();
      if (payload == null || payload.isEmpty) {
        return await _convertNativeErrorToFailure<Map<String, Object?>>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              UnsupportedFeatureError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to read audit status',
        );
      }
      final decoded = _decodeJsonMap(payload);
      if (decoded == null) {
        return const Failure<Map<String, Object?>, OdbcError>(
          QueryError(message: 'Invalid audit status payload format'),
        );
      }
      return Success(decoded);
    } on FormatException catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: 'Invalid audit status JSON: ${e.message}'),
      );
    } on Exception catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<List<Map<String, Object?>>>> getAuditEvents({
    int limit = 0,
  }) async {
    try {
      final payload = _isAsync
          ? await _async.getAuditEventsJson(
              limit: limit,
            )
          : _sync.getAuditEventsJson(limit: limit);
      if (payload == null || payload.isEmpty) {
        return await _convertNativeErrorToFailure<List<Map<String, Object?>>>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              UnsupportedFeatureError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to read audit events',
        );
      }
      final decoded = _decodeJsonMapList(payload);
      if (decoded == null) {
        return const Failure<List<Map<String, Object?>>, OdbcError>(
          QueryError(message: 'Invalid audit events payload format'),
        );
      }
      return Success(decoded);
    } on FormatException catch (e) {
      return Failure<List<Map<String, Object?>>, OdbcError>(
        QueryError(message: 'Invalid audit events JSON: ${e.message}'),
      );
    } on Exception catch (e) {
      return Failure<List<Map<String, Object?>>, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> clearAuditEvents() async {
    try {
      final ok =
          _isAsync ? await _async.clearAuditEvents() : _sync.clearAuditEvents();
      if (ok) {
        return const Success(unit);
      }
      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to clear audit events',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        UnsupportedFeatureError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) async {
    try {
      Map<String, Object?>? decoded;
      if (_isAsync) {
        final payload = await _async.poolGetStateJson(poolId);
        if (payload == null || payload.isEmpty) {
          return await _convertNativeErrorToFailure<Map<String, Object?>>(
            errorFactory: ({required message, sqlState, nativeCode}) =>
                QueryError(
              message: message,
              sqlState: sqlState,
              nativeCode: nativeCode,
            ),
            fallbackMessage: 'Failed to get detailed pool state',
          );
        }
        decoded = _decodeJsonMap(payload);
      } else {
        final payload = _sync.poolGetStateJson(poolId);
        if (payload == null || payload.isEmpty) {
          return await _convertNativeErrorToFailure<Map<String, Object?>>(
            errorFactory: ({required message, sqlState, nativeCode}) =>
                QueryError(
              message: message,
              sqlState: sqlState,
              nativeCode: nativeCode,
            ),
            fallbackMessage: 'Failed to get detailed pool state',
          );
        }
        decoded = payload.map<String, Object?>(
          MapEntry<String, Object?>.new,
        );
      }
      if (decoded == null) {
        return const Failure<Map<String, Object?>, OdbcError>(
          QueryError(message: 'Invalid detailed pool state payload format'),
        );
      }
      return Success(decoded);
    } on FormatException catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: 'Invalid detailed pool state JSON: ${e.message}'),
      );
    } on Exception catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) async {
    if (maxEntries <= 0 || ttlSeconds <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(
          message: 'maxEntries and ttlSeconds must be greater than zero',
        ),
      );
    }

    if (!_isAsync && !_sync.supportsMetadataCacheApi) {
      return const Failure<Unit, OdbcError>(
        UnsupportedFeatureError(
          message: 'Metadata cache API is not available in native runtime',
        ),
      );
    }

    try {
      final enabled = _isAsync
          ? await _async.metadataCacheEnable(
              maxEntries: maxEntries,
              ttlSeconds: ttlSeconds,
            )
          : _sync.metadataCacheEnable(
              maxEntries: maxEntries,
              ttlSeconds: ttlSeconds,
            );

      if (enabled) {
        return const Success(unit);
      }

      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to enable metadata cache',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        UnsupportedFeatureError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Map<String, Object?>>> metadataCacheStats() async {
    if (!_isAsync && !_sync.supportsMetadataCacheApi) {
      return const Failure<Map<String, Object?>, OdbcError>(
        UnsupportedFeatureError(
          message: 'Metadata cache API is not available in native runtime',
        ),
      );
    }

    try {
      final payload = _isAsync
          ? await _async.getMetadataCacheStatsJson()
          : _sync.getMetadataCacheStatsJson();

      if (payload == null || payload.isEmpty) {
        return await _convertNativeErrorToFailure<Map<String, Object?>>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              UnsupportedFeatureError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to read metadata cache stats',
        );
      }

      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return const Failure<Map<String, Object?>, OdbcError>(
          QueryError(message: 'Invalid metadata cache stats payload format'),
        );
      }

      return Success(
        decoded.map<String, Object?>(
          MapEntry<String, Object?>.new,
        ),
      );
    } on FormatException catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: 'Invalid metadata cache stats JSON: ${e.message}'),
      );
    } on Exception catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> clearMetadataCache() async {
    if (!_isAsync && !_sync.supportsMetadataCacheApi) {
      return const Failure<Unit, OdbcError>(
        UnsupportedFeatureError(
          message: 'Metadata cache API is not available in native runtime',
        ),
      );
    }

    try {
      final cleared = _isAsync
          ? await _async.clearMetadataCache()
          : _sync.clearMetadataCache();

      if (cleared) {
        return const Success(unit);
      }

      return await _convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to clear metadata cache',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        UnsupportedFeatureError(message: e.toString()),
      );
    }
  }

  @override
  Future<Result<Unit>> cancelStream(int streamId) async {
    if (streamId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid stream ID'),
      );
    }

    try {
      final cancelled = _isAsync
          ? await _async.streamCancel(streamId)
          : _sync.streamCancel(streamId);

      if (cancelled) {
        return const Success(unit);
      }

      return await _convertNativeErrorToFailure<Unit>(
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

  @override
  Future<Result<int>> executeAsyncStart(String connectionId, String sql) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    try {
      final requestId = _isAsync
          ? await _async.executeAsyncStart(
              nativeId,
              sql,
            )
          : _sync.executeAsyncStart(nativeId, sql);
      final resolved = requestId ?? 0;
      if (resolved > 0) {
        return Success(resolved);
      }
      return await _convertNativeErrorToFailure<int>(
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

  @override
  Future<Result<int>> asyncPoll(int requestId) async {
    if (requestId <= 0) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid async request ID'),
      );
    }

    try {
      final status = _isAsync
          ? await _async.asyncPoll(requestId)
          : _sync.asyncPoll(requestId);
      final resolved = status ?? -1;
      return Success(resolved);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  @override
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
      final data = _isAsync
          ? await _async.asyncGetResult(
              requestId,
              maxBufferBytes: maxBufferBytes,
            )
          : _sync.asyncGetResult(requestId);
      final parsed = _parseBufferToQueryResult(data);
      if (parsed == null) {
        return await _convertNativeErrorToFailure<QueryResult>(
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

  @override
  Future<Result<Unit>> asyncCancel(int requestId) async {
    if (requestId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid async request ID'),
      );
    }

    try {
      final ok = _isAsync
          ? await _async.asyncCancel(requestId)
          : _sync.asyncCancel(requestId);
      if (ok) {
        return const Success(unit);
      }
      return await _convertNativeErrorToFailure<Unit>(
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

  @override
  Future<Result<Unit>> asyncFree(int requestId) async {
    if (requestId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid async request ID'),
      );
    }

    try {
      final ok = _isAsync
          ? await _async.asyncFree(requestId)
          : _sync.asyncFree(requestId);
      if (ok) {
        return const Success(unit);
      }
      return await _convertNativeErrorToFailure<Unit>(
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

  @override
  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    final nativeId = _connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    try {
      final streamId = _isAsync
          ? await _async.streamStartAsync(
              nativeId,
              sql,
              fetchSize: fetchSize,
              chunkSize: chunkSize,
            )
          : _sync.streamStartAsync(
              nativeId,
              sql,
              fetchSize: fetchSize,
              chunkSize: chunkSize,
            );
      final resolved = streamId ?? 0;
      if (resolved > 0) {
        return Success(resolved);
      }
      return await _convertNativeErrorToFailure<int>(
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

  @override
  Future<Result<int>> streamPollAsync(int streamId) async {
    if (streamId <= 0) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid stream ID'),
      );
    }

    try {
      final status = _isAsync
          ? await _async.streamPollAsync(
              streamId,
            )
          : _sync.streamPollAsync(streamId);
      final resolved = status ?? -1;
      return Success(resolved);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
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
        ? await _async.detectDriver(connectionString)
        : _sync.detectDriver(connectionString);
  }
}
