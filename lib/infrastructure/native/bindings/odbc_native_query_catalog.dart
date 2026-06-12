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
        ),
      ),
    );
  }

  /// Queries the database catalog for column information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query columns for.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogColumns(int connectionId, String table) {
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
      ),
    );
  }

  /// Queries the database catalog for data type information.
  ///
  /// The [connectionId] must be a valid active connection.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogTypeInfo(int connectionId) {
    return callWithBuffer(
      (buf, bufLen, outWritten) => _bindings.odbc_catalog_type_info(
        connectionId,
        buf,
        bufLen,
        outWritten,
      ),
    );
  }

  /// Queries the database catalog for primary key information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query primary keys for.
  ///
  /// Returns binary result data on success, null on failure.
  /// Result columns: TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, CONSTRAINT_NAME
  Uint8List? catalogPrimaryKeys(int connectionId, String table) {
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
      ),
    );
  }

  /// Queries the database catalog for foreign key information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query foreign keys for.
  ///
  /// Returns binary result data on success, null on failure.
  /// Result columns: CONSTRAINT_NAME, FROM_TABLE, FROM_COLUMN, TO_TABLE,
  /// TO_COLUMN, UPDATE_RULE, DELETE_RULE
  Uint8List? catalogForeignKeys(int connectionId, String table) {
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
      ),
    );
  }

  /// Queries the database catalog for index information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query indexes for.
  ///
  /// Returns binary result data on success, null on failure.
  /// Result columns: INDEX_NAME, TABLE_NAME, COLUMN_NAME, IS_UNIQUE,
  /// IS_PRIMARY, ORDINAL_POSITION
  Uint8List? catalogIndexes(int connectionId, String table) {
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
      ),
    );
  }
}
