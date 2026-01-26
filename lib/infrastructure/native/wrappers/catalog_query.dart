import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';

class CatalogQuery {
  CatalogQuery(this._backend, this._connectionId);

  final OdbcConnectionBackend _backend;
  final int _connectionId;

  int get connectionId => _connectionId;

  ParsedRowBuffer? tables({String catalog = '', String schema = ''}) {
    final raw = _backend.catalogTables(
      _connectionId,
      catalog: catalog,
      schema: schema,
    );
    return _parse(raw);
  }

  ParsedRowBuffer? columns(String table) {
    final raw = _backend.catalogColumns(_connectionId, table);
    return _parse(raw);
  }

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
