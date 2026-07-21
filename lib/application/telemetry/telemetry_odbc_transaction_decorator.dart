import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/services/i_transaction_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_operations.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:result_dart/result_dart.dart';

/// Transaction-shaped telemetry decorator implementing [ITransactionService].
class TelemetryOdbcTransactionDecorator implements ITransactionService {
  /// Creates a transaction telemetry decorator.
  TelemetryOdbcTransactionDecorator(
    ITransactionService transactions,
    this._ops, [
    IOdbcService? aggregate,
  ])  : _transactions = transactions,
        _aggregate =
            aggregate ?? (transactions is IOdbcService ? transactions : null);

  final ITransactionService _transactions;
  final TelemetryOdbcOperations _ops;
  final IOdbcService? _aggregate;

  IOdbcService get _service => _aggregate ?? _transactions as IOdbcService;

  @override
  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      _ops.inOperation(
        'ODBC.beginTransaction',
        () => _transactions.beginTransaction(
          connectionId,
          isolationLevel: isolationLevel,
          savepointDialect: savepointDialect,
          accessMode: accessMode,
          lockTimeout: lockTimeout,
        ),
      );

  @override
  Future<Result<void>> commitTransaction(String connectionId, int txnId) =>
      _ops.inOperation(
        'ODBC.commitTransaction',
        () => _transactions.commitTransaction(connectionId, txnId),
      );

  @override
  Future<Result<void>> rollbackTransaction(String connectionId, int txnId) =>
      _ops.inOperation(
        'ODBC.rollbackTransaction',
        () => _transactions.rollbackTransaction(connectionId, txnId),
      );

  @override
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
        () => _transactions.runInTransaction<T>(
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

  Future<Result<List<Xid>>> xaRecover(String connectionId) => _ops.inOperation(
        'ODBC.xaRecover',
        () => _service.xaRecover(connectionId),
      );

  Future<Result<XaTransactionHandle>> xaResumePrepared(
    String connectionId,
    Xid xid,
  ) =>
      _ops.inOperation(
        'ODBC.xaResumePrepared',
        () => _service.xaResumePrepared(connectionId, xid),
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
