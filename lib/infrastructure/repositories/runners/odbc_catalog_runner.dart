import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:result_dart/result_dart.dart';

/// Resolves the native id for a domain `connectionId`, or returns `null`
/// when the connection is unknown. Injected so the runner does not need
/// to reach into the repository's private state map.
typedef NativeIdLookupFn = int? Function(String connectionId);

/// Signature for `OdbcRepositoryImpl._parseBufferToQueryResult`. Injected
/// so the runner does not need access to the parser internals (and so the
/// repository can swap the strategy in tests).
typedef ParseBufferFn = QueryResult? Function(Uint8List? buf);

/// Signature for `OdbcRepositoryImpl._convertNativeErrorToFailure<QueryResult>`
/// specialized for the catalog return type. Injected so the runner reuses
/// the central error mapping (structured error → typed `OdbcError`).
typedef ConvertQueryErrorFn = Future<Failure<QueryResult, OdbcError>> Function({
  required String fallbackMessage,
  int? nativeConnectionId,
});

/// Runs the catalog / metadata family of operations
/// (`catalogTables`, `catalogColumns`, `catalogTypeInfo`,
/// `catalogPrimaryKeys`, `catalogForeignKeys`, `catalogIndexes`).
///
/// Step 2 of the repository split (see
/// `native/doc/repository_split_plan.md`). Composition: the
/// `OdbcRepositoryImpl` façade holds an instance and delegates each
/// catalog method to it. The runner is intentionally stateless — every
/// invariant (connection id resolution, buffer parsing, error mapping)
/// is plumbed in as a function pointer so the repository keeps a single
/// source of truth for those concerns.
class OdbcCatalogRunner {
  OdbcCatalogRunner({
    required this.backend,
    required this.nativeIdLookup,
    required this.parseBuffer,
    required this.convertQueryError,
  });

  final OdbcBackend backend;
  final NativeIdLookupFn nativeIdLookup;
  final ParseBufferFn parseBuffer;
  final ConvertQueryErrorFn convertQueryError;

  /// Lists tables for the given connection. See
  /// `IOdbcRepository.catalogTables` for the contract.
  Future<Result<QueryResult>> catalogTables(
    String connectionId, {
    String catalog = '',
    String schema = '',
  }) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to list catalog tables',
        call: (nativeId) => switch (backend) {
          SyncBackend(:final connection) => connection.catalogTables(
              nativeId,
              catalog: catalog,
              schema: schema,
            ),
          AsyncBackend(:final connection) => connection.catalogTables(
              nativeId,
              catalog: catalog,
              schema: schema,
            ),
        },
      );

  /// Lists columns for [table] on the given connection.
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to list catalog columns',
        call: (nativeId) => switch (backend) {
          SyncBackend(:final connection) =>
            connection.catalogColumns(nativeId, table),
          AsyncBackend(:final connection) =>
            connection.catalogColumns(nativeId, table),
        },
      );

  /// Returns the data-type information from `INFORMATION_SCHEMA.COLUMNS`.
  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to get catalog type info',
        call: (nativeId) => switch (backend) {
          SyncBackend(:final connection) =>
            connection.catalogTypeInfo(nativeId),
          AsyncBackend(:final connection) =>
            connection.catalogTypeInfo(nativeId),
        },
      );

  /// Lists primary keys for [table].
  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to list catalog primary keys',
        call: (nativeId) => switch (backend) {
          SyncBackend(:final connection) =>
            connection.catalogPrimaryKeys(nativeId, table),
          AsyncBackend(:final connection) =>
            connection.catalogPrimaryKeys(nativeId, table),
        },
      );

  /// Lists foreign keys for [table].
  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to list catalog foreign keys',
        call: (nativeId) => switch (backend) {
          SyncBackend(:final connection) =>
            connection.catalogForeignKeys(nativeId, table),
          AsyncBackend(:final connection) =>
            connection.catalogForeignKeys(nativeId, table),
        },
      );

  /// Lists indexes for [table].
  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to list catalog indexes',
        call: (nativeId) => switch (backend) {
          SyncBackend(:final connection) =>
            connection.catalogIndexes(nativeId, table),
          AsyncBackend(:final connection) =>
            connection.catalogIndexes(nativeId, table),
        },
      );

  /// Shared scaffolding for all catalog ops. Validates the connection,
  /// dispatches the FFI call (sync result or `Future`), parses the buffer,
  /// and routes failure paths to the central error converter.
  Future<Result<QueryResult>> _runCatalog({
    required String connectionId,
    required String fallbackMessage,
    required FutureOr<Uint8List?> Function(int nativeId) call,
  }) async {
    final nativeId = nativeIdLookup(connectionId);
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    try {
      final buf = await call(nativeId);
      final qr = parseBuffer(buf);
      if (qr == null) {
        return await convertQueryError(
          fallbackMessage: fallbackMessage,
          nativeConnectionId: nativeId,
        );
      }
      return Success(qr);
    } on Exception catch (e) {
      return convertQueryError(
        fallbackMessage: e.toString(),
        nativeConnectionId: nativeId,
      );
    }
  }
}
