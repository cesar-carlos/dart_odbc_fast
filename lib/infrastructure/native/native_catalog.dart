part of 'native_odbc_connection.dart';

mixin _NativeCatalog on _NativeOdbcState {
  Uint8List? catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) =>
      _captureSync(
        'catalogTables',
        () => _native.catalogTables(
          connectionId,
          catalog: catalog,
          schema: schema,
          initialBufferBytes: initialBufferBytes,
          maxBufferBytes: maxBufferBytes,
        ),
        failed: (value) => value == null,
        nativeConnectionId: connectionId,
      );

  /// Creates a [CatalogQuery] wrapper for database catalog queries.
  CatalogQuery catalogQuery(int connectionId) =>
      CatalogQuery(_connection, connectionId);

  Uint8List? catalogColumns(
    int connectionId,
    String table, {
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) =>
      _captureSync(
        'catalogColumns',
        () => _native.catalogColumns(
          connectionId,
          table,
          initialBufferBytes: initialBufferBytes,
          maxBufferBytes: maxBufferBytes,
        ),
        failed: (value) => value == null,
        nativeConnectionId: connectionId,
      );

  Uint8List? catalogTypeInfo(
    int connectionId, {
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) =>
      _captureSync(
        'catalogTypeInfo',
        () => _native.catalogTypeInfo(
          connectionId,
          initialBufferBytes: initialBufferBytes,
          maxBufferBytes: maxBufferBytes,
        ),
        failed: (value) => value == null,
        nativeConnectionId: connectionId,
      );

  Uint8List? catalogPrimaryKeys(
    int connectionId,
    String table, {
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) =>
      _captureSync(
        'catalogPrimaryKeys',
        () => _native.catalogPrimaryKeys(
          connectionId,
          table,
          initialBufferBytes: initialBufferBytes,
          maxBufferBytes: maxBufferBytes,
        ),
        failed: (value) => value == null,
        nativeConnectionId: connectionId,
      );

  Uint8List? catalogForeignKeys(
    int connectionId,
    String table, {
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) =>
      _captureSync(
        'catalogForeignKeys',
        () => _native.catalogForeignKeys(
          connectionId,
          table,
          initialBufferBytes: initialBufferBytes,
          maxBufferBytes: maxBufferBytes,
        ),
        failed: (value) => value == null,
        nativeConnectionId: connectionId,
      );

  Uint8List? catalogIndexes(
    int connectionId,
    String table, {
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) =>
      _captureSync(
        'catalogIndexes',
        () => _native.catalogIndexes(
          connectionId,
          table,
          initialBufferBytes: initialBufferBytes,
          maxBufferBytes: maxBufferBytes,
        ),
        failed: (value) => value == null,
        nativeConnectionId: connectionId,
      );
}
