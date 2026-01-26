import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

class PreparedStatement {
  PreparedStatement(this._backend, this._stmtId);

  final OdbcConnectionBackend _backend;
  final int _stmtId;

  int get stmtId => _stmtId;

  Uint8List? execute([List<ParamValue>? params]) =>
      _backend.executePrepared(_stmtId, params);

  void close() {
    _backend.closeStatement(_stmtId);
  }
}
