import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_catalog_runner.dart'
    show NativeIdLookupFn;
import 'package:result_dart/result_dart.dart';

/// Signature for `OdbcRepositoryImpl._convertNativeErrorToFailure<int>`
/// specialized for bulk insert. Same shape as `ConvertQueryErrorFn` but
/// returns `Failure<int, OdbcError>` because bulk inserts return the
/// number of rows on success.
typedef ConvertIntErrorFn = Future<Failure<int, OdbcError>> Function({
  required String fallbackMessage,
  int? nativeConnectionId,
});

/// Runs the bulk-insert family of operations (`bulkInsert` and
/// `bulkInsertParallel`).
///
/// Step 3 of the repository split (see
/// `native/doc/repository_split_plan.md`). Same composition pattern as
/// [OdbcCatalogRunner](odbc_catalog_runner.dart): stateless, plumbs
/// every cross-cutting concern via injected closures. Owns its own
/// dispatch through the sealed [OdbcBackend].
class OdbcBulkRunner {
  OdbcBulkRunner({
    required this.backend,
    required this.nativeIdLookup,
    required this.convertIntError,
  });

  final OdbcBackend backend;
  final NativeIdLookupFn nativeIdLookup;
  final ConvertIntErrorFn convertIntError;

  /// Performs a single-connection bulk insert. See
  /// `IOdbcRepository.bulkInsert` for the contract.
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) async {
    final nativeId = nativeIdLookup(connectionId);
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    final buffer = asUint8List(dataBuffer);
    try {
      final n = await _bulkInsertArray(
        nativeId: nativeId,
        table: table,
        columns: columns,
        buffer: buffer,
        rowCount: rowCount,
      );
      if (n < 0) {
        return await convertIntError(
          fallbackMessage: 'Failed to bulk insert',
          nativeConnectionId: nativeId,
        );
      }
      return Success(n);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(QueryError(message: e.toString()));
    }
  }

  /// Performs a parallel bulk insert across a connection pool. See
  /// `IOdbcRepository.bulkInsertParallel` for the contract. When
  /// `parallelism <= 1`, falls back to a single connection checked out
  /// from the pool.
  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  }) async {
    if (poolId <= 0) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid pool ID'),
      );
    }
    if (table.trim().isEmpty) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Table name cannot be empty'),
      );
    }
    if (columns.isEmpty) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Column list cannot be empty'),
      );
    }
    if (dataBuffer.isEmpty) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Data buffer cannot be empty'),
      );
    }
    if (rowCount <= 0) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Row count must be greater than zero'),
      );
    }
    final buffer = asUint8List(dataBuffer);

    if (parallelism <= 1) {
      return _bulkInsertParallelFallback(
        poolId: poolId,
        table: table,
        columns: columns,
        buffer: buffer,
        rowCount: rowCount,
      );
    }

    try {
      final n = await _bulkInsertParallel(
        poolId: poolId,
        table: table,
        columns: columns,
        buffer: buffer,
        parallelism: parallelism,
      );
      if (n < 0) {
        return await convertIntError(
          fallbackMessage: 'Failed to execute parallel bulk insert',
        );
      }
      return Success(n);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(QueryError(message: e.toString()));
    }
  }

  Future<Result<int>> _bulkInsertParallelFallback({
    required int poolId,
    required String table,
    required List<String> columns,
    required Uint8List buffer,
    required int rowCount,
  }) async {
    final connId = await _poolGetConnection(poolId);
    if (connId == 0) {
      return convertIntError(
        fallbackMessage:
            'Failed to get pool connection for bulk insert fallback',
      );
    }

    try {
      final n = await _bulkInsertArray(
        nativeId: connId,
        table: table,
        columns: columns,
        buffer: buffer,
        rowCount: rowCount,
      );
      if (n < 0) {
        return await convertIntError(
          fallbackMessage: 'Failed to bulk insert in fallback mode',
        );
      }
      return Success(n);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(QueryError(message: e.toString()));
    } finally {
      final released = await _poolReleaseConnection(connId);
      if (!released) {
        AppLogger.warning(
          'bulkInsertParallel: failed to release pool connection $connId '
          'back to pool $poolId',
        );
      }
    }
  }

  Future<int> _bulkInsertArray({
    required int nativeId,
    required String table,
    required List<String> columns,
    required Uint8List buffer,
    required int rowCount,
  }) =>
      switch (backend) {
        SyncBackend(:final connection) => Future.value(
            connection.bulkInsertArray(
              nativeId,
              table,
              columns,
              buffer,
              rowCount,
            ),
          ),
        AsyncBackend(:final connection) => connection.bulkInsertArray(
            nativeId,
            table,
            columns,
            buffer,
            rowCount,
          ),
      };

  Future<int> _bulkInsertParallel({
    required int poolId,
    required String table,
    required List<String> columns,
    required Uint8List buffer,
    required int parallelism,
  }) =>
      switch (backend) {
        SyncBackend(:final connection) => Future.value(
            connection.bulkInsertParallel(
              poolId,
              table,
              columns,
              buffer,
              parallelism,
            ),
          ),
        AsyncBackend(:final connection) => connection.bulkInsertParallel(
            poolId,
            table,
            columns,
            buffer,
            parallelism,
          ),
      };

  Future<int> _poolGetConnection(int poolId) => switch (backend) {
        SyncBackend(:final connection) =>
          Future.value(connection.poolGetConnection(poolId)),
        AsyncBackend(:final connection) => connection.poolGetConnection(poolId),
      };

  Future<bool> _poolReleaseConnection(int connId) => switch (backend) {
        SyncBackend(:final connection) =>
          Future.value(connection.poolReleaseConnection(connId)),
        AsyncBackend(:final connection) =>
          connection.poolReleaseConnection(connId),
      };
}

/// Returns [data] unchanged when it is already a [Uint8List]; otherwise copies.
///
/// Keeps the hot path zero-copy for `BulkInsertBuilder.build()` payloads.
Uint8List asUint8List(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);
