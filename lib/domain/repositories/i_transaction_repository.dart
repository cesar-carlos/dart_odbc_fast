import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:result_dart/result_dart.dart';

/// Transaction, savepoint, and XA operations for the ODBC repository.
abstract interface class ITransactionRepository {
  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel, {
    SavepointDialect savepointDialect = SavepointDialect.auto,
    TransactionAccessMode accessMode = TransactionAccessMode.readWrite,
    Duration? lockTimeout,
  });

  Future<Result<Unit>> commitTransaction(String connectionId, int txnId);

  Future<Result<Unit>> rollbackTransaction(String connectionId, int txnId);

  Future<Result<XaTransactionHandle>> xaStart(
    String connectionId,
    Xid xid,
  );

  Future<Result<List<Xid>>> xaRecover(String connectionId);

  Future<Result<XaTransactionHandle>> xaResumePrepared(
    String connectionId,
    Xid xid,
  );

  Future<Result<Unit>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  );

  Future<Result<Unit>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  );

  Future<Result<Unit>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  );
}
