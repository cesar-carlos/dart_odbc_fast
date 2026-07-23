import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart';
import 'package:odbc_fast/infrastructure/native/protocol/stream_frame_decode.dart';
import 'package:test/test.dart';

const Endian _le = Endian.little;

Uint8List _buildColumnarV2Frame() {
  return _createColumnarV2Buffer(
    columns: const [
      (name: 'id', type: 2),
    ],
    rows: [
      [42],
    ],
  );
}

Uint8List _wrapResultSetFrame(Uint8List inner) {
  final out = BytesBuilder()
    ..addByte(multiStreamItemTagResultSet)
    ..add((ByteData(4)..setUint32(0, inner.length, _le)).buffer.asUint8List())
    ..add(inner);
  return out.toBytes();
}

void main() {
  group('decodeBatchedStreamFrame', () {
    test('should_decode_columnar_v2_frame_to_parsed_row_buffer', () {
      final frame = _buildColumnarV2Frame();
      final parsed = decodeBatchedStreamFrame(frame);
      expect(parsed.rowCount, 1);
      expect(parsed.rows.single.single, 42);
    });
  });

  group('MultiResultStreamDecoder columnar v2', () {
    test('should_decode_columnar_v2_result_set_frame', () {
      final decoder = MultiResultStreamDecoder();
      final items = decoder.feed(_wrapResultSetFrame(_buildColumnarV2Frame()));
      expect(items, hasLength(1));
      expect(items.single, isA<MultiResultItemResultSet>());
      final rs = (items.single as MultiResultItemResultSet).value;
      expect(rs.rowCount, 1);
      expect(rs.rows.single.single, 42);
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

extension on int {
  List<int> toBytes(int length) {
    final bytes = <int>[];
    for (var i = 0; i < length; i++) {
      bytes.add((this >> (i * 8)) & 0xFF);
    }
    return bytes;
  }
}
