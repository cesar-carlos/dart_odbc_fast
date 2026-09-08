import 'package:odbc_fast/domain/entities/query_result.dart';

/// Represents a full multi-result response preserving item order.
///
/// A multi-result query can return interleaved result sets and row counts.
/// This type keeps that sequence intact while exposing convenience getters.
class QueryResultMulti {
  /// Creates a new [QueryResultMulti] instance.
  const QueryResultMulti({
    required this.items,
  });

  /// Ordered items as returned by the database.
  final List<QueryResultMultiItem> items;

  /// Returns true when there are no items.
  bool get isEmpty => items.isEmpty;

  /// Returns true when there is at least one item.
  bool get isNotEmpty => items.isNotEmpty;

  /// Returns all result sets, preserving their relative order.
  List<QueryResult> get resultSets => items
      .where((item) => item.resultSet != null)
      .map((item) => item.resultSet!)
      .toList(growable: false);

  /// Returns all row counts, preserving their relative order.
  List<int> get rowCounts => items
      .where((item) => item.rowCount != null)
      .map((item) => item.rowCount!)
      .toList(growable: false);

  /// Returns the first result set, or `null` when the batch produced no
  /// cursors (e.g. INSERT-only batch).
  QueryResult? get firstResultSetOrNull {
    for (final item in items) {
      final set = item.resultSet;
      if (set != null) {
        return set;
      }
    }
    return null;
  }
}

/// One item in a multi-result response.
///
/// An item is either a [resultSet] or a [rowCount].
class QueryResultMultiItem {
  /// Creates a result-set item.
  const QueryResultMultiItem.resultSet(this.resultSet) : rowCount = null;

  /// Creates a row-count item.
  const QueryResultMultiItem.rowCount(this.rowCount) : resultSet = null;

  /// Result set payload, when this item is a result-set item.
  final QueryResult? resultSet;

  /// Affected rows payload, when this item is a row-count item.
  final int? rowCount;

  /// Returns true if this item is a result set.
  bool get isResultSet => resultSet != null;

  /// Returns true if this item is a row count.
  bool get isRowCount => rowCount != null;
}

/// One fetch batch from a streaming multi-result query.
///
/// Unlike [QueryResultMultiItem], a result-set item here represents only the
/// rows from one native fetch batch. This keeps consumption bounded by the
/// configured fetch size. [isContinuationBatch] identifies batches after the
/// first one for the same SQL cursor.
class QueryResultMultiBatchItem {
  /// Creates a result-set batch.
  const QueryResultMultiBatchItem.resultSet(
    this.resultSet, {
    this.isContinuationBatch = false,
  }) : rowCount = null;

  /// Creates an affected-row-count item.
  const QueryResultMultiBatchItem.rowCount(this.rowCount)
      : resultSet = null,
        isContinuationBatch = false;

  /// Rows decoded for this fetch batch, when the item represents a cursor.
  final QueryResult? resultSet;

  /// Affected rows, when the item represents a DML result.
  final int? rowCount;

  /// Whether this result-set batch continues the preceding cursor.
  final bool isContinuationBatch;

  /// Returns true when this item contains a result-set batch.
  bool get isResultSet => resultSet != null;

  /// Returns true when this item contains a row count.
  bool get isRowCount => rowCount != null;
}
