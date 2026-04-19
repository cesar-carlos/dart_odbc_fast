import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser, ParsedRowBuffer;

const Endian _littleEndian = Endian.little;

/// Multi-result wire-protocol magic ("MULT" little-endian).
const int multiResultMagic = 0x544C554D;

/// Multi-result wire-protocol version (current). v1 (no header) is also
/// accepted for backwards compatibility.
const int multiResultVersionV2 = 2;

// magic(4) + version(2) + reserved(2) + count(4)
const int _headerV2Len = 12;

/// One item in a multi-result response.
///
/// Sealed class hierarchy added in v3.2.0 (M3 fix). Use pattern matching to
/// distinguish the variant:
///
/// ```dart
/// for (final item in items) {
///   switch (item) {
///     case MultiResultItemResultSet(:final value):
///       print('rows=${value.rowCount}');
///     case MultiResultItemRowCount(:final value):
///       print('affected=$value');
///   }
/// }
/// ```
///
/// The legacy two-field constructor
/// (`MultiResultItem(resultSet:..., rowCount:...)`) is preserved as a
/// deprecated factory so existing code keeps compiling for one minor cycle.
sealed class MultiResultItem {
  /// Legacy constructor preserved for one minor cycle. Prefer building items
  /// via [MultiResultItemResultSet] or [MultiResultItemRowCount] directly.
  @Deprecated('Use MultiResultItemResultSet / MultiResultItemRowCount instead.')
  const factory MultiResultItem({
    required ParsedRowBuffer? resultSet,
    required int? rowCount,
  }) = _LegacyMultiResultItem;

  const MultiResultItem._();

  /// Backward-compatible accessor: returns the result set if this is a
  /// [MultiResultItemResultSet], otherwise `null`.
  ParsedRowBuffer? get resultSet => switch (this) {
        MultiResultItemResultSet(:final value) => value,
        MultiResultItemRowCount() => null,
        _LegacyMultiResultItem(:final resultSetField) => resultSetField,
      };

  /// Backward-compatible accessor: returns the row count if this is a
  /// [MultiResultItemRowCount], otherwise `null`.
  int? get rowCount => switch (this) {
        MultiResultItemResultSet() => null,
        MultiResultItemRowCount(:final value) => value,
        _LegacyMultiResultItem(:final rowCountField) => rowCountField,
      };
}

/// A `MultiResultItem` carrying a [ParsedRowBuffer] (cursor-shaped result).
final class MultiResultItemResultSet extends MultiResultItem {
  const MultiResultItemResultSet(this.value) : super._();
  final ParsedRowBuffer value;
}

/// A `MultiResultItem` carrying an `INSERT`/`UPDATE`/`DELETE` row count.
final class MultiResultItemRowCount extends MultiResultItem {
  const MultiResultItemRowCount(this.value) : super._();
  final int value;
}

/// Legacy concrete class returned by the deprecated 2-field constructor.
/// Lets old callers that did `MultiResultItem(resultSet: rs, rowCount: null)`
/// keep compiling. Internally normalises to one of the variants when read
/// back through the sealed accessors.
final class _LegacyMultiResultItem extends MultiResultItem {
  const _LegacyMultiResultItem({
    required ParsedRowBuffer? resultSet,
    required int? rowCount,
  })  : resultSetField = resultSet,
        rowCountField = rowCount,
        super._();
  final ParsedRowBuffer? resultSetField;
  final int? rowCountField;
}

/// Parser for multi-result protocol.
///
/// Decodes binary data returned by `odbc_exec_query_multi` /
/// `odbc_exec_query_multi_params`.
///
/// **Wire format v2** (current, since v3.2.0):
///
/// ```text
/// [magic: u32 LE = 0x4D554C54 ("MULT")]
/// [version: u16 LE = 2]
/// [reserved: u16 = 0]
/// [count: u32 LE]
/// for each item:
///   [tag: u8] (0 = ResultSet, 1 = RowCount)
///   [length: u32 LE]
///   [payload: length bytes]
/// ```
///
/// **Wire format v1** (legacy, still accepted):
///
/// ```text
/// [count: u32 LE]
/// for each item: ... (same as v2)
/// ```
///
/// `parse` auto-detects the framing by sniffing the first 4 bytes.
class MultiResultParser {
  /// Tag for result set item.
  static const int tagResultSet = 0;

  /// Tag for row count item.
  static const int tagRowCount = 1;

  /// Header size for the legacy v1 framing: 4 bytes for item count.
  static const int headerSize = 4;

  /// Header size for each item: 1 (tag) + 4 (length) bytes.
  static const int itemHeaderSize = 5;

  /// Parses multi-result binary data into a list of items.
  ///
  /// Auto-detects v1 (no magic) and v2 (magic + version) framings.
  ///
  /// Throws [FormatException] on malformed input or unsupported version.
  static List<MultiResultItem> parse(Uint8List data) {
    if (data.length >= 4) {
      final firstWord =
          ByteData.sublistView(data, 0, 4).getUint32(0, _littleEndian);
      if (firstWord == multiResultMagic) {
        return _parseV2(data);
      }
    }
    return _parseV1(data);
  }

  static List<MultiResultItem> _parseV1(Uint8List data) {
    if (data.length < headerSize) {
      throw const FormatException(
        'Buffer too small for multi-result header',
      );
    }
    final byteData = ByteData.sublistView(data);
    final itemCount = byteData.getUint32(0, _littleEndian);
    return _parseItems(data, byteData, headerSize, itemCount);
  }

  static List<MultiResultItem> _parseV2(Uint8List data) {
    if (data.length < _headerV2Len) {
      throw const FormatException(
        'Buffer too small for multi-result v2 header',
      );
    }
    final byteData = ByteData.sublistView(data);
    final version = byteData.getUint16(4, _littleEndian);
    if (version != multiResultVersionV2) {
      throw FormatException(
        'Unsupported multi-result version: $version '
        '(expected $multiResultVersionV2)',
      );
    }
    final itemCount = byteData.getUint32(8, _littleEndian);
    return _parseItems(data, byteData, _headerV2Len, itemCount);
  }

  static List<MultiResultItem> _parseItems(
    Uint8List data,
    ByteData byteData,
    int initialOffset,
    int itemCount,
  ) {
    final items = <MultiResultItem>[];
    var offset = initialOffset;

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

      final length = byteData.getUint32(offset, _littleEndian);
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
          items.add(MultiResultItemResultSet(resultSet));

        case tagRowCount:
          if (length != 8) {
            throw const FormatException(
              'RowCount item expected 8-byte payload',
            );
          }
          final rowCount = byteData.getInt64(offset, _littleEndian);
          items.add(MultiResultItemRowCount(rowCount));
      }

      offset += length;
    }

    return items;
  }

  /// Returns the first result set from a multi-result response, or `null`
  /// when the batch produced no cursors at all (e.g. INSERT-only batch).
  ///
  /// **Breaking change in v3.2.0 (M7 fix)** — pre-v3.2 returned a fake empty
  /// `ParsedRowBuffer` which made it impossible to distinguish "0 rows" from
  /// "no result set was produced". Callers can recover the old behaviour
  /// with `getFirstResultSet(items) ?? const ParsedRowBuffer(...)`.
  static ParsedRowBuffer? getFirstResultSet(List<MultiResultItem> items) {
    for (final item in items) {
      if (item is MultiResultItemResultSet) {
        return item.value;
      }
    }
    return null;
  }
}
