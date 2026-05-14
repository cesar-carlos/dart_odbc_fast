import 'dart:ffi';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/ffi_buffer_helper.dart';
import 'package:test/test.dart';

void main() {
  group('callWithBuffer', () {
    test('grows directly to outWritten size when buffer is too small', () {
      var calls = 0;

      final result = callWithBuffer(
        (buf, bufLen, outWritten) {
          calls++;
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
      expect(result, equals([1, 2, 3, 4, 5, 6]));
    });

    test('falls back to transient allocation for reentrant calls', () {
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
  });
}
