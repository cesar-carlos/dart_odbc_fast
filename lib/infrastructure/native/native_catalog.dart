part of 'native_odbc_connection.dart';

mixin _NativeCatalog on _NativeOdbcState {
  Uint8List? catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  }) =>
      _native.catalogTables(
        connectionId,
        catalog: catalog,
        schema: schema,
      );

  /// Creates a [CatalogQuery] wrapper for database catalog queries.
  ///
  /// The [connectionId] must be a valid active connection.
  /// Returns a [CatalogQuery] instance for querying database metadata.
  CatalogQuery catalogQuery(int connectionId) =>
      CatalogQuery(_connection, connectionId);

  Uint8List? catalogColumns(int connectionId, String table) =>
      _native.catalogColumns(connectionId, table);

  Uint8List? catalogTypeInfo(int connectionId) =>
      _native.catalogTypeInfo(connectionId);

  Uint8List? catalogPrimaryKeys(int connectionId, String table) =>
      _native.catalogPrimaryKeys(connectionId, table);

  Uint8List? catalogForeignKeys(int connectionId, String table) =>
      _native.catalogForeignKeys(connectionId, table);

  Uint8List? catalogIndexes(int connectionId, String table) =>
      _native.catalogIndexes(connectionId, table);
}
