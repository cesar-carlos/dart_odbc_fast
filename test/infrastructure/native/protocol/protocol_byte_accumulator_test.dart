import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/protocol_byte_accumulator.dart';
import 'package:test/test.dart';

void main() {
  group('ProtocolByteAccumulator', () {
    setUp(ProtocolByteAccumulator.clearPoolForTest);
    tearDown(ProtocolByteAccumulator.clearPoolForTest);

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

    test('should_reuse_offered_default_backing_when_constructing', () {
      final recycled = Uint8List(64 * 1024);
      ProtocolByteAccumulator.offerDefaultBacking(recycled);
      expect(ProtocolByteAccumulator.pooledBackingCount, 1);

      final acc = ProtocolByteAccumulator();
      expect(ProtocolByteAccumulator.pooledBackingCount, 0);

      acc.add(Uint8List.fromList([42]));
      // Same backing instance was pulled from the pool.
      expect(recycled[0], 42);
    });

    test('should_cap_pooled_backings_at_four', () {
      for (var i = 0; i < 10; i++) {
        ProtocolByteAccumulator.offerDefaultBacking(Uint8List(64 * 1024));
      }
      expect(ProtocolByteAccumulator.pooledBackingCount, 4);
    });

    test('should_offer_abandoned_default_backing_on_growth', () {
      final acc = ProtocolByteAccumulator()
        ..add(Uint8List(64 * 1024))
        ..add(Uint8List.fromList([1]));
      expect(ProtocolByteAccumulator.pooledBackingCount, 1);
      expect(acc.length, 64 * 1024 + 1);
    });

    test('should_not_pool_non_default_capacity_buffers', () {
      ProtocolByteAccumulator.offerDefaultBacking(Uint8List(8));
      expect(ProtocolByteAccumulator.pooledBackingCount, 0);
    });

    test('should_reuse_offered_1mib_backing_when_acquiring_large', () {
      final recycled = Uint8List(1024 * 1024);
      ProtocolByteAccumulator.offerPooledBacking(recycled);
      expect(ProtocolByteAccumulator.pooledLargeBackingCount, 1);

      final acc = ProtocolByteAccumulator(initialCapacity: 1024 * 1024);
      expect(ProtocolByteAccumulator.pooledLargeBackingCount, 0);

      acc.add(Uint8List.fromList([7]));
      expect(recycled[0], 7);
    });

    test('should_cap_pooled_1mib_backings_at_two', () {
      for (var i = 0; i < 5; i++) {
        ProtocolByteAccumulator.offerPooledBacking(Uint8List(1024 * 1024));
      }
      expect(ProtocolByteAccumulator.pooledLargeBackingCount, 2);
      expect(ProtocolByteAccumulator.pooledDefaultBackingCount, 0);
    });

    test('should_snap_growth_to_1mib_tier_when_exceeding_64kib', () {
      final acc = ProtocolByteAccumulator()
        ..add(Uint8List(64 * 1024))
        ..add(Uint8List.fromList([1]));
      // Abandoned 64 KiB backing is pooled; new capacity snaps to 1 MiB.
      expect(ProtocolByteAccumulator.pooledDefaultBackingCount, 1);
      expect(acc.length, 64 * 1024 + 1);
      final remaining = (1024 * 1024) - acc.length;
      acc.add(Uint8List(remaining));
      expect(acc.length, 1024 * 1024);
      final taken = acc.take(1024 * 1024);
      expect(taken.length, 1024 * 1024);
    });
  });
}
