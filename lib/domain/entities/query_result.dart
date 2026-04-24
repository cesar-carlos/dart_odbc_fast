/// One item from a multi-result directed response.
///
/// Callers should pattern-match on the concrete sub-type:
///
/// ```dart
/// for (final item in result.additionalResults) {
///   switch (item) {
///     case DirectedResultItem(:final columns, :final rows, :final rowCount):
///       print('rows=$rowCount');
///     case DirectedRowCountItem(:final rowCount):
///       print('affected=$rowCount');
///   }
/// }
/// ```
sealed class DirectedMultiItem {
  const DirectedMultiItem();
}

/// A result-set item (cursor) from a directed multi-result response.
final class DirectedResultItem extends DirectedMultiItem {
  const DirectedResultItem({
    required this.columns,
    required this.rows,
    required this.rowCount,
  });
  final List<String> columns;
  final List<List<dynamic>> rows;
  final int rowCount;
}

/// A row-count item (DML) from a directed multi-result response.
final class DirectedRowCountItem extends DirectedMultiItem {
  const DirectedRowCountItem(this.rowCount);
  final int rowCount;
}

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
    this.refCursorResults = const <QueryResult>[],
    this.additionalResults = const <DirectedMultiItem>[],
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
  /// are typically the sealed `ParamValue` types from the package's
  /// `param_value` protocol — **scalar** `OUT`/`INOUT` only (no
  /// `ParamValueRefCursorOut`); see `doc/notes/TYPE_MAPPING.md` §3.1.1.
  final List<dynamic> outputParamValues;

  /// When the native `RC1\0` trailer is present, each entry is a full result
  /// set materialized from a `SYS_REFCURSOR` (or similar) `OUT` parameter.
  final List<QueryResult> refCursorResults;

  /// Additional result sets and row-counts returned by a directed OUT call
  /// when the stored procedure / batch produced more than one ODBC result after
  /// `SQLMoreResults` (the `MULT` envelope path).
  ///
  /// The first result set from the engine is always mapped to [columns] /
  /// [rows] / [rowCount] so single-result callers require no changes. Items
  /// here represent the *tail* of the multi-result sequence (index 1 onward).
  /// Empty for procedures that return a single result set (the common case).
  final List<DirectedMultiItem> additionalResults;

  /// True when [outputParamValues] is non-empty.
  bool get hasOutputParamValues => outputParamValues.isNotEmpty;

  /// True when [refCursorResults] is non-empty.
  bool get hasRefCursorResults => refCursorResults.isNotEmpty;

  /// True when [additionalResults] is non-empty.
  bool get hasAdditionalResults => additionalResults.isNotEmpty;

  /// Returns true if the result set contains no rows.
  bool get isEmpty => rowCount == 0;

  /// Returns true if the result set contains at least one row.
  bool get isNotEmpty => rowCount > 0;
}
