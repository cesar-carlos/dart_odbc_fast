import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

abstract class OdbcConnectionBackend {
  bool commitTransaction(int txnId);
  bool rollbackTransaction(int txnId);
  Uint8List? executePrepared(int stmtId, [List<ParamValue>? params]);
  bool closeStatement(int stmtId);
  Uint8List? catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  });
  Uint8List? catalogColumns(int connectionId, String table);
  Uint8List? catalogTypeInfo(int connectionId);
  int poolGetConnection(int poolId);
  bool poolReleaseConnection(int connectionId);
  bool poolHealthCheck(int poolId);
  ({int size, int idle})? poolGetState(int poolId);
  bool poolClose(int poolId);
}
