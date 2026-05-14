import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/frame_accumulator.dart';
import 'package:test/test.dart';

void main() {
  group('BinaryFrameAccumulator', () {
    test('drains a frame split across chunks', () {
      final frame = _frame([1, 2, 3]);
      final accumulator = BinaryFrameAccumulator()
        ..add(Uint8List.sublistView(frame, 0, 5));

      expect(accumulator.drainFrames(), isEmpty);
      expect(accumulator.length, equals(5));

      accumulator.add(Uint8List.sublistView(frame, 5));

      expect(accumulator.drainFrames().toList(), equals([frame]));
      expect(accumulator.length, equals(0));
    });

    test('drains multiple frames from one chunk', () {
      final first = _frame([1]);
      final second = _frame([2, 3]);
      final accumulator = BinaryFrameAccumulator()
        ..add(Uint8List.fromList([...first, ...second]));

      expect(accumulator.drainFrames().toList(), equals([first, second]));
      expect(accumulator.length, equals(0));
    });

    test('preserves incomplete leftover bytes', () {
      final frame = _frame([1]);
      final leftover = Uint8List.fromList([0x99, 0x88, 0x77]);
      final accumulator = BinaryFrameAccumulator()
        ..add(Uint8List.fromList([...frame, ...leftover]));

      expect(accumulator.drainFrames().toList(), equals([frame]));
      expect(accumulator.length, equals(leftover.length));
    });
  });
}

Uint8List _frame(List<int> payload) {
  final bytes = Uint8List(BinaryProtocolParser.headerSize + payload.length);
  ByteData.sublistView(bytes)
    ..setUint32(0, BinaryProtocolParser.magic, Endian.little)
    ..setUint16(4, BinaryProtocolParser.protocolVersionRowMajor, Endian.little)
    ..setUint16(6, 0, Endian.little)
    ..setUint32(8, 0, Endian.little)
    ..setUint32(12, payload.length, Endian.little);
  bytes.setAll(BinaryProtocolParser.headerSize, payload);
  return bytes;
}
