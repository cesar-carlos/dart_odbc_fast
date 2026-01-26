import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const int initialBufferSize = 64 * 1024;
const int maxBufferSize = 16 * 1024 * 1024;

typedef BufferCallback = int Function(
  ffi.Pointer<ffi.Uint8> buf,
  int bufLen,
  ffi.Pointer<ffi.Uint32> outWritten,
);

Uint8List? callWithBuffer(BufferCallback fn) {
  var size = initialBufferSize;
  while (size <= maxBufferSize) {
    final buf = malloc<ffi.Uint8>(size);
    final outWritten = malloc<ffi.Uint32>();
    outWritten.value = 0;
    try {
      final code = fn(buf, size, outWritten);
      if (code == 0) {
        final n = outWritten.value;
        if (n == 0) {
          return Uint8List(0);
        }
        return Uint8List.fromList(buf.asTypedList(n));
      }
      if (code == -2) {
        size *= 2;
        continue;
      }
      return null;
    } finally {
      malloc.free(buf);
      malloc.free(outWritten);
    }
  }
  return null;
}
