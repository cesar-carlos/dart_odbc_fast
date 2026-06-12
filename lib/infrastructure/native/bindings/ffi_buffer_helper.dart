import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart';

/// Initial buffer size for FFI buffer allocations (64 KB).
const int initialBufferSize = 64 * 1024;

/// Maximum buffer size for FFI buffer allocations (16 MB).
const int maxBufferSize = 16 * 1024 * 1024;

/// Minimum successful FFI payload size before returning a zero-copy view.
///
/// Smaller payloads keep the `Uint8List.fromList` copy because the
/// `NativeFinalizer` bookkeeping dominates the win.
const int zeroCopyResultThresholdBytes = 64 * 1024;

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

typedef _OdbcReleaseBufferNative = ffi.Void Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
);
typedef _OdbcReleaseBufferDart = void Function(
  ffi.Pointer<ffi.Uint8>,
  int,
);

_OdbcReleaseBufferDart? _releaseBufferNative;
ffi.NativeFinalizer? _zeroCopyFinalizer;
final Expando<ffi.Finalizable> _zeroCopyOwners = Expando<ffi.Finalizable>();
var _releaseBindingAttempted = false;

final class _ZeroCopyFfiOwner implements ffi.Finalizable {
  const _ZeroCopyFfiOwner();
}

/// True when the native engine exports `odbc_release_buffer` (ABI 1.1+).
bool get isZeroCopyResultBufferAvailable {
  _bindReleaseBufferOnce();
  return _releaseBufferNative != null;
}

/// Calls a buffer callback function with dynamically sized buffers.
///
/// Starts with [initialSize] or [initialBufferSize] and doubles the buffer
/// size if the callback returns -2 (buffer too small), up to [maxSize] or
/// [maxBufferSize].
///
/// When [maxSize] is null, [maxBufferSize] is used.
/// When [initialSize] is null, [initialBufferSize] is used.
/// Returns the data as [Uint8List] on success, null on failure.
///
/// Payloads at or above [zeroCopyResultThresholdBytes] use a transient native
/// allocation and return a view with a [`NativeFinalizer`] when
/// [isZeroCopyResultBufferAvailable]; otherwise they copy into the Dart heap.
Uint8List? callWithBuffer(BufferCallback fn, {int? maxSize, int? initialSize}) {
  final limit = maxSize ?? maxBufferSize;
  final size = initialSize ?? initialBufferSize;
  if (isZeroCopyResultBufferAvailable && limit >= zeroCopyResultThresholdBytes) {
    return _callWithTransientBuffer(
      fn,
      limit: limit,
      initialSize: size,
      allowZeroCopy: true,
    );
  }
  final scratch = _sharedScratch.tryAcquire();
  if (scratch == null) {
    return _callWithTransientBuffer(
      fn,
      limit: limit,
      initialSize: size,
      allowZeroCopy: isZeroCopyResultBufferAvailable,
    );
  }
  try {
    return scratch.call(
      fn,
      limit: limit,
      initialSize: size,
      allowZeroCopy: isZeroCopyResultBufferAvailable,
    );
  } finally {
    scratch.release();
  }
}

Uint8List? _callWithTransientBuffer(
  BufferCallback fn, {
  required int limit,
  required int initialSize,
  required bool allowZeroCopy,
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
        malloc.free(outWritten);
        return _materializeFfiBytes(
          buf,
          n,
          transferOwnership: true,
          allowZeroCopy: allowZeroCopy,
        );
      }
      if (code == -2) {
        final requested = outWritten.value;
        malloc.free(buf);
        malloc.free(outWritten);
        size = requested > size ? requested : size * 2;
        continue;
      }
      malloc.free(buf);
      malloc.free(outWritten);
      return null;
    } on Object {
      malloc.free(buf);
      malloc.free(outWritten);
      rethrow;
    }
  }
  return null;
}

Uint8List _materializeFfiBytes(
  ffi.Pointer<ffi.Uint8> buf,
  int length, {
  required bool transferOwnership,
  required bool allowZeroCopy,
}) {
  if (length == 0) {
    if (transferOwnership) {
      malloc.free(buf);
    }
    return Uint8List(0);
  }
  if (transferOwnership &&
      allowZeroCopy &&
      length >= zeroCopyResultThresholdBytes &&
      _zeroCopyFinalizer != null) {
    final view = buf.asTypedList(length);
    const owner = _ZeroCopyFfiOwner();
    _zeroCopyOwners[view] = owner;
    _zeroCopyFinalizer!.attach(owner, buf.cast(), detach: owner);
    return view;
  }
  try {
    return Uint8List.fromList(buf.asTypedList(length));
  } finally {
    if (transferOwnership) {
      malloc.free(buf);
    }
  }
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
    required bool allowZeroCopy,
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
        if (allowZeroCopy && n >= zeroCopyResultThresholdBytes) {
          final owned = malloc<ffi.Uint8>(n);
          owned.asTypedList(n).setAll(0, _buffer.asTypedList(n));
          return _materializeFfiBytes(
            owned,
            n,
            transferOwnership: true,
            allowZeroCopy: true,
          );
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

void _bindReleaseBufferOnce() {
  if (_releaseBindingAttempted) {
    return;
  }
  _releaseBindingAttempted = true;
  try {
    final lib = loadOdbcLibrary();
    _releaseBufferNative = lib
        .lookup<ffi.NativeFunction<_OdbcReleaseBufferNative>>(
          'odbc_release_buffer',
        )
        .asFunction<_OdbcReleaseBufferDart>();
    // Buffers are allocated with `package:ffi` `malloc`; `nativeFree` pairs
    // with that allocator on every supported host. `odbc_release_buffer` is
    // exported for ABI symmetry and non-Dart callers.
    _zeroCopyFinalizer = ffi.NativeFinalizer(malloc.nativeFree);
  } on Object {
    _releaseBufferNative = null;
    _zeroCopyFinalizer = null;
  }
}

/// Clears cached zero-copy bindings (tests only).
void resetZeroCopyResultBufferBindingForTest() {
  _releaseBindingAttempted = false;
  _releaseBufferNative = null;
  _zeroCopyFinalizer = null;
  // Expando has no clear(); tests only use sub-threshold copies today.
}
