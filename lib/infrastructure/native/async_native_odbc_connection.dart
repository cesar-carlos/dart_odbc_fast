library;

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/core/di/async_backpressure_mode.dart';
import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/entities/async_worker_pool_stats.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/isolate/worker_isolate.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/frame_accumulator.dart';
import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart'
    show NamedParameterParser, ParameterMissingException;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/native/protocol/stream_frame_decode.dart';

export 'package:odbc_fast/core/di/async_backpressure_mode.dart';

part 'async_worker_channel.dart';
part 'async_worker_lifecycle.dart';
part 'async_worker_dispatch.dart';
part 'async_worker_stats.dart';
part 'async_connection.dart';
part 'async_query_async.dart';
part 'async_transactions.dart';
part 'async_query.dart';
part 'async_pool.dart';
part 'async_streaming.dart';

const _defaultRequestTimeout = Duration(seconds: 30);
const _streamAsyncStatusPending = 0;
const _streamAsyncStatusReady = 1;
const _streamAsyncStatusDone = 2;
const _streamAsyncStatusError = -1;
const _streamAsyncStatusCancelled = -2;
const _pollBackoffMin = Duration(milliseconds: 1);

/// Non-blocking wrapper around ODBC using a long-lived worker isolate.
///
/// **Architecture**: All FFI/ODBC operations run in a dedicated worker isolate.
/// The main thread stays responsive; no blocking FFI calls run on the UI
/// thread.
///
/// ## How it works
///
/// 1. `initialize` spawns a worker isolate and loads the ODBC driver.
/// 2. Each operation sends a request (via [SendPort]) to the worker.
/// 3. The worker runs the FFI call and sends back the result (via
///    [ReceivePort]).
/// 4. The main thread never blocks on ODBC.
///
/// ## Performance
///
/// - Worker spawn (one-time): ~50–100 ms.
/// - Per-operation overhead: ~1–3 ms.
/// - Parallel queries: N queries complete in the time of the longest (not
///   the sum).
///
/// ## Request timeout
///
/// Use `requestTimeout` to avoid UI hangs when the worker does not respond
/// (default 30s). Pass `Duration.zero` or `null` to disable.
///
/// ## Example
///
/// ```dart
/// final async = AsyncNativeOdbcConnection(
///   requestTimeout: Duration(seconds: 30),
/// );
/// await async.initialize();
///
/// final connId = await async.connect(dsn);
/// final data = await async.executeQueryParams(connId, 'SELECT 1', []);
/// await async.disconnect(connId);
///
/// async.dispose(); // Pending requests complete with error
/// ```
///
/// See also:
/// - `worker_isolate.dart` for the worker entry and request handling.
/// - [WorkerRequest] and [WorkerResponse] for the message protocol.
abstract class _AsyncOdbcState {
  _AsyncOdbcState({
    required Duration? requestTimeout,
    required void Function(SendPort)? isolateEntry,
    required this.autoRecoverOnWorkerCrash,
    required this.workerCount,
    required this.maxPendingRequests,
    required this.backpressureMode,
    required this.backpressureTimeout,
  })  : _requestTimeout = requestTimeout,
        _isolateEntry = isolateEntry;

  final Duration? _requestTimeout;

  /// Test hook: custom isolate entry. When set, used instead of [workerEntry].
  final void Function(SendPort)? _isolateEntry;

  final int workerCount;
  final int? maxPendingRequests;
  final AsyncBackpressureMode backpressureMode;
  final Duration? backpressureTimeout;
  final bool autoRecoverOnWorkerCrash;

  /// Optional callback invoked after `_recoverWorkerInternal` completes a
  /// successful auto-recovery.
  void Function()? onWorkerRecovered;

  final List<_WorkerChannel> _workers = [];
  bool _isInitialized = false;
  bool _isShuttingDown = false;
  int _requestIdCounter = 0;
  final Map<int, List<String>> _namedParamOrderByStmtId = {};
  final Map<int, int> _connectionWorkerById = {};
  final Map<int, int> _statementWorkerById = {};
  final Map<int, int> _statementConnectionById = {};
  final Map<int, int> _transactionWorkerById = {};
  final Map<int, int> _transactionConnectionById = {};
  final Map<int, int> _streamWorkerById = {};
  final Map<int, int> _asyncRequestWorkerById = {};
  final Queue<_BackpressureWaiter> _backpressureWaiters =
      Queue<_BackpressureWaiter>();
  int _backpressureSlotsReserved = 0;
  int _cachedAggregateLatencyP95Version = -1;
  int _cachedAggregateQueueWaitP95Version = -1;
  int _cachedAggregateExecutionP95Version = -1;
  int _cachedAggregateLatencyP95Micros = 0;
  int _cachedAggregateQueueWaitP95Micros = 0;
  int _cachedAggregateExecutionP95Micros = 0;
  Completer<void>? _recoveryInFlight;
}

class AsyncNativeOdbcConnection extends _AsyncOdbcState
    with
        _AsyncWorkerDispatch,
        _AsyncConnection,
        _AsyncWorkerLifecycle,
        _AsyncWorkerStats,
        _AsyncQueryAsync,
        _AsyncQuery,
        _AsyncTransactions,
        _AsyncPool,
        _AsyncStreaming {
  AsyncNativeOdbcConnection({
    super.requestTimeout,
    super.isolateEntry,
    super.autoRecoverOnWorkerCrash = false,
    super.workerCount = 1,
    super.maxPendingRequests,
    super.backpressureMode = AsyncBackpressureMode.failFast,
    super.backpressureTimeout,
  }) {
    if (workerCount < 1) {
      throw ArgumentError.value(
        workerCount,
        'workerCount',
        'must be greater than or equal to 1',
      );
    }
    final pendingLimit = maxPendingRequests;
    if (pendingLimit != null && pendingLimit < 1) {
      throw ArgumentError.value(
        pendingLimit,
        'maxPendingRequests',
        'must be null or greater than or equal to 1',
      );
    }
    final pendingTimeout = backpressureTimeout;
    if (pendingTimeout != null && pendingTimeout < Duration.zero) {
      throw ArgumentError.value(
        pendingTimeout,
        'backpressureTimeout',
        'must be null, zero, or greater than zero',
      );
    }
  }
}
