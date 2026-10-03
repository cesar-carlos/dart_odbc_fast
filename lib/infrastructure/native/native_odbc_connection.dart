library;

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart' as domain;
import 'package:odbc_fast/infrastructure/native/audit/odbc_audit_logger.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart'
    as bindings;
import 'package:odbc_fast/infrastructure/native/driver_capabilities.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_call_context.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_cleanup.dart';
import 'package:odbc_fast/infrastructure/native/errors/odbc_error_translator.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:odbc_fast/infrastructure/native/protocol/frame_accumulator.dart';
import 'package:odbc_fast/infrastructure/native/protocol/stream_frame_decode.dart';
import 'package:odbc_fast/infrastructure/native/wrappers/transaction_completion_status.dart';
import 'package:odbc_fast/odbc_fast.dart'
    hide
        DatabaseEngineIds,
        DatabaseType,
        DbmsInfo,
        DmlVerb,
        DriverCapabilities,
        OdbcDriverCapabilities,
        OdbcDriverFeatures,
        PoolOptions,
        SessionOptions;

part 'native_async_audit.dart';
part 'native_catalog.dart';
part 'native_connection.dart';
part 'native_pool.dart';
part 'native_prepared_query.dart';
part 'native_streaming.dart';
part 'native_transactions.dart';

abstract class _NativeOdbcState {
  _NativeOdbcState(bindings.OdbcNative native) : _native = native {
    _auditLogger = OdbcAuditLogger(_native);
  }

  final bindings.OdbcNative _native;
  late final OdbcAuditLogger _auditLogger;
  bool _isInitialized = false;

  NativeOdbcConnection get _connection => this as NativeOdbcConnection;

  T _captureSync<T>(
    String operation,
    T Function() call, {
    required bool Function(T) failed,
    int? nativeConnectionId,
  }) {
    nativeConnectionId ??= NativeCallContext.current?.nativeConnectionId;
    final result = NativeCallContext.invoke(call);
    if (NativeCallContext.current == null || !failed(result)) return result;
    if (result == null &&
        (operation.startsWith('executeAsyncStart') ||
            operation.startsWith('streamMultiStart'))) {
      NativeCallContext.record(
        UnsupportedFeatureError(
          message: 'The native entrypoint is unavailable',
          details: OdbcErrorDetails(operation: operation),
        ),
      );
      return result;
    }
    OdbcError error = QueryError(
      message: 'Failed to complete $operation',
      details: OdbcErrorDetails(
        operation: operation,
        connectionId: nativeConnectionId?.toString(),
        code: operation == 'streamClose' || operation == 'asyncFree'
            ? OdbcErrorCode.cleanup
            : null,
      ),
    );
    try {
      final structured = nativeConnectionId == null
          ? _connection.getStructuredError()
          : _connection.getStructuredErrorForConnection(nativeConnectionId);
      final message = (structured?.message ?? _connection.getError()).trim();
      error = QueryError(
        message:
            message.isEmpty || message == 'No error' ? error.message : message,
        sqlState: structured?.sqlStateString,
        nativeCode: structured?.nativeCode,
        details: error.details,
      );
    } on Object catch (diagnosticError, stack) {
      error = error.withSecondary(
        translateOdbcError(
          diagnosticError,
          operation: 'collectDiagnostic',
          stackTrace: stack,
        ),
      );
    }
    NativeCallContext.record(error);
    return result;
  }
}

/// Native ODBC connection implementation using FFI bindings.
///
/// Provides direct access to the Rust-based ODBC engine through FFI.
/// This is the low-level implementation that handles all native ODBC operations
/// including connections, queries, transactions, prepared statements,
/// connection pooling, and streaming.
///
/// Example:
/// ```dart
/// final native = NativeOdbcConnection();
/// native.initialize();
/// final connId = native.connect('DSN=MyDatabase');
/// ```
class NativeOdbcConnection extends _NativeOdbcState
    with
        _NativeConnection,
        _NativeAsyncAudit,
        _NativeTransactions,
        _NativePreparedQuery,
        _NativeCatalog,
        _NativePool,
        _NativeStreaming
    implements OdbcConnectionBackend, TransactionCompletionStatus {
  /// Creates a new [NativeOdbcConnection] instance.
  NativeOdbcConnection({int? sqlPointerCacheMaxSize})
      : super(
          bindings.OdbcNative(
            sqlPointerCacheMaxSize: sqlPointerCacheMaxSize,
          ),
        );

  /// Creates an instance backed by injected [native] (unit tests only).
  @visibleForTesting
  NativeOdbcConnection.testing(super.native);
}
