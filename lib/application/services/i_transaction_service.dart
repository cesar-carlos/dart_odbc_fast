import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:result_dart/result_dart.dart';

/// Transaction-shaped operations subset of `IOdbcService`.
///
/// Local 2PC primitives without the rest of the surface (queries, pool,
/// admin). XA / 2PC operations remain on the aggregate `IOdbcService`
/// because they expose helper types (`XaTransactionHandle`) that bring
/// in heavier dependencies.
abstract interface class ITransactionService {
  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  });

  Future<Result<void>> commitTransaction(String connectionId, int txnId);

  Future<Result<void>> rollbackTransaction(String connectionId, int txnId);

  /// Run [action] inside a freshly opened transaction with automatic
  /// commit-on-success / rollback-on-failure semantics.
  Future<Result<T>> runInTransaction<T extends Object>(
    String connectionId,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  });
}

/// Ergonomic overloads for [ITransactionService]. See
/// `IQueryServiceConnectionOverloads` for the rationale.
extension ITransactionServiceConnectionOverloads on ITransactionService {
  /// `beginTransaction` overload that accepts a [Connection].
  Future<Result<int>> beginTransactionFor(
    Connection conn, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      beginTransaction(
        conn.id,
        isolationLevel: isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeout: lockTimeout,
      );

  /// `runInTransaction` overload that accepts a [Connection].
  Future<Result<T>> runInTransactionFor<T extends Object>(
    Connection conn,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      runInTransaction(
        conn.id,
        action,
        isolationLevel: isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeout: lockTimeout,
      );
}
