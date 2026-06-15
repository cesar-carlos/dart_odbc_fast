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
  });
}
