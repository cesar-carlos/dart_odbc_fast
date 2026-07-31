part of 'odbc_native.dart';

mixin _OdbcNativeQueryCatalog on _OdbcNativeState, _OdbcNativeHelpers {
  /// Queries the database catalog for table information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [catalog] and [schema] parameters filter results.
  /// Empty strings match all values.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) {
    return _withUtf8Pair(
      catalog,
      schema,
      (cPtr, sPtr) => _withConn(
        connectionId,
        (conn) => callWithBuffer(
          (buf, bufLen, outWritten) => _bindings.odbc_catalog_tables(
            conn,
            cPtr,
            sPtr,
            buf,
            bufLen,
            outWritten,
          ),
          initialSize: initialBufferBytes,
          maxSize: maxBufferBytes,
        ),
      ),
    );
  }

  /// Queries the database catalog for column information.
  Uint8List? catalogColumns(
    int connectionId,
    String table, {
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_columns(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
        initialSize: initialBufferBytes,
        maxSize: maxBufferBytes,
      ),
    );
  }

  /// Queries the database catalog for data type information.
  Uint8List? catalogTypeInfo(
    int connectionId, {
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) {
    return callWithBuffer(
      (buf, bufLen, outWritten) => _bindings.odbc_catalog_type_info(
        connectionId,
        buf,
        bufLen,
        outWritten,
      ),
      initialSize: initialBufferBytes,
      maxSize: maxBufferBytes,
    );
  }

  /// Queries the database catalog for primary key information.
  Uint8List? catalogPrimaryKeys(
    int connectionId,
    String table, {
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_primary_keys(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
        initialSize: initialBufferBytes,
        maxSize: maxBufferBytes,
      ),
    );
  }

  /// Queries the database catalog for foreign key information.
  Uint8List? catalogForeignKeys(
    int connectionId,
    String table, {
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_foreign_keys(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
        initialSize: initialBufferBytes,
        maxSize: maxBufferBytes,
      ),
    );
  }

  /// Queries the database catalog for index information.
  Uint8List? catalogIndexes(
    int connectionId,
    String table, {
    int? initialBufferBytes,
    int? maxBufferBytes,
  }) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_indexes(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
        initialSize: initialBufferBytes,
        maxSize: maxBufferBytes,
      ),
    );
  }
}
