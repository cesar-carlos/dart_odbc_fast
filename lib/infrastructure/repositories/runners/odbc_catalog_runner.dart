import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/connection_options.dart';
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
typedef ParseBufferFn = QueryResult? Function(
  Uint8List? buf, {
  bool lazyStrings,
});

/// Looks up [ConnectionOptions] for a domain connection id.
typedef ConnectionOptionsLookupFn = ConnectionOptions? Function(
  String connectionId,
);

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
class OdbcCatalogRunner {
  OdbcCatalogRunner({
    required this.backend,
    required this.nativeIdLookup,
    required this.parseBuffer,
    required this.convertQueryError,
    this.optionsLookup,
  });

  final OdbcBackend backend;
  final NativeIdLookupFn nativeIdLookup;
  final ParseBufferFn parseBuffer;
  final ConvertQueryErrorFn convertQueryError;
  final ConnectionOptionsLookupFn? optionsLookup;

  Future<Result<QueryResult>> catalogTables(
    String connectionId, {
    String catalog = '',
    String schema = '',
  }) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to list catalog tables',
        call: (nativeId, initialBytes, maxBytes) => switch (backend) {
          SyncBackend(:final connection) => connection.catalogTables(
              nativeId,
              catalog: catalog,
              schema: schema,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
          AsyncBackend(:final connection) => connection.catalogTables(
              nativeId,
              catalog: catalog,
              schema: schema,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
        },
      );

  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to list catalog columns',
        call: (nativeId, initialBytes, maxBytes) => switch (backend) {
          SyncBackend(:final connection) => connection.catalogColumns(
              nativeId,
              table,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
          AsyncBackend(:final connection) => connection.catalogColumns(
              nativeId,
              table,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
        },
      );

  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to get catalog type info',
        call: (nativeId, initialBytes, maxBytes) => switch (backend) {
          SyncBackend(:final connection) => connection.catalogTypeInfo(
              nativeId,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
          AsyncBackend(:final connection) => connection.catalogTypeInfo(
              nativeId,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
        },
      );

  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to list catalog primary keys',
        call: (nativeId, initialBytes, maxBytes) => switch (backend) {
          SyncBackend(:final connection) => connection.catalogPrimaryKeys(
              nativeId,
              table,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
          AsyncBackend(:final connection) => connection.catalogPrimaryKeys(
              nativeId,
              table,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
        },
      );

  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to list catalog foreign keys',
        call: (nativeId, initialBytes, maxBytes) => switch (backend) {
          SyncBackend(:final connection) => connection.catalogForeignKeys(
              nativeId,
              table,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
          AsyncBackend(:final connection) => connection.catalogForeignKeys(
              nativeId,
              table,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
        },
      );

  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) =>
      _runCatalog(
        connectionId: connectionId,
        fallbackMessage: 'Failed to list catalog indexes',
        call: (nativeId, initialBytes, maxBytes) => switch (backend) {
          SyncBackend(:final connection) => connection.catalogIndexes(
              nativeId,
              table,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
          AsyncBackend(:final connection) => connection.catalogIndexes(
              nativeId,
              table,
              initialBufferBytes: initialBytes,
              maxBufferBytes: maxBytes,
            ),
        },
      );

  Future<Result<QueryResult>> _runCatalog({
    required String connectionId,
    required String fallbackMessage,
    required FutureOr<Uint8List?> Function(
      int nativeId,
      int? initialBufferBytes,
      int? maxBufferBytes,
    ) call,
  }) async {
    final nativeId = nativeIdLookup(connectionId);
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    final opts = optionsLookup?.call(connectionId);
    final initialBytes =
        opts?.initialResultBufferBytes ?? defaultInitialResultBufferBytes;
    final maxBytes = opts?.maxResultBufferBytes;
    final lazyStrings = opts?.lazyStrings ?? false;
    final queryTimeout = opts?.queryTimeout;

    try {
      final pending = Future<Uint8List?>(
        () => call(
          nativeId,
          initialBytes,
          maxBytes,
        ),
      );
      final buf = queryTimeout == null
          ? await pending
          : await pending.timeout(
              queryTimeout,
              onTimeout: () => throw TimeoutException(
                'Catalog operation timed out after '
                '${queryTimeout.inMilliseconds}ms',
              ),
            );
      final qr = parseBuffer(buf, lazyStrings: lazyStrings);
      if (qr == null) {
        return await convertQueryError(
          fallbackMessage: fallbackMessage,
          nativeConnectionId: nativeId,
        );
      }
      return Success(qr);
    } on TimeoutException catch (e) {
      return Failure<QueryResult, OdbcError>(
        QueryError(message: e.message ?? 'Catalog operation timed out'),
      );
    } on Exception catch (e) {
      return convertQueryError(
        fallbackMessage: e.toString(),
        nativeConnectionId: nativeId,
      );
    }
  }
}
