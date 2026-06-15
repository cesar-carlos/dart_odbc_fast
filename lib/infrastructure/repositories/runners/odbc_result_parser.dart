import 'dart:typed_data';

import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/entities/query_result.dart'
    show
        DirectedMultiItem,
        DirectedResultItem,
        DirectedRowCountItem,
        QueryResult;
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser, ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart'
    show
        MultiResultItem,
        MultiResultItemResultSet,
        MultiResultItemRowCount,
        MultiResultParser,
        multiResultMagic;

/// Decodes native wire buffers into domain [QueryResult] values.
class OdbcResultParser {
  const OdbcResultParser();

  QueryResult? parseBufferToQueryResult(Uint8List? buf) {
    if (buf == null) return null;
    if (buf.isEmpty) {
      return const QueryResult(
        columns: [],
        rows: [],
        rowCount: 0,
      );
    }
    try {
      if (buf.length >= 4) {
        final firstWord =
            ByteData.sublistView(buf, 0, 4).getUint32(0, Endian.little);
        if (firstWord == multiResultMagic) {
          return _parseMultiDirectedBuffer(buf);
        }
      }
      final p = BinaryProtocolParser.parseWithOutputs(buf);
      return QueryResult(
        columns: p.rowBuffer.columnNames,
        columnsMetadata: p.rowBuffer.columns,
        rows: p.rowBuffer.rows,
        rowCount: p.rowBuffer.rowCount,
        outputParamValues: p.outputParamValues,
        refCursorResults: p.refCursorRowBuffers
            .map(
              (b) => QueryResult(
                columns: b.columnNames,
                columnsMetadata: b.columns,
                rows: b.rows,
                rowCount: b.rowCount,
              ),
            )
            .toList(growable: false),
      );
    } on FormatException catch (e, st) {
      AppLogger.warning(
        'BinaryProtocolParser failed (buf len=${buf.length}): ${e.message}',
        e,
        st,
      );
      return null;
    }
  }

  /// Decodes a native buffer directly to [TypedColumnarResult] when the wire
  /// layout is columnar v2; row-major and multi-result buffers fall back to
  /// [toTypedColumnar] after row materialization.
  TypedColumnarResult? parseBufferToTypedColumnar(
    Uint8List? buf, {
    bool lazyStrings = false,
  }) {
    if (buf == null) return null;
    if (buf.isEmpty) {
      return TypedColumnarResult(columns: const [], rowCount: 0);
    }
    try {
      if (buf.length >= 4) {
        final firstWord =
            ByteData.sublistView(buf, 0, 4).getUint32(0, Endian.little);
        if (firstWord == multiResultMagic) {
          final qr = _parseMultiDirectedBuffer(buf);
          return toTypedColumnar(qr);
        }
      }
      if (BinaryProtocolParser.isColumnarV2Message(buf)) {
        return BinaryProtocolParser.parseColumnarToTyped(
          buf,
          lazyStrings: lazyStrings,
        );
      }
      final p = BinaryProtocolParser.parseWithOutputs(
        buf,
        lazyStrings: lazyStrings,
      );
      return toTypedColumnar(
        QueryResult(
          columns: p.rowBuffer.columnNames,
          columnsMetadata: p.rowBuffer.columns,
          rows: p.rowBuffer.rows,
          rowCount: p.rowBuffer.rowCount,
          outputParamValues: p.outputParamValues,
          refCursorResults: p.refCursorRowBuffers
              .map(
                (b) => QueryResult(
                  columns: b.columnNames,
                  columnsMetadata: b.columns,
                  rows: b.rows,
                  rowCount: b.rowCount,
                ),
              )
              .toList(growable: false),
        ),
      );
    } on FormatException catch (e, st) {
      AppLogger.warning(
        'BinaryProtocolParser typed columnar decode failed '
        '(buf len=${buf.length}): ${e.message}',
        e,
        st,
      );
      return null;
    }
  }

  QueryResult _parseMultiDirectedBuffer(Uint8List buf) {
    final parsed = MultiResultParser.parseMultiWithOutputs(buf);
    final items = parsed.items;
    final outputParamValues = parsed.outputParamValues;

    final firstIsResultSet =
        items.isNotEmpty && items[0] is MultiResultItemResultSet;

    var columns = const <String>[];
    var rows = const <List<dynamic>>[];
    var rowCount = 0;
    int startTailAt;

    if (firstIsResultSet) {
      final rb = (items[0] as MultiResultItemResultSet).value;
      columns = rb.columnNames;
      rows = rb.rows;
      rowCount = rb.rowCount;
      startTailAt = 1;
    } else {
      startTailAt = 0;
    }

    final additional = <DirectedMultiItem>[];
    for (var i = startTailAt; i < items.length; i++) {
      final item = items[i];
      if (item is MultiResultItemResultSet) {
        final rb = item.value;
        additional.add(
          DirectedResultItem(
            columns: rb.columnNames,
            rows: rb.rows,
            rowCount: rb.rowCount,
          ),
        );
      } else if (item is MultiResultItemRowCount) {
        additional.add(DirectedRowCountItem(item.value));
      }
    }

    return QueryResult(
      columns: columns,
      rows: rows,
      rowCount: rowCount,
      outputParamValues: outputParamValues,
      additionalResults: additional,
    );
  }

  QueryResult toQueryResult(ParsedRowBuffer buffer) {
    return QueryResult(
      columns: buffer.columnNames,
      rows: buffer.rows,
      rowCount: buffer.rowCount,
    );
  }

  QueryResultMulti toQueryResultMulti(List<MultiResultItem> items) {
    final mapped = List<QueryResultMultiItem>.generate(
      items.length,
      (i) {
        final item = items[i];
        final resultSet = item.resultSet;
        return resultSet != null
            ? QueryResultMultiItem.resultSet(toQueryResult(resultSet))
            : QueryResultMultiItem.rowCount(item.rowCount ?? 0);
      },
      growable: false,
    );
    return QueryResultMulti(items: mapped);
  }

  QueryResultMultiItem toQueryResultMultiItem(MultiResultItem item) {
    final rs = item.resultSet;
    if (rs != null) {
      return QueryResultMultiItem.resultSet(toQueryResult(rs));
    }
    return QueryResultMultiItem.rowCount(item.rowCount ?? 0);
  }
}
