import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';

class TransactionHandle {
  TransactionHandle(this._backend, this._txnId);

  final OdbcConnectionBackend _backend;
  final int _txnId;

  int get txnId => _txnId;

  bool commit() => _backend.commitTransaction(_txnId);

  bool rollback() => _backend.rollbackTransaction(_txnId);
}
