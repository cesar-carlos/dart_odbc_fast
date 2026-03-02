/// Shared helper for creating valid binary protocol buffers in tests.
library;

import 'dart:typed_data';

List<int> _toBytes(int value, int length) {
  final bytes = <int>[];
  for (var i = 0; i < length; i++) {
    bytes.add((value >> (i * 8)) & 0xFF);
  }
  return bytes;
}

/// Creates a minimal valid binary protocol buffer with given columns and rows.
Uint8List createBinaryProtocolBuffer({
  List<({String name, int type})> columns = const [
    (name: 'id', type: 2),
  ],
  List<List<dynamic>> rows = const [],
}) {
  const magic = 0x4F444243;
  const version = 1;

  var payloadSize = 0;
  for (final col in columns) {
    payloadSize += 2 + 2 + col.name.length;
  }
  for (final row in rows) {
    for (final cell in row) {
      payloadSize += 1;
      if (cell != null) {
        final data = cell is int
            ? _toBytes(cell, 4)
            : (cell is String ? cell.codeUnits : <int>[]);
        payloadSize += 4 + data.length;
      }
    }
  }

  final buffer = <int>[
    ..._toBytes(magic, 4),
    ..._toBytes(version, 2),
    ..._toBytes(columns.length, 2),
    ..._toBytes(rows.length, 4),
    ..._toBytes(payloadSize, 4),
  ];

  for (final col in columns) {
    buffer
      ..addAll(_toBytes(col.type, 2))
      ..addAll(_toBytes(col.name.length, 2))
      ..addAll(col.name.codeUnits);
  }

  for (final row in rows) {
    for (final cell in row) {
      if (cell == null) {
        buffer.add(1);
      } else {
        buffer.add(0);
        final data = cell is int
            ? _toBytes(cell, 4)
            : (cell is String ? cell.codeUnits : <int>[]);
        buffer
          ..addAll(_toBytes(data.length, 4))
          ..addAll(data);
      }
    }
  }

  return Uint8List.fromList(buffer);
}
