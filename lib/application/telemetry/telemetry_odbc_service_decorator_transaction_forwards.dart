import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_base.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:result_dart/result_dart.dart';

/// Transaction-shaped `IOdbcService` forwards for the telemetry decorator
/// façade.
mixin TelemetryOdbcServiceTransactionForwards
    on TelemetryOdbcServiceDecoratorBase {
  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      transaction.beginTransaction(
        connectionId,
        isolationLevel: isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeout: lockTimeout,
      );

  Future<Result<void>> commitTransaction(String connectionId, int txnId) =>
      transaction.commitTransaction(connectionId, txnId);

  Future<Result<void>> rollbackTransaction(String connectionId, int txnId) =>
      transaction.rollbackTransaction(connectionId, txnId);

  Future<Result<T>> runInTransaction<T extends Object>(
    String connectionId,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      transaction.runInTransaction<T>(
        connectionId,
        action,
        isolationLevel: isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeout: lockTimeout,
      );

  Future<Result<T>> runInXaTransaction<T extends Object>(
    String connectionId,
    Xid xid,
    Future<Result<T>> Function(XaTransactionHandle xa) action, {
    bool onePhase = false,
  }) =>
      transaction.runInXaTransaction<T>(
        connectionId,
        xid,
        action,
        onePhase: onePhase,
      );

  Future<Result<List<Xid>>> xaRecover(String connectionId) =>
      transaction.xaRecover(connectionId);

  Future<Result<XaTransactionHandle>> xaResumePrepared(
    String connectionId,
    Xid xid,
  ) =>
      transaction.xaResumePrepared(connectionId, xid);

  Future<Result<void>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      transaction.createSavepoint(connectionId, txnId, name);

  Future<Result<void>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      transaction.rollbackToSavepoint(connectionId, txnId, name);

  Future<Result<void>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      transaction.releaseSavepoint(connectionId, txnId, name);
}
