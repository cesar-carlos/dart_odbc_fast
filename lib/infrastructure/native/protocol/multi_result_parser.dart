import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser, ParsedRowBuffer;

/// Represents an item in a multi-result set.
///
/// A multi-result query can return multiple result sets
/// followed by row counts. Each item is either a result set
/// (with columns and rows) or a row count (affected rows).
///
/// Example:
/// ```dart
/// final items = [
///   MultiResultItem(resultSet: ParsedRowBuffer(...)),
///   MultiResultItem(rowCount: 42),
/// ];
/// ```
class MultiResultItem {
  const MultiResultItem({required this.resultSet, required this.rowCount});

  /// Result set containing column metadata and row data.
  final ParsedRowBuffer? resultSet;

  /// Number of affected rows (for INSERT/UPDATE/DELETE).
  ///
  /// Null when this item represents a row count instead.
  final int? rowCount;
}

/// Parser for multi-result protocol.
///
/// Decodes binary data returned from FFI's `odbc_exec_query_multi`
/// function. The multi-result format consists of a count followed by
/// multiple items, where each item has a tag, length, and payload.
///
/// Binary format (little-endian):
/// - Bytes 0-3: Item count (u32)
/// - For each item:
///   - Byte 4: Tag (0 = ResultSet, 1 = RowCount)
///   - Bytes 5-8: Payload length (u32)
///   - Bytes 9+: Payload data
class MultiResultParser {
  /// Magic number for multi-result validation (not currently used).
  // Note: Tag value 0 is reserved for future use.

  /// Tag for result set item.
  static const int tagResultSet = 0;

  /// Tag for row count item.
  static const int tagRowCount = 1;

  /// Header size: 4 bytes for item count.
  static const int headerSize = 4;

  /// Header size for each item: 1 (tag) + 4 (length) bytes.
  static const int itemHeaderSize = 5;

  /// Parses multi-result binary data into a list of items.
  ///
  /// The [data] parameter must contain valid multi-result binary data.
  /// Returns a list of [MultiResultItem] in the order they appear.
  ///
  /// Throws [FormatException] if the buffer is malformed or contains
  /// invalid data.
  static List<MultiResultItem> parse(Uint8List data) {
    if (data.length < headerSize) {
      throw const FormatException(
        'Buffer too small for multi-result header',
      );
    }

    final byteData = ByteData.sublistView(data);
    final itemCount = byteData.getUint32(0, Endian.little);

    final items = <MultiResultItem>[];
    var offset = headerSize;

    for (var i = 0; i < itemCount; i++) {
      if (offset + itemHeaderSize > data.length) {
        throw const FormatException(
          'Multi-result buffer truncated at item header',
        );
      }

      final tag = data[offset];
      offset += 1;

      if (tag != tagResultSet && tag != tagRowCount) {
        throw FormatException('Unknown multi-result item tag: $tag');
      }

      final length = byteData.getUint32(offset, Endian.little);
      offset += 4;

      if (offset + length > data.length) {
        throw const FormatException(
          'Multi-result buffer truncated at item payload',
        );
      }

      final payload = data.sublist(offset, offset + length);

      switch (tag) {
        case tagResultSet:
          final resultSet = BinaryProtocolParser.parse(payload);
          items.add(
            MultiResultItem(resultSet: resultSet, rowCount: null),
          );

        case tagRowCount:
          if (length != 8) {
            throw const FormatException(
              'RowCount item expected 8-byte payload',
            );
          }

          final rowCount = byteData.getInt64(offset, Endian.little);
          items.add(
            MultiResultItem(resultSet: null, rowCount: rowCount),
          );

        default:
          throw FormatException('Unknown multi-result item tag: $tag');
      }

      offset += length;
    }

    return items;
  }

  /// Returns the first result set from a multi-result response.
  ///
  /// Returns the result set item, or an empty result set if none exists.
  static ParsedRowBuffer getFirstResultSet(List<MultiResultItem> items) {
    final first = items
        .where((item) => item.resultSet != null)
        .map((item) => item.resultSet!)
        .firstOrNull;
    if (first != null) {
      return first;
    }
    return const ParsedRowBuffer(
      columns: [],
      rows: [],
      rowCount: 0,
      columnCount: 0,
    );
  }
}
