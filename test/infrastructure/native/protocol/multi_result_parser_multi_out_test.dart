/// Unit tests for [MultiResultParser.parseMultiWithOutputs].
///
/// Covers:
/// - MULT envelope (v2) + OUT1 footer decode.
/// - Tail items from drain (result set, row-count) surfaced in the parsed list.
/// - Single-RS + OUT1 round-trip (the common, drain-empty path).
/// - Error cases: wrong magic, truncated buffer.
library;

import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:test/test.dart';

// ─── wire helpers ────────────────────────────────────────────────────────────

/// Minimal valid ODBC v1 buffer (0 columns, 0 rows).
Uint8List _emptyOdbcBuf() {
  final bd = ByteData(16)
    ..setUint32(0, 0x4F444243, Endian.little) // ODBC magic
    ..setUint16(4, 1, Endian.little) // version 1
    ..setUint16(6, 0, Endian.little) // 0 columns
    ..setUint32(8, 0, Endian.little) // 0 rows
    ..setUint32(12, 0, Endian.little); // payload size 0
  return bd.buffer.asUint8List();
}

List<int> _le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

List<int> _le64(int v) {
  final r = <int>[];
  for (var i = 0; i < 8; i++) {
    r.add((v >> (i * 8)) & 0xFF);
  }
  return r;
}

/// Build a MULT v2 envelope wrapping [items].
/// Each element is `(tag, payload)`:
///   - tag 0 = result-set (payload = ODBC buffer bytes)
///   - tag 1 = row-count  (payload = 8-byte i64 LE)
Uint8List _multBuf(List<(int, List<int>)> items) {
  final header = <int>[
    ..._le32(0x544C554D), // MULT magic
    0x02, 0x00, // version = 2
    0x00, 0x00, // reserved
    ..._le32(items.length), // item count
  ];
  final body = <int>[];
  for (final (tag, payload) in items) {
    body
      ..add(tag)
      ..addAll(_le32(payload.length))
      ..addAll(payload);
  }
  return Uint8List.fromList([...header, ...body]);
}

/// Build an OUT1 trailer for [values].
///
/// Wire: `b"OUT1"` LE bytes `[4F 55 54 31]` (= u32 0x3154554F),
/// then u32 count, then serialized [ParamValue] payloads.
List<int> _out1(List<ParamValue> values) {
  const magic = [0x4F, 0x55, 0x54, 0x31];
  final count = _le32(values.length);
  final payloads = values.expand((v) => v.serialize()).toList();
  return [...magic, ...count, ...payloads];
}

// Tests

void main() {
  group('MultiResultParser.parseMultiWithOutputs', () {
    test(
      'parses MULT with one result-set item and no OUT1',
      () {
        final buf = _multBuf([(0, _emptyOdbcBuf().toList())]);
        final r = MultiResultParser.parseMultiWithOutputs(buf);
        expect(r.items, hasLength(1));
        expect(r.items[0], isA<MultiResultItemResultSet>());
        expect(r.outputParamValues, isEmpty);
      },
    );

    test(
      'parses MULT with result-set + row-count and no OUT1',
      () {
        final buf = _multBuf([
          (0, _emptyOdbcBuf().toList()),
          (1, _le64(42)),
        ]);
        final r = MultiResultParser.parseMultiWithOutputs(buf);
        expect(r.items, hasLength(2));
        expect(r.items[0], isA<MultiResultItemResultSet>());
        expect(r.items[1], isA<MultiResultItemRowCount>());
        expect((r.items[1] as MultiResultItemRowCount).value, 42);
        expect(r.outputParamValues, isEmpty);
      },
    );

    test(
      'parses MULT + OUT1 footer with scalar int output',
      () {
        final multBody = _multBuf([(0, _emptyOdbcBuf().toList())]);
        final out1 = _out1([const ParamValueInt32(99)]);
        final buf = Uint8List.fromList([...multBody, ...out1]);

        final r = MultiResultParser.parseMultiWithOutputs(buf);
        expect(r.items, hasLength(1));
        expect(r.outputParamValues, hasLength(1));
        expect(r.outputParamValues[0], isA<ParamValueInt32>());
        expect((r.outputParamValues[0] as ParamValueInt32).value, 99);
      },
    );

    test(
      'parses MULT with two result-sets + row-count + two OUT1 values',
      () {
        final multBody = _multBuf([
          (0, _emptyOdbcBuf().toList()), // first RS
          (0, _emptyOdbcBuf().toList()), // second RS (drain item)
          (1, _le64(7)), // row-count (drain item)
        ]);
        final out1 = _out1([
          const ParamValueInt32(1),
          const ParamValueString('hi'),
        ]);
        final buf = Uint8List.fromList([...multBody, ...out1]);

        final r = MultiResultParser.parseMultiWithOutputs(buf);
        expect(r.items, hasLength(3));
        expect(r.items[0], isA<MultiResultItemResultSet>());
        expect(r.items[1], isA<MultiResultItemResultSet>());
        expect(r.items[2], isA<MultiResultItemRowCount>());
        expect((r.items[2] as MultiResultItemRowCount).value, 7);

        expect(r.outputParamValues, hasLength(2));
        expect(
          (r.outputParamValues[0] as ParamValueInt32).value,
          1,
        );
        expect(
          (r.outputParamValues[1] as ParamValueString).value,
          'hi',
        );
      },
    );

    test(
      'throws FormatException when buffer does not start with MULT magic',
      () {
        final buf = Uint8List.fromList([
          0x00, 0x01, 0x02, 0x03,
          0, 0, 0, 0, 0, 0, 0, 0,
        ]);
        expect(
          () => MultiResultParser.parseMultiWithOutputs(buf),
          throwsFormatException,
        );
      },
    );

    test(
      'throws FormatException when buffer is too small for MULT header',
      () {
        // Valid MULT magic but truncated.
        final buf = Uint8List.fromList([0x4D, 0x55, 0x4C, 0x54, 0x02, 0x00]);
        expect(
          () => MultiResultParser.parseMultiWithOutputs(buf),
          throwsFormatException,
        );
      },
    );

    test(
      'single-RS ODBC buffer is rejected by parseMultiWithOutputs',
      () {
        // The repository detects MULT magic and routes correctly; a plain ODBC
        // buffer must NOT be passed to parseMultiWithOutputs.
        final odbc = _emptyOdbcBuf();
        final out1 = _out1([const ParamValueInt32(5)]);
        final buf = Uint8List.fromList([...odbc, ...out1]);
        expect(
          () => MultiResultParser.parseMultiWithOutputs(buf),
          throwsFormatException,
        );
      },
    );

    test(
      'MULT with one item and no OUT1 has empty outputParamValues',
      () {
        final buf = _multBuf([(0, _emptyOdbcBuf().toList())]);
        final r = MultiResultParser.parseMultiWithOutputs(buf);
        expect(r.outputParamValues, isEmpty);
      },
    );

    // RowCount-first (DML-first procedures)

    test(
      'RowCount-first: item[0] is RowCount, item[1] is ResultSet',
      () {
        final buf = _multBuf([
          (1, _le64(3)), // row-count first
          (0, _emptyOdbcBuf().toList()), // result set after
        ]);
        final r = MultiResultParser.parseMultiWithOutputs(buf);
        expect(r.items, hasLength(2));
        expect(r.items[0], isA<MultiResultItemRowCount>());
        expect((r.items[0] as MultiResultItemRowCount).value, 3);
        expect(r.items[1], isA<MultiResultItemResultSet>());
        expect(r.outputParamValues, isEmpty);
      },
    );

    test(
      'RowCount → ResultSet → RowCount → OUT1 round-trip',
      () {
        final multBody = _multBuf([
          (1, _le64(1)), // initial row-count
          (0, _emptyOdbcBuf().toList()), // result set
          (1, _le64(2)), // second row-count
        ]);
        final out1 = _out1([const ParamValueInt32(42)]);
        final buf = Uint8List.fromList([...multBody, ...out1]);

        final r = MultiResultParser.parseMultiWithOutputs(buf);
        expect(r.items, hasLength(3));
        expect(r.items[0], isA<MultiResultItemRowCount>());
        expect((r.items[0] as MultiResultItemRowCount).value, 1);
        expect(r.items[1], isA<MultiResultItemResultSet>());
        expect(r.items[2], isA<MultiResultItemRowCount>());
        expect((r.items[2] as MultiResultItemRowCount).value, 2);
        expect(r.outputParamValues, hasLength(1));
        expect((r.outputParamValues[0] as ParamValueInt32).value, 42);
      },
    );
  });

  group('BinaryProtocolParser single-RS + OUT1 unchanged', () {
    test(
      'single ODBC RS + OUT1 still parses via parseWithOutputs',
      () {
        final odbc = _emptyOdbcBuf();
        final out1 = _out1([const ParamValueInt32(77)]);
        final buf = Uint8List.fromList([...odbc, ...out1]);
        final msg = BinaryProtocolParser.parseWithOutputs(buf);
        expect(msg.rowBuffer.rowCount, 0);
        expect(msg.outputParamValues, hasLength(1));
        expect((msg.outputParamValues[0] as ParamValueInt32).value, 77);
      },
    );
  });
}
