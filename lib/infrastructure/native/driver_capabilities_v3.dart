// v3.0 driver-specific capabilities exposed to Dart.
//
// This file complements `driver_capabilities.dart` (which deals with
// detection / DBMS info). It adds typed wrappers over the new FFI:
//
// - `OdbcUpsert.buildSql`            — `odbc_build_upsert_sql`
// - `OdbcReturning.appendClause`     — `odbc_append_returning_sql`
// - `OdbcSession.getInitStatements`  — `odbc_get_session_init_sql`

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_bindings.dart'
    as bindings;
import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';

/// Backend contract used by [OdbcDriverFeatures].
abstract interface class OdbcDriverFeatureBackend {
  bool get supportsApi;

  Uint8List? buildUpsertSql(
    String connectionString,
    String table,
    String payloadJson,
  );

  Uint8List? appendReturningClause(
    String connectionString,
    String sql,
    int verbCode,
    String columnsCsv,
  );

  Uint8List? getSessionInitSql(String connectionString, String? optionsJson);
}

final class _NativeOdbcDriverFeatureBackend
    implements OdbcDriverFeatureBackend {
  _NativeOdbcDriverFeatureBackend(this._native);

  final OdbcNative _native;

  @override
  bool get supportsApi => _native.rawBindings.supportsCapabilitiesApi;

  @override
  Uint8List? buildUpsertSql(
    String connectionString,
    String table,
    String payloadJson,
  ) {
    final connPtr = connectionString.toNativeUtf8();
    final tablePtr = table.toNativeUtf8();
    final payloadPtr = payloadJson.toNativeUtf8();
    try {
      return _native.execWithBuffer(
        (buf, bufLen, outWritten) => _native.rawBindings.odbc_build_upsert_sql(
          connPtr.cast<bindings.Utf8>(),
          tablePtr.cast<bindings.Utf8>(),
          payloadPtr.cast<bindings.Utf8>(),
          buf,
          bufLen,
          outWritten,
        ),
      );
    } finally {
      malloc
        ..free(connPtr)
        ..free(tablePtr)
        ..free(payloadPtr);
    }
  }

  @override
  Uint8List? appendReturningClause(
    String connectionString,
    String sql,
    int verbCode,
    String columnsCsv,
  ) {
    final connPtr = connectionString.toNativeUtf8();
    final sqlPtr = sql.toNativeUtf8();
    final colsPtr = columnsCsv.toNativeUtf8();
    try {
      return _native.execWithBuffer(
        (buf, bufLen, outWritten) =>
            _native.rawBindings.odbc_append_returning_sql(
          connPtr.cast<bindings.Utf8>(),
          sqlPtr.cast<bindings.Utf8>(),
          verbCode,
          colsPtr.cast<bindings.Utf8>(),
          buf,
          bufLen,
          outWritten,
        ),
      );
    } finally {
      malloc
        ..free(connPtr)
        ..free(sqlPtr)
        ..free(colsPtr);
    }
  }

  @override
  Uint8List? getSessionInitSql(String connectionString, String? optionsJson) {
    final connPtr = connectionString.toNativeUtf8();
    final optsPtr = optionsJson == null
        ? ffi.Pointer<bindings.Utf8>.fromAddress(0)
        : optionsJson.toNativeUtf8().cast<bindings.Utf8>();
    try {
      return _native.execWithBuffer(
        (buf, bufLen, outWritten) =>
            _native.rawBindings.odbc_get_session_init_sql(
          connPtr.cast<bindings.Utf8>(),
          optsPtr,
          buf,
          bufLen,
          outWritten,
        ),
      );
    } finally {
      malloc.free(connPtr);
      if (optionsJson != null) {
        malloc.free(optsPtr.cast<Utf8>());
      }
    }
  }
}

/// DML category used by [OdbcDriverFeatures.appendReturningClause] to
/// position the dialect-specific OUTPUT/RETURNING clause.
enum DmlVerb {
  insert(0),
  update(1),
  delete(2);

  const DmlVerb(this.code);
  final int code;
}

/// Per-driver session initialization options. Mirror of the Rust
/// `SessionOptions` struct — every field is optional; `null`/empty means
/// "do not touch this setting".
class SessionOptions {
  const SessionOptions({
    this.applicationName,
    this.timezone,
    this.charset,
    this.schema,
    this.extraSql = const <String>[],
  });

  final String? applicationName;
  final String? timezone;
  final String? charset;
  final String? schema;
  final List<String> extraSql;

  Map<String, Object?> toJson() => <String, Object?>{
        if (applicationName != null) 'application_name': applicationName,
        if (timezone != null) 'timezone': timezone,
        if (charset != null) 'charset': charset,
        if (schema != null) 'schema': schema,
        if (extraSql.isNotEmpty) 'extra_sql': extraSql,
      };
}

/// Typed wrapper for the v3.0 capability FFIs.
class OdbcDriverFeatures {
  OdbcDriverFeatures(OdbcNative native)
      : _backend = _NativeOdbcDriverFeatureBackend(native);

  OdbcDriverFeatures.withBackend(this._backend);

  final OdbcDriverFeatureBackend _backend;

  /// True when the loaded native library exposes the v3.0 capability FFIs.
  bool get supportsApi => _backend.supportsApi;

  /// Build an UPSERT statement for the dialect implied by [connectionString].
  ///
  /// Returns `null` when the FFI is missing or the underlying call fails.
  /// On success returns the dialect-specific SQL (with `?` placeholders).
  String? buildUpsertSql({
    required String connectionString,
    required String table,
    required List<String> columns,
    required List<String> conflictColumns,
    List<String>? updateColumns,
  }) {
    if (!supportsApi) return null;
    final payload = <String, Object?>{
      'columns': columns,
      'conflict': conflictColumns,
      if (updateColumns != null) 'update': updateColumns,
    };
    final data = _backend.buildUpsertSql(
      connectionString,
      table,
      jsonEncode(payload),
    );
    if (data == null) return null;
    return utf8.decode(data);
  }

  /// Append a RETURNING/OUTPUT clause to [sql], using the dialect implied by
  /// [connectionString].
  ///
  /// [columns] are the result columns to project; not quoted by the caller.
  String? appendReturningClause({
    required String connectionString,
    required String sql,
    required DmlVerb verb,
    required List<String> columns,
  }) {
    if (!supportsApi) return null;
    final data = _backend.appendReturningClause(
      connectionString,
      sql,
      verb.code,
      columns.join(','),
    );
    if (data == null) return null;
    return utf8.decode(data);
  }

  /// Returns the post-connect SQL statements for the dialect implied by
  /// [connectionString], customised by [options].
  ///
  /// The returned list is empty when the dialect has no specific setup.
  List<String>? getSessionInitSql({
    required String connectionString,
    SessionOptions? options,
  }) {
    if (!supportsApi) return null;
    final data = _backend.getSessionInitSql(
      connectionString,
      options == null ? null : jsonEncode(options.toJson()),
    );
    if (data == null) return null;
    final dynamic decoded = jsonDecode(utf8.decode(data));
    if (decoded is! List) return <String>[];
    return decoded.cast<String>();
  }
}
