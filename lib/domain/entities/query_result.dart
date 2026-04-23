/// Represents the result of a SQL query execution.
///
/// Contains the column names, row data, and row count. Each row is a list
/// of dynamic values corresponding to the columns in the same order.
///
/// Example:
/// ```dart
/// final result = QueryResult(
///   columns: ['id', 'name', 'age'],
///   rows: [
///     [1, 'Alice', 30],
///     [2, 'Bob', 25],
///   ],
///   rowCount: 2,
/// );
/// ```
class QueryResult {
  /// Creates a new [QueryResult] instance.
  ///
  /// The [columns] list must match the order of values in each row of [rows].
  /// The [rowCount] should equal the length of [rows].
  const QueryResult({
    required this.columns,
    required this.rows,
    required this.rowCount,
    this.outputParamValues = const <dynamic>[],
  });

  /// Column names in the order they appear in the query result.
  final List<String> columns;

  /// Row data as a list of lists, where each inner list represents one row.
  ///
  /// Each row's values correspond to [columns] in the same order.
  final List<List<dynamic>> rows;

  /// Total number of rows in the result set.
  final int rowCount;

  /// Values for `OUT` / `INOUT` parameters, when a directed (DRT1) execute
  /// is used and the engine appends the `OUT1` footer. Empty when the query
  /// used only `INPUT` parameters or a legacy v0 parameter buffer. Entries
  /// are typically the sealed `ParamValue` types from the package’s
  /// `param_value` protocol in the same order as the corresponding
  /// placeholders.
  final List<dynamic> outputParamValues;

  /// True when [outputParamValues] is non-empty.
  bool get hasOutputParamValues => outputParamValues.isNotEmpty;

  /// Returns true if the result set contains no rows.
  bool get isEmpty => rowCount == 0;

  /// Returns true if the result set contains at least one row.
  bool get isNotEmpty => rowCount > 0;
}
