import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';
import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart'
    show ParamValue, paramValuesFromObjects;

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
/// ```
class PreparedStatement {
  /// Creates a new [PreparedStatement] instance.
  ///
  /// `paramNamesForNamedExecution` when set, enables `executeNamed` with
  /// that parameter order. Use when the statement was prepared with named
  /// SQL (e.g. via `prepareStatementNamed`).
  PreparedStatement(
    this._backend,
    this._stmtId, {
    List<String>? paramNamesForNamedExecution,
  }) : _paramNamesForNamedExecution = paramNamesForNamedExecution;

  final OdbcConnectionBackend _backend;
  final int _stmtId;
  final List<String>? _paramNamesForNamedExecution;

  /// The prepared statement identifier.
  int get stmtId => _stmtId;

  /// Executes prepared statement with optional parameters.
  ///
  /// The [params] list should contain [ParamValue] instances for each
  /// parameter placeholder in prepared SQL statement, in order.
  /// Can be null if no parameters are needed.
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execute({
    List<ParamValue>? params,
    int timeoutOverrideMs = 0,
    int fetchSize = 1000,
    int? maxBufferBytes,
  }) =>
      _backend.executePrepared(
        _stmtId,
        params,
        timeoutOverrideMs,
        fetchSize,
        maxBufferBytes: maxBufferBytes,
      );

  /// Executes with named parameters.
  ///
  /// Requires `paramNamesForNamedExecution` at construction (e.g. from
  /// `prepareStatementNamed`). Converts `namedParams` to positional
  /// and delegates to `execute`. Throws `ParameterMissingException`
  /// if a required parameter is missing.
  Uint8List? executeNamed({
    required Map<String, Object?> namedParams,
    int timeoutOverrideMs = 0,
    int fetchSize = 1000,
    int? maxBufferBytes,
  }) {
    final paramNames = _paramNamesForNamedExecution;
    if (paramNames == null) {
      throw StateError(
        'executeNamed requires paramNamesForNamedExecution at construction',
      );
    }
    final positional = NamedParameterParser.toPositionalParams(
      namedParams: namedParams,
      paramNames: paramNames,
    );
    final params = paramValuesFromObjects(positional);
    return execute(
      params: params,
      timeoutOverrideMs: timeoutOverrideMs,
      fetchSize: fetchSize,
      maxBufferBytes: maxBufferBytes,
    );
  }

  /// Closes and releases a prepared statement.
  ///
  /// Should be called when the statement is no longer needed.
  void close() {
    _backend.closeStatement(_stmtId);
  }
}
