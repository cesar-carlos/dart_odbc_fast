import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart'
    show MultiResultItem, MultiResultItemResultSet, MultiResultItemRowCount;
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';

/// Coalesces streaming multi-result frames into one logical item per SQL
/// cursor.
///
/// Wire tag 0 opens a result set; tag 2 (continuation batch) appends rows
/// into the open set; tag 1 flushes the open set (if any) then yields a
/// row-count. Mapping to domain result sets happens once per closed cursor.
class MultiStreamCoalescer {
  MultiStreamCoalescer(this._parser);

  final OdbcResultParser _parser;

  /// Column metadata / shape for the open cursor (rows live in [_openRows]).
  ParsedRowBuffer? _openMeta;
  List<List<dynamic>>? _openRows;
  int _openRowCount = 0;

  /// Consumes decoded wire items and returns domain items ready to yield.
  List<QueryResultMultiItem> take(Iterable<MultiResultItem> items) {
    final out = <QueryResultMultiItem>[];
    for (final item in items) {
      switch (item) {
        case MultiResultItemResultSet(
            :final value,
            :final isContinuationBatch,
          ):
          if (isContinuationBatch && _openMeta != null) {
            _appendContinuation(value);
          } else {
            final flushed = _flushOpen();
            if (flushed != null) {
              out.add(flushed);
            }
            _openCursor(value);
          }
        case MultiResultItemRowCount(:final value):
          final flushed = _flushOpen();
          if (flushed != null) {
            out.add(flushed);
          }
          out.add(QueryResultMultiItem.rowCount(value));
      }
    }
    return out;
  }

  /// Yields any result set still open after end-of-stream.
  List<QueryResultMultiItem> finish() {
    final flushed = _flushOpen();
    if (flushed == null) {
      return const <QueryResultMultiItem>[];
    }
    return <QueryResultMultiItem>[flushed];
  }

  void _openCursor(ParsedRowBuffer value) {
    // Take ownership of the row list for tag-2 continuations. Stream parsers
    // hand growable outer lists; callers must not retain [value.rows] for
    // mutation after this transfer.
    final rows = value.rows;
    _openRows = rows;
    _openRowCount = value.rowCount;
    _openMeta = ParsedRowBuffer(
      columns: value.columns,
      rows: rows,
      rowCount: value.rowCount,
      columnCount: value.columnCount,
    );
  }

  void _appendContinuation(ParsedRowBuffer next) {
    final rows = _openRows;
    if (rows == null) {
      _openCursor(next);
      return;
    }
    rows.addAll(next.rows);
    _openRowCount += next.rowCount;
  }

  QueryResultMultiItem? _flushOpen() {
    final open = _openMeta;
    final rows = _openRows;
    if (open == null || rows == null) {
      return null;
    }
    final buffer = ParsedRowBuffer(
      columns: open.columns,
      rows: rows,
      rowCount: _openRowCount,
      columnCount: open.columnCount,
    );
    _openMeta = null;
    _openRows = null;
    _openRowCount = 0;
    return QueryResultMultiItem.resultSet(_parser.toQueryResult(buffer));
  }
}
