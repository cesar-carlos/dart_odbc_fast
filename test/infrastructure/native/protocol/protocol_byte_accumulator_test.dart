import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/protocol_byte_accumulator.dart';
import 'package:test/test.dart';

void main() {
  group('ProtocolByteAccumulator', () {
    test('should_return_sublistView_from_peek_and_take', () {
      final acc = ProtocolByteAccumulator()
        ..add(Uint8List.fromList([1, 2, 3, 4]));

      final peeked = acc.peek(2);
      expect(peeked, equals([1, 2]));
      expect(acc.length, equals(4));

      final taken = acc.take(4);
      expect(taken, equals([1, 2, 3, 4]));
      expect(taken.offsetInBytes, equals(0));
      expect(acc.length, equals(0));
    });

    test('should_compact_after_partial_consumption', () {
      final acc = ProtocolByteAccumulator(initialCapacity: 8)
        ..add(Uint8List.fromList([1, 2, 3, 4, 5]))
        ..drop(3)
        ..add(Uint8List.fromList([6, 7]));

      expect(acc.length, equals(4));
      expect(acc.take(4), equals([4, 5, 6, 7]));
      expect(acc.length, equals(0));
    });

    test('should_transfer_buffer_when_draining_full_capacity', () {
      final acc = ProtocolByteAccumulator(initialCapacity: 4)
        ..add(Uint8List.fromList([1, 2, 3, 4]));

      final taken = acc.take(4);
      expect(taken, equals([1, 2, 3, 4]));
      expect(taken.offsetInBytes, equals(0));
      expect(taken.length, equals(4));
      expect(acc.length, equals(0));

      acc.add(Uint8List.fromList([5, 6]));
      expect(acc.take(2), equals([5, 6]));
    });

    test('should_hand_off_view_without_copy_when_taking_full_length', () {
      final acc = ProtocolByteAccumulator(initialCapacity: 16)
        ..add(Uint8List.fromList([9, 8, 7]));
      final taken = acc.take(3);
      expect(taken, equals([9, 8, 7]));
      expect(taken.lengthInBytes, equals(3));
      expect(acc.length, equals(0));
      // Accumulator reuse must not mutate the handed-off frame.
      acc.add(Uint8List.fromList([1]));
      expect(taken, equals([9, 8, 7]));
    });

    test('should_hand_off_prefix_view_when_taking_partial_length', () {
      final acc = ProtocolByteAccumulator(initialCapacity: 8)
        ..add(Uint8List.fromList([1, 2, 3, 4, 5, 6]));
      final frame = acc.take(4);
      expect(frame, equals([1, 2, 3, 4]));
      expect(acc.length, equals(2));
      expect(acc.take(2), equals([5, 6]));
      expect(frame, equals([1, 2, 3, 4]));
    });
  });
}
