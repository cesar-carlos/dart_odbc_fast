import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
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

    test('should parse row-major data from non-zero Uint8List view offset', () {
      final buffer = _createTestBuffer(
        columns: [
          (name: 'id', type: 2),
          (name: 'name', type: 1),
        ],
        rows: [
          [42, 'Alice'],
        ],
      );
      final padded = Uint8List.fromList([0xAA, 0xBB, ...buffer, 0xCC]);
      final view = Uint8List.sublistView(padded, 2, padded.length - 1);

      final result = BinaryProtocolParser.parse(view);

      expect(result.columnNames, equals(['id', 'name']));
      expect(result.rows.single, equals([42, 'Alice']));
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

    test('v1 with OUT1 footer recovers output ParamValues', () {
      var buffer = _createTestBuffer(
        columns: const [
          (name: 'a', type: 2),
        ],
        rows: const [
          [1],
        ],
      );
      final out = <int>[
        // Same as [BinaryProtocolParser.outputFooterMagic] / `b"OUT1"` (LE u32)
        ...0x3154554F.toBytes(4),
        ...1.toBytes(4),
        ...const ParamValueInt32(99).serialize(),
      ];
      buffer = Uint8List.fromList([...buffer, ...out]);

      final msg = BinaryProtocolParser.parseWithOutputs(buffer);
      expect(msg.outputParamValues.length, 1);
      expect(msg.outputParamValues[0], isA<ParamValueInt32>());
      expect(
        (msg.outputParamValues[0] as ParamValueInt32).value,
        99,
      );
      expect(msg.rowBuffer.rowCount, 1);
    });

    test('RC1 trailer parses one embedded v1 result', () {
      final main = _createTestBuffer(
        columns: const [
          (name: 'm', type: 2),
        ],
        rows: const [
          [0],
        ],
      );
      final inner = _createTestBuffer(
        columns: const [
          (name: 'c', type: 2),
        ],
        rows: const [
          [7],
        ],
      );
      final b = <int>[
        ...main,
        ...0x00314352.toBytes(4),
        ...1.toBytes(4),
        ...inner.length.toBytes(4),
        ...inner,
      ];
      final p = BinaryProtocolParser.parseWithOutputs(Uint8List.fromList(b));
      expect(p.refCursorRowBuffers.length, 1);
      expect(p.refCursorRowBuffers[0].rowCount, 1);
      expect(p.refCursorRowBuffers[0].rows[0][0], 7);
    });

    test('columnar v2 single column int round-trips', () {
      final b = <int>[];
      void u16(int v) {
        b.addAll(v.toBytes(2));
      }

      void u32(int v) {
        b.addAll(v.toBytes(4));
      }

      u32(0x4F444243);
      u16(2);
      u16(0);
      u16(1);
      u32(1);
      b.add(0);
      u32(0);
      final payloadAt = b.length;
      u16(2);
      u16(1);
      b
        ..add('n'.codeUnitAt(0))
        ..add(0);
      u32(5);
      b
        ..add(0)
        ..addAll(42.toBytes(4));
      final pay = b.length - payloadAt;
      b[15] = pay & 0xff;
      b[16] = (pay >> 8) & 0xff;
      b[17] = (pay >> 16) & 0xff;
      b[18] = (pay >> 24) & 0xff;
      final data = Uint8List.fromList(b);
      final p = BinaryProtocolParser.parseWithOutputs(data);
      expect(p.rowBuffer.rowCount, 1);
      expect(p.rowBuffer.columnCount, 1);
      expect(p.rowBuffer.rows[0][0], 42);
    });

    test('columnar v2 multiple columns fill row-major output directly', () {
      final data = _createColumnarV2Buffer(
        columns: const [
          (name: 'id', type: 2),
          (name: 'name', type: 1),
          (name: 'count', type: 3),
        ],
        rows: [
          [1, 'Alice', 10000000000],
          [2, null, 20000000000],
          [3, 'Carol', null],
        ],
      );

      final parsed = BinaryProtocolParser.parse(data);

      expect(parsed.columnCount, equals(3));
      expect(parsed.rowCount, equals(3));
      expect(parsed.rows, [
        [1, 'Alice', 10000000000],
        [2, null, 20000000000],
        [3, 'Carol', null],
      ]);
    });

    test('parseColumnarToTyped matches toTypedColumnar for columnar v2', () {
      final data = _createColumnarV2Buffer(
        columns: const [
          (name: 'id', type: 2),
          (name: 'name', type: 1),
          (name: 'count', type: 3),
        ],
        rows: [
          [1, 'Alice', 10000000000],
          [2, null, 20000000000],
          [3, 'Carol', null],
        ],
      );

      final typed = BinaryProtocolParser.parseColumnarToTyped(data);
      final rowMajor = BinaryProtocolParser.parse(data);
      final viaRows = toTypedColumnar(
        QueryResult(
          columns: rowMajor.columnNames,
          rows: rowMajor.rows,
          rowCount: rowMajor.rowCount,
        ),
      );

      expect(typed.rowCount, equals(viaRows.rowCount));
      expect(typed.columnCount, equals(viaRows.columnCount));
      expect(
        typed.column<TypedColumnInt32>('id').values,
        orderedEquals(viaRows.column<TypedColumnInt32>('id').values),
      );
      expect(
        typed.column<TypedColumnObject<String>>('name').values,
        orderedEquals(viaRows.column<TypedColumnObject<String>>('name').values),
      );
      expect(
        typed.column<TypedColumnInt64>('count').values,
        orderedEquals(viaRows.column<TypedColumnInt64>('count').values),
      );
    });

    test('columnar v2 binary cells decode as Uint8List', () {
      final data = _createColumnarV2Buffer(
        columns: const [
          (name: 'payload', type: 7),
        ],
        rows: [
          [
            [0x01, 0x02, 0x03],
          ],
          [null],
        ],
      );

      final parsed = BinaryProtocolParser.parse(data);

      expect(parsed.rows[0][0], isA<Uint8List>());
      expect(parsed.rows[0][0], equals([0x01, 0x02, 0x03]));
      expect(parsed.rows[1][0], isNull);
    });

    test('parseColumnarToTyped coerces UTF-8 timestamp cells to DateTime', () {
      final data = _createColumnarV2Buffer(
        columns: const [
          (name: 'created_at', type: 6),
          (name: 'day', type: 5),
        ],
        rows: [
          ['2024-06-15 14:30:00.123', '2024-06-15'],
          [null, '2020-01-01'],
        ],
      );

      final typed = BinaryProtocolParser.parseColumnarToTyped(data);
      final ts = typed.column<TypedColumnObject<DateTime>>('created_at');
      expect(ts.values[0], DateTime.parse('2024-06-15T14:30:00.123'));
      expect(ts.values[1], isNull);
      final day = typed.column<TypedColumnObject<DateTime>>('day');
      expect(day.values[0], DateTime.parse('2024-06-15'));
      expect(day.values[1], DateTime.parse('2020-01-01'));
    });

    test('parseColumnarToTyped skips row-major intermediate for int column',
        () {
      final data = _createColumnarV2Buffer(
        columns: const [
          (name: 'id', type: 2),
          (name: 'name', type: 1),
        ],
        rows: [
          [1, 'Alice'],
          [2, null],
        ],
      );

      final typed = BinaryProtocolParser.parseColumnarToTyped(data);

      expect(typed.rowCount, 2);
      expect(typed.columnCount, 2);
      final idCol = typed.column<TypedColumnInt32>('id');
      expect(idCol.values, Int32List.fromList([1, 2]));
      expect(idCol.isNullAt(1), isFalse);
      final nameCol = typed.column<TypedColumnObject<String>>('name');
      expect(nameCol.values[0], 'Alice');
      expect(nameCol.values[1], isNull);
    });

    test('parseColumnarToTyped preserves LazyString when lazyStrings is true',
        () {
      final data = _createColumnarV2Buffer(
        columns: const [
          (name: 'name', type: 1),
        ],
        rows: [
          ['Bob'],
        ],
      );

      final typed = BinaryProtocolParser.parseColumnarToTyped(
        data,
        lazyStrings: true,
      );

      final nameCell =
          typed.column<TypedColumnObject<Object>>('name').values.single!;
      expect(nameCell, isA<LazyString>());
      final lazy = nameCell as LazyString;
      expect(lazy.isDecoded, isFalse);
      expect(lazy.value, 'Bob');
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

  group('BinaryProtocolParser DoS guard', () {
    test('should_reject_v1_buffer_with_oversized_rowCount', () {
      // Build a tiny v1 buffer header whose declared rowCount is huge.
      final buf = Uint8List(20);
      final bd = ByteData.sublistView(buf)
        ..setUint32(0, BinaryProtocolParser.magic, Endian.little)
        ..setUint16(
          4,
          BinaryProtocolParser.protocolVersionRowMajor,
          Endian.little,
        )
        ..setUint16(6, 1, Endian.little) // columnCount = 1
        ..setUint32(8, 1 << 30, Endian.little) // rowCount = 1G
        ..setUint32(12, 0, Endian.little);
      // Just assign to silence unused warning — bd is used by setters above.
      expect(bd, isNotNull);

      expect(
        () => BinaryProtocolParser.parse(buf),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            anyOf(contains('oversized'), contains('inconsistent')),
          ),
        ),
      );
    });

    test('should_reject_v1_buffer_with_oversized_columnCount', () {
      final buf = Uint8List(20);
      ByteData.sublistView(buf)
        ..setUint32(0, BinaryProtocolParser.magic, Endian.little)
        ..setUint16(
          4,
          BinaryProtocolParser.protocolVersionRowMajor,
          Endian.little,
        )
        ..setUint16(6, 0xFFFF, Endian.little) // columnCount = 65535
        ..setUint32(8, 0, Endian.little)
        ..setUint32(12, 0, Endian.little);

      expect(
        () => BinaryProtocolParser.parse(buf),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('BinaryProtocolParser lazyStrings flag', () {
    test('default is eager — text cells decode to plain String', () {
      final buffer = _createTestBuffer(
        columns: [(name: 'name', type: 1)],
        rows: [
          ['Alice'],
        ],
      );
      final result = BinaryProtocolParser.parse(buffer);
      expect(result.rows[0][0], isA<String>());
      expect(result.rows[0][0], equals('Alice'));
    });

    test('lazyStrings:true wraps text cells but they still equal Strings', () {
      final buffer = _createTestBuffer(
        columns: [(name: 'name', type: 1)],
        rows: [
          ['Bob'],
        ],
      );
      final result = BinaryProtocolParser.parse(buffer, lazyStrings: true);
      // LazyString implements value-equality with String.
      expect(result.rows[0][0] == 'Bob', isTrue);
      expect(result.rows[0][0].toString(), equals('Bob'));
    });

    test('lazyStrings flag is restored after parse, even on exception', () {
      // Two consecutive parses: the second one without lazyStrings must
      // get plain Strings back (no leakage from previous call).
      final buf1 = _createTestBuffer(
        columns: [(name: 'name', type: 1)],
        rows: [
          ['First'],
        ],
      );
      BinaryProtocolParser.parse(buf1, lazyStrings: true);

      final buf2 = _createTestBuffer(
        columns: [(name: 'name', type: 1)],
        rows: [
          ['Second'],
        ],
      );
      final r2 = BinaryProtocolParser.parse(buf2);
      expect(r2.rows[0][0], isA<String>());
    });
  });
}

Uint8List _createColumnarV2Buffer({
  required List<({String name, int type})> columns,
  required List<List<dynamic>> rows,
}) {
  final payload = <int>[];
  for (var c = 0; c < columns.length; c++) {
    final column = columns[c];
    payload
      ..addAll(column.type.toBytes(2))
      ..addAll(column.name.length.toBytes(2))
      ..addAll(column.name.codeUnits)
      ..add(0);

    final raw = <int>[];
    for (final row in rows) {
      final cell = row[c];
      if (cell == null) {
        raw.add(1);
        continue;
      }
      raw.add(0);
      if (column.type == 2) {
        raw.addAll((cell as int).toBytes(4));
      } else if (column.type == 3) {
        raw.addAll((cell as int).toBytes(8));
      } else {
        final bytes = _cellToBytes(cell);
        raw
          ..addAll(bytes.length.toBytes(4))
          ..addAll(bytes);
      }
    }
    payload
      ..addAll(raw.length.toBytes(4))
      ..addAll(raw);
  }

  final buffer = <int>[
    ...BinaryProtocolParser.magic.toBytes(4),
    ...BinaryProtocolParser.protocolVersionColumnarV2.toBytes(2),
    ...0.toBytes(2),
    ...columns.length.toBytes(2),
    ...rows.length.toBytes(4),
    0,
    ...payload.length.toBytes(4),
    ...payload,
  ];

  return Uint8List.fromList(buffer);
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
