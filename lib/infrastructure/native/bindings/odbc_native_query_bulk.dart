part of 'odbc_native.dart';

mixin _OdbcNativeQueryBulk on _OdbcNativeState, _OdbcNativeHelpers {
  /// Performs a bulk insert operation.
  ///
  /// Inserts multiple rows into [table] using the specified [columns].
  /// The [dataBuffer] contains the data as a binary buffer.
  /// The [rowCount] specifies how many rows are in [dataBuffer].
  ///
  /// Returns the number of rows inserted on success, -1 on failure.
  int bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) {
    final tablePtr = _sqlCache.acquire(table);
    final colPtrs = malloc<ffi.Pointer<bindings.Utf8>>(columns.length);
    try {
      for (var i = 0; i < columns.length; i++) {
        (colPtrs + i).value = _sqlCache.acquire(columns[i]);
      }
      final rowsInserted = malloc<ffi.Uint32>();
      try {
        final dataPtr = _allocUint8List(dataBuffer);
        try {
          final code = _bindings.odbc_bulk_insert_array(
            connectionId,
            tablePtr,
            colPtrs,
            columns.length,
            dataPtr,
            dataBuffer.length,
            rowCount,
            rowsInserted,
          );
          if (code != 0) return -1;
          return rowsInserted.value;
        } finally {
          malloc.free(dataPtr);
        }
      } finally {
        malloc.free(rowsInserted);
      }
    } finally {
      malloc.free(colPtrs);
    }
  }

  /// Performs a parallel bulk insert operation through [poolId].
  ///
  /// [dataBuffer] must be built using [BulkInsertBuilder.build()].
  /// Returns inserted row count on success, -1 on failure.
  int bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) {
    final tablePtr = _sqlCache.acquire(table);
    final colPtrs = malloc<ffi.Pointer<bindings.Utf8>>(columns.length);
    try {
      for (var i = 0; i < columns.length; i++) {
        (colPtrs + i).value = _sqlCache.acquire(columns[i]);
      }
      final rowsInserted = malloc<ffi.Uint32>();
      try {
        final dataPtr = _allocUint8List(dataBuffer);
        try {
          final code = _bindings.odbc_bulk_insert_parallel(
            poolId,
            tablePtr,
            colPtrs,
            columns.length,
            dataPtr,
            dataBuffer.length,
            parallelism,
            rowsInserted,
          );
          if (code != 0) return -1;
          return rowsInserted.value;
        } finally {
          malloc.free(dataPtr);
        }
      } finally {
        malloc.free(rowsInserted);
      }
    } finally {
      malloc.free(colPtrs);
    }
  }
}
