import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Initial buffer size for FFI buffer allocations (64 KB).
const int initialBufferSize = 64 * 1024;

/// Maximum buffer size for FFI buffer allocations (16 MB).
const int maxBufferSize = 16 * 1024 * 1024;

/// Callback function type for FFI buffer operations.
///
/// The callback receives a buffer pointer, buffer length, and output
/// written pointer. Returns 0 on success, -2 if buffer needs to be resized,
/// or other error code on failure.
typedef BufferCallback = int Function(
  ffi.Pointer<ffi.Uint8> buf,
  int bufLen,
  ffi.Pointer<ffi.Uint32> outWritten,
);

/// Calls a buffer callback function with dynamically sized buffers.
///
/// Starts with [initialSize] or [initialBufferSize] and doubles the buffer
/// size if the callback returns -2 (buffer too small), up to [maxSize] or
/// [maxBufferSize].
///
/// When [maxSize] is null, [maxBufferSize] is used.
/// When [initialSize] is null, [initialBufferSize] is used.
/// Returns the data as [Uint8List] on success, null on failure.
Uint8List? callWithBuffer(BufferCallback fn, {int? maxSize, int? initialSize}) {
  final limit = maxSize ?? maxBufferSize;
  var size = initialSize ?? initialBufferSize;
  while (size <= limit) {
    final buf = malloc<ffi.Uint8>(size);
    final outWritten = malloc<ffi.Uint32>()..value = 0;
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
      malloc
        ..free(buf)
        ..free(outWritten);
    }
  }
  return null;
}
