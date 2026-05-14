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

    test('returns a view when the complete frame is already in one chunk', () {
      final frame = _frame([1, 2, 3, 4]);
      final backing = Uint8List.fromList([0x99, ...frame, 0x88]);
      final frameView = Uint8List.sublistView(
        backing,
        1,
        1 + frame.length,
      );
      final accumulator = BinaryFrameAccumulator()..add(frameView);

      final drained = accumulator.drainFrames().single;

      expect(drained, equals(frame));
      expect(drained.offsetInBytes, equals(frameView.offsetInBytes));
      expect(accumulator.length, equals(0));
    });

    test('copies only when frame spans many chunks', () {
      final frame = _frame([1, 2, 3, 4, 5]);
      final accumulator = BinaryFrameAccumulator();
      for (final byte in frame) {
        accumulator.add(Uint8List.fromList([byte]));
      }

      final drained = accumulator.drainFrames().single;

      expect(drained, equals(frame));
      expect(drained.buffer, isNot(same(frame.buffer)));
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

    test('drains a columnar v2 frame split across header chunks', () {
      final frame = _columnarFrame([1, 2, 3, 4]);
      final accumulator = BinaryFrameAccumulator()
        ..add(Uint8List.sublistView(frame, 0, 17));

      expect(accumulator.drainFrames(), isEmpty);
      expect(accumulator.length, equals(17));

      accumulator.add(Uint8List.sublistView(frame, 17));

      expect(accumulator.drainFrames().toList(), equals([frame]));
      expect(accumulator.length, equals(0));
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

Uint8List _columnarFrame(List<int> payload) {
  final bytes = Uint8List(
    BinaryProtocolParser.headerSizeColumnarV2 + payload.length,
  );
  ByteData.sublistView(bytes)
    ..setUint32(0, BinaryProtocolParser.magic, Endian.little)
    ..setUint16(
      4,
      BinaryProtocolParser.protocolVersionColumnarV2,
      Endian.little,
    )
    ..setUint16(6, 0, Endian.little)
    ..setUint16(8, 0, Endian.little)
    ..setUint32(10, 0, Endian.little)
    ..setUint8(14, 0)
    ..setUint32(15, payload.length, Endian.little);
  bytes.setAll(BinaryProtocolParser.headerSizeColumnarV2, payload);
  return bytes;
}
