import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_operations.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:result_dart/result_dart.dart';

/// Transaction-shaped telemetry delegate for the ODBC service decorator façade.
class TelemetryOdbcTransactionDecorator {
  /// Creates a transaction telemetry delegate.
  TelemetryOdbcTransactionDecorator(this._service, this._ops);

  final IOdbcService _service;
  final TelemetryOdbcOperations _ops;

  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      _ops.inOperation(
        'ODBC.beginTransaction',
        () => _service.beginTransaction(
          connectionId,
          isolationLevel: isolationLevel,
          savepointDialect: savepointDialect,
          accessMode: accessMode,
          lockTimeout: lockTimeout,
        ),
      );

  Future<Result<void>> commitTransaction(String connectionId, int txnId) =>
      _ops.inOperation(
        'ODBC.commitTransaction',
        () => _service.commitTransaction(connectionId, txnId),
      );

  Future<Result<void>> rollbackTransaction(String connectionId, int txnId) =>
      _ops.inOperation(
        'ODBC.rollbackTransaction',
        () => _service.rollbackTransaction(connectionId, txnId),
      );

  Future<Result<T>> runInTransaction<T extends Object>(
    String connectionId,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      _ops.inOperation(
        'ODBC.runInTransaction',
        () => _service.runInTransaction<T>(
          connectionId,
          action,
          isolationLevel: isolationLevel,
          savepointDialect: savepointDialect,
          accessMode: accessMode,
          lockTimeout: lockTimeout,
        ),
      );

  Future<Result<T>> runInXaTransaction<T extends Object>(
    String connectionId,
    Xid xid,
    Future<Result<T>> Function(XaTransactionHandle xa) action, {
    bool onePhase = false,
  }) =>
      _ops.inOperation(
        'ODBC.runInXaTransaction',
        () => _service.runInXaTransaction<T>(
          connectionId,
          xid,
          action,
          onePhase: onePhase,
        ),
      );

  Future<Result<void>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _ops.inOperation(
        'ODBC.createSavepoint',
        () => _service.createSavepoint(connectionId, txnId, name),
      );

  Future<Result<void>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _ops.inOperation(
        'ODBC.rollbackToSavepoint',
        () => _service.rollbackToSavepoint(connectionId, txnId, name),
      );

  Future<Result<void>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _ops.inOperation(
        'ODBC.releaseSavepoint',
        () => _service.releaseSavepoint(connectionId, txnId, name),
      );
}
