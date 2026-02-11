import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/domain/entities/prepared_statement_config.dart';

/// Wrapper for prepared statement operations.
///
/// Provides convenient methods to execute prepared statements with
/// parameters and close them when done.
///
/// Example:
/// ```dart
/// final stmt = PreparedStatement(backend, stmtId);
/// final result = stmt.execute([ParamValueString('value')]);
/// stmt.close();
/// ```class PreparedStatement {
  /// Creates a new [PreparedStatement] instance.
  ///
  /// The backend parameter must be a valid ODBC connection backend instance.
  /// The stmtId parameter must be a valid prepared statement identifier.
  PreparedStatement(this._backend, this._stmtId);

  final OdbcConnectionBackend _backend;
  final int _stmtId;

  /// The prepared statement identifier.
  int get stmtId => _stmtId;

  /// Executes the prepared statement with optional parameters.
  ///
  /// The [params] list should contain [ParamValue] instances for each
  /// parameter placeholder in the prepared SQL statement, in order.
  /// Can be null if no parameters are needed.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execute([List<ParamValue>? params]) =>
      _backend.executePrepared(_stmtId, params);

  /// Closes and releases the prepared statement.
  ///
  /// Should be called when the statement is no longer needed.
  void close() {
    _backend.closeStatement(_stmtId);
  }
}
