import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/services/i_query_service.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/helpers/param_value_conversion.dart';
import 'package:result_dart/result_dart.dart';

/// Typed positional helpers that convert plain Dart values to wire tags.
extension IQueryServiceTypedParamExtensions on IQueryService {
  /// Positional execute with automatic [ParamValue] conversion.
  Future<Result<QueryResult>> executeQueryParamValuesFromObjects(
    String connectionId,
    String sql,
    List<Object?> params, {
    ResultEncoding? resultEncoding,
  }) =>
      executeQueryParamValues(
        connectionId,
        sql,
        paramValuesFromObjects(params),
        resultEncoding: resultEncoding,
      );

  /// Columnar execute with automatic [ParamValue] conversion.
  Future<Result<TypedColumnarResult>> executeQueryColumnarFromObjects(
    String connectionId,
    String sql, {
    List<Object?>? params,
  }) =>
      executeQueryColumnarParamValues(
        connectionId,
        sql,
        params: params == null || params.isEmpty
            ? null
            : paramValuesFromObjects(params),
      );
}

/// Prepared and multi-result helpers on the full ODBC service contract.
extension IOdbcServiceTypedParamExtensions on IOdbcService {
  /// Prepared positional execute with automatic [ParamValue] conversion.
  Future<Result<QueryResult>> executePreparedParamValuesFromObjects(
    String connectionId,
    int stmtId,
    List<Object?>? params,
    StatementOptions? options,
  ) =>
      executePreparedParamValues(
        connectionId,
        stmtId,
        params == null || params.isEmpty
            ? null
            : paramValuesFromObjects(params),
        options,
      );

  /// Multi-result positional execute with automatic [ParamValue] conversion.
  Future<Result<QueryResultMulti>> executeQueryMultiParamValuesFromObjects(
    String connectionId,
    String sql,
    List<Object?> params,
  ) =>
      executeQueryMultiParamValues(
        connectionId,
        sql,
        paramValuesFromObjects(params),
      );
}
