import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';

/// Wrapper for database catalog queries.
///
/// Provides convenient methods to query database metadata including
/// tables, columns, and data type information.
///
/// Example:
/// ```dart
/// final catalog = CatalogQuery(backend, connectionId);
/// final tables = catalog.tables(catalog: 'MyDatabase');
/// ```
class CatalogQuery {
  /// Creates a new [CatalogQuery] instance.
  ///
  /// The backend parameter must be a valid ODBC connection backend instance.
  /// The connectionId parameter must be a valid active connection identifier.
  CatalogQuery(this._backend, this._connectionId);

  final OdbcConnectionBackend _backend;
  final int _connectionId;

  /// The connection ID used for catalog queries.
  int get connectionId => _connectionId;

  /// Queries the database catalog for table information.
  ///
  /// Returns metadata about tables in the specified [catalog] and [schema].
  /// Empty strings for [catalog] or [schema] match all values.
  /// Returns a [ParsedRowBuffer] on success, null on failure.
  ParsedRowBuffer? tables({String catalog = '', String schema = ''}) {
    final raw = _backend.catalogTables(
      _connectionId,
      catalog: catalog,
      schema: schema,
    );
    return _parse(raw);
  }

  /// Queries the database catalog for column information.
  ///
  /// Returns metadata about columns in the specified [table].
  /// Returns a [ParsedRowBuffer] on success, null on failure.
  ParsedRowBuffer? columns(String table) {
    final raw = _backend.catalogColumns(_connectionId, table);
    return _parse(raw);
  }

  /// Queries the database catalog for data type information.
  ///
  /// Returns metadata about data types supported by the database.
  /// Returns a [ParsedRowBuffer] on success, null on failure.
  ParsedRowBuffer? typeInfo() {
    final raw = _backend.catalogTypeInfo(_connectionId);
    return _parse(raw);
  }

  static ParsedRowBuffer? _parse(Uint8List? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return BinaryProtocolParser.parse(raw);
    } on FormatException {
      return null;
    }
  }
}
