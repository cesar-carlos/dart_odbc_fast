import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('BinaryProtocolParser', () {
    test('should validate magic number', () {
      final invalidBuffer = Uint8List(16);
      expect(
        () => BinaryProtocolParser.parse(invalidBuffer),
        throwsFormatException,
      );
    });

    test('should parse simple buffer with one column and one row', () {
      final buffer = _createTestBuffer(
        columns: [
          (name: 'id', type: 2),
        ],
        rows: [
          [1],
        ],
      );

      final result = BinaryProtocolParser.parse(buffer);

      expect(result.columnCount, equals(1));
      expect(result.rowCount, equals(1));
      expect(result.columns[0].name, equals('id'));
      expect(result.columns[0].odbcType, equals(2));
      expect(result.rows[0][0], equals(1));
    });

    test('should handle null values', () {
      final buffer = _createTestBuffer(
        columns: [
          (name: 'value', type: 1),
        ],
        rows: [
          [null],
        ],
      );

      final result = BinaryProtocolParser.parse(buffer);

      expect(result.rows[0][0], isNull);
    });

    test('should parse multiple columns and rows', () {
      final buffer = _createTestBuffer(
        columns: [
          (name: 'id', type: 2),
          (name: 'name', type: 1),
        ],
        rows: [
          [1, 'Alice'],
          [2, 'Bob'],
        ],
      );

      final result = BinaryProtocolParser.parse(buffer);

      expect(result.columnCount, equals(2));
      expect(result.rowCount, equals(2));
      expect(result.rows[0][0], equals(1));
      expect(result.rows[0][1], equals('Alice'));
      expect(result.rows[1][0], equals(2));
      expect(result.rows[1][1], equals('Bob'));
    });
  });

  /// Regression coverage for issue #1 — Chinese (and CJK in general)
  /// character handling. The Rust engine reads text columns as
  /// `SQL_C_WCHAR` and emits UTF-8 bytes, so the Dart decoder must round-
  /// trip valid UTF-8 verbatim and **must not** silently re-interpret
  /// invalid bytes as Latin-1 (the historical bug).
  ///
  /// See `_decodeText` in `binary_protocol.dart` for the contract.
  group('BinaryProtocolParser CJK / encoding regression (#1)', () {
    test('round-trips valid UTF-8 Chinese characters (NVARCHAR path)', () {
      // "管理员" — the exact sequence cited in issue #1.
      const original = '管理员';
      final utf8Bytes = utf8.encode(original);
      // Sanity-check the corpus matches what SQL Server would deliver
      // through SQL_C_WCHAR transcoding (UTF-8 of "管理员").
      expect(
        utf8Bytes,
        equals([0xE7, 0xAE, 0xA1, 0xE7, 0x90, 0x86, 0xE5, 0x91, 0x98]),
      );

      final buffer = _createTestBuffer(
        columns: [(name: 'employee_name', type: 8)],
        rows: [
          [utf8Bytes],
        ],
      );

      final result = BinaryProtocolParser.parse(buffer);
      expect(result.rows[0][0], equals(original));
    });

    test('round-trips mixed CJK + ASCII JSON payloads', () {
      const original = '{"name":"管理员","role":"admin","emoji":"🚀"}';
      final buffer = _createTestBuffer(
        columns: [(name: 'payload', type: 16)],
        rows: [
          [utf8.encode(original)],
        ],
      );

      final result = BinaryProtocolParser.parse(buffer);
      expect(result.rows[0][0], equals(original));
      expect(
        jsonDecode(result.rows[0][0] as String),
        isA<Map<String, dynamic>>(),
      );
    });

    test(
      'replaces invalid UTF-8 with U+FFFD instead of falling back to Latin-1 '
      '(no more silent "¹ÜÀíÔ±" mojibake)',
      () {
        // Raw GBK bytes for "管理员", which is exactly the byte stream
        // reported in issue #1 when the upstream driver was misconfigured.
        // These bytes are NOT valid UTF-8 and the parser must surface
        // that — never silently cast them to Latin-1.
        final gbkBytes = <int>[0xB9, 0xDC, 0xC0, 0xED, 0xD4, 0xB1];
        final buffer = _createTestBuffer(
          columns: [(name: 'name', type: 8)],
          rows: [
            [gbkBytes],
          ],
        );

        final result = BinaryProtocolParser.parse(buffer);
        final decoded = result.rows[0][0]! as String;

        // The legacy Latin-1 fallback would have produced "¹ÜÀíÔ±".
        // The new contract is: bytes survive as the replacement
        // character so the breakage is loud and observable.
        expect(
          decoded,
          isNot(equals('¹ÜÀíÔ±')),
          reason: 'Latin-1 fallback regressed; '
              'this is exactly the bug from issue #1',
        );
        expect(
          decoded.contains('\uFFFD'),
          isTrue,
          reason: 'invalid UTF-8 must surface as the replacement character',
        );
        // Defensive: no codepoint should match a "plausible" Latin-1
        // glyph in the printable Western range (0xA0..0xFF), otherwise
        // the silent fallback regressed. U+FFFD (0xFFFD) is fine.
        expect(
          decoded.codeUnits
              .where((c) => c != 0xFFFD)
              .any((c) => c >= 0xA0 && c <= 0xFF),
          isFalse,
          reason: 'no Latin-1 mojibake codepoints must leak through',
        );
      },
    );

    test('survives partial UTF-8 truncation mid-codepoint', () {
      // Take "管" (E7 AE A1) and drop the trailing byte. The remaining
      // [E7, AE] is an incomplete UTF-8 sequence — must not throw.
      final partial = <int>[0xE7, 0xAE];
      final buffer = _createTestBuffer(
        columns: [(name: 'name', type: 1)],
        rows: [
          [partial],
        ],
      );

      expect(
        () => BinaryProtocolParser.parse(buffer),
        returnsNormally,
        reason: 'truncated UTF-8 must not crash the decoder',
      );
      final decoded = BinaryProtocolParser.parse(buffer).rows[0][0]! as String;
      expect(decoded, contains('\uFFFD'));
    });
  });
}

Uint8List _createTestBuffer({
  required List<({String name, int type})> columns,
  required List<List<dynamic>> rows,
}) {
  final buffer = <int>[];

  const magic = 0x4F444243;
  const version = 1;

  buffer
    ..addAll(magic.toBytes(4))
    ..addAll(version.toBytes(2))
    ..addAll(columns.length.toBytes(2))
    ..addAll(rows.length.toBytes(4));

  var payloadSize = 0;
  for (final col in columns) {
    payloadSize += 2 + 2 + col.name.length;
  }
  for (final row in rows) {
    for (final cell in row) {
      payloadSize += 1;
      if (cell != null) {
        final data = _cellToBytes(cell);
        payloadSize += 4 + data.length;
      }
    }
  }

  buffer.addAll(payloadSize.toBytes(4));

  for (final col in columns) {
    buffer
      ..addAll(col.type.toBytes(2))
      ..addAll(col.name.length.toBytes(2))
      ..addAll(col.name.codeUnits);
  }

  for (final row in rows) {
    for (final cell in row) {
      if (cell == null) {
        buffer.add(1);
      } else {
        buffer.add(0);
        final data = _cellToBytes(cell);
        buffer
          ..addAll(data.length.toBytes(4))
          ..addAll(data);
      }
    }
  }

  return Uint8List.fromList(buffer);
}

List<int> _cellToBytes(dynamic cell) {
  if (cell is int) {
    return cell.toBytes(4);
  } else if (cell is String) {
    return cell.codeUnits;
  } else if (cell is List<int>) {
    return cell;
  }
  return [];
}

extension IntBytes on int {
  List<int> toBytes(int length) {
    final bytes = <int>[];
    for (var i = 0; i < length; i++) {
      bytes.add((this >> (i * 8)) & 0xFF);
    }
    return bytes;
  }
}
