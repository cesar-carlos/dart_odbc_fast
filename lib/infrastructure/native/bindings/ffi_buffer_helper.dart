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
  final size = initialSize ?? initialBufferSize;
  final scratch = _sharedScratch.tryAcquire();
  if (scratch == null) {
    return _callWithTransientBuffer(fn, limit: limit, initialSize: size);
  }
  try {
    return scratch.call(fn, limit: limit, initialSize: size);
  } finally {
    scratch.release();
  }
}

Uint8List? _callWithTransientBuffer(
  BufferCallback fn, {
  required int limit,
  required int initialSize,
}) {
  // Clamp to limit so callers passing maxBufferBytes smaller than the default
  // 64 KB initialSize still enter the loop instead of skipping it entirely.
  var size = initialSize <= limit ? initialSize : limit;
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
        final requested = outWritten.value;
        size = requested > size ? requested : size * 2;
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

final _ReusableFfiScratch _sharedScratch = _ReusableFfiScratch();

final class _ReusableFfiScratch {
  ffi.Pointer<ffi.Uint8> _buffer = ffi.nullptr;
  ffi.Pointer<ffi.Uint32> _outWritten = ffi.nullptr;
  int _capacity = 0;
  bool _isInUse = false;

  _ReusableFfiScratch? tryAcquire() {
    if (_isInUse) return null;
    _isInUse = true;
    return this;
  }

  Uint8List? call(
    BufferCallback fn, {
    required int limit,
    required int initialSize,
  }) {
    var size = initialSize <= limit ? initialSize : limit;
    while (size <= limit) {
      _ensureCapacity(size);
      _outWritten.value = 0;
      final code = fn(_buffer, size, _outWritten);
      if (code == 0) {
        final n = _outWritten.value;
        if (n == 0) {
          return Uint8List(0);
        }
        return Uint8List.fromList(_buffer.asTypedList(n));
      }
      if (code == -2) {
        final requested = _outWritten.value;
        size = requested > size ? requested : size * 2;
        continue;
      }
      return null;
    }
    return null;
  }

  void release() {
    _isInUse = false;
  }

  void _ensureCapacity(int size) {
    if (_outWritten == ffi.nullptr) {
      _outWritten = malloc<ffi.Uint32>();
    }
    if (_capacity >= size) return;
    if (_buffer != ffi.nullptr) {
      malloc.free(_buffer);
    }
    _buffer = malloc<ffi.Uint8>(size);
    _capacity = size;
  }
}
