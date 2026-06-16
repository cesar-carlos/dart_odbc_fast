import 'dart:ffi';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/ffi_buffer_helper.dart';
import 'package:test/test.dart';

void main() {
  group('callWithBuffer', () {
    test('should invoke callback again when buffer is too small', () {
      var calls = 0;
      final attemptedSizes = <int>[];

      final result = callWithBuffer(
        (buf, bufLen, outWritten) {
          calls++;
          attemptedSizes.add(bufLen);
          if (bufLen < 6) {
            outWritten.value = 6;
            return -2;
          }
          buf.asTypedList(6).setAll(0, [1, 2, 3, 4, 5, 6]);
          outWritten.value = 6;
          return 0;
        },
        initialSize: 2,
        maxSize: 8,
      );

      expect(calls, equals(2));
      expect(attemptedSizes, equals([2, 6]));
      expect(result, equals([1, 2, 3, 4, 5, 6]));
    });

    test('uses scratch pool slots for reentrant calls', () {
      Uint8List? innerResult;

      final outerResult = callWithBuffer(
        (outerBuf, outerLen, outerWritten) {
          final outerBytes = outerBuf.asTypedList(outerLen);
          outerBytes[0] = 1;

          innerResult = callWithBuffer(
            (innerBuf, innerLen, innerWritten) {
              innerBuf.asTypedList(innerLen).setAll(0, [9, 8]);
              innerWritten.value = 2;
              return 0;
            },
            initialSize: 2,
            maxSize: 2,
          );

          expect(outerBytes[0], equals(1));
          outerBytes[1] = 2;
          outerWritten.value = 2;
          return 0;
        },
        initialSize: 2,
        maxSize: 2,
      );

      expect(innerResult, equals([9, 8]));
      expect(outerResult, equals([1, 2]));
    });

    test('returns null when callback reports a hard failure', () {
      final result = callWithBuffer(
        (_, __, ___) => 1,
        initialSize: 8,
        maxSize: 8,
      );

      expect(result, isNull);
    });

    test('returns null when required size exceeds maxSize', () {
      final result = callWithBuffer(
        (_, __, outWritten) {
          outWritten.value = 32;
          return -2;
        },
        initialSize: 4,
        maxSize: 8,
      );

      expect(result, isNull);
    });

    test('returns empty list when callback succeeds with zero bytes', () {
      final result = callWithBuffer(
        (_, __, outWritten) {
          outWritten.value = 0;
          return 0;
        },
        initialSize: 8,
        maxSize: 8,
      );

      expect(result, isEmpty);
    });

    test('returns copied list for payloads below zero-copy threshold', () {
      const n = zeroCopyResultThresholdBytes - 1;
      final result = callWithBuffer(
        (buf, bufLen, outWritten) {
          expect(bufLen, greaterThanOrEqualTo(n));
          buf.asTypedList(n).fillRange(0, n, 7);
          outWritten.value = n;
          return 0;
        },
        initialSize: zeroCopyResultThresholdBytes,
        maxSize: zeroCopyResultThresholdBytes,
      );

      expect(result, isNotNull);
      expect(result, hasLength(n));
      expect(result, everyElement(7));
    });

    test('bypasses scratch pool when allowZeroCopy and limit exceeds threshold',
        () {
      const n = zeroCopyResultThresholdBytes;
      var calls = 0;

      final result = callWithBuffer(
        (buf, bufLen, outWritten) {
          calls++;
          expect(bufLen, greaterThanOrEqualTo(n));
          buf.asTypedList(n).fillRange(0, n, 3);
          outWritten.value = n;
          return 0;
        },
        initialSize: n,
        maxSize: n,
        allowZeroCopy: true,
      );

      expect(calls, 1);
      expect(result, hasLength(n));
      expect(result, everyElement(3));
    });

    test(
      'bypasses scratch pool for default maxSize without large params',
      () {
        const n = zeroCopyResultThresholdBytes;
        var calls = 0;

        final result = callWithBuffer(
          (buf, bufLen, outWritten) {
            calls++;
            buf.asTypedList(n).fillRange(0, n, 5);
            outWritten.value = n;
            return 0;
          },
          initialSize: initialBufferSize,
          allowZeroCopy: true,
        );

        expect(calls, 1);
        expect(result, hasLength(n));
        expect(result, everyElement(5));
      },
    );
  });
}
