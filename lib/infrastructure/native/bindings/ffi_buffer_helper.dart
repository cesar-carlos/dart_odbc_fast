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
/// `NativeFinalizer` bookkeeping dominates the win. Lowered in v4.2.0 from
/// 64 KiB after microbenchmarks showed net benefit at 32 KiB on Windows.
const int zeroCopyResultThresholdBytes = 32 * 1024;

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

typedef _OdbcReleaseBufferDart = void Function(
  ffi.Pointer<ffi.Uint8>,
  int,
);

_OdbcReleaseBufferDart? _releaseBufferNative;
ffi.NativeFinalizer? _zeroCopyFinalizer;
final Expando<ffi.Finalizable> _zeroCopyOwners = Expando<ffi.Finalizable>();
var _releaseBindingAttempted = false;

final class _ZeroCopyFfiOwner implements ffi.Finalizable {}

/// True when the native engine exports `odbc_release_buffer` (ABI 1.1+).
bool get isZeroCopyResultBufferAvailable {
  _bindReleaseBufferOnce();
  return _releaseBufferNative != null;
}

/// When true, skip the reusable scratch pool so large sync param queries can
/// return zero-copy result views without an extra scratch→owned copy.
bool preferTransientFfiBufferForParams(Uint8List params) =>
    params.length >= zeroCopyResultThresholdBytes;

/// Result of a streaming FFI buffer callback (includes has-more flag).
class StreamBufferFetchResult {
  const StreamBufferFetchResult({
    required this.data,
    required this.hasMore,
  });

  final Uint8List? data;
  final bool hasMore;
}

typedef StreamBufferCallback = int Function(
  ffi.Pointer<ffi.Uint8> buf,
  int bufLen,
  ffi.Pointer<ffi.Uint32> outWritten,
  ffi.Pointer<ffi.Uint8> hasMore,
);

/// Like [callWithBuffer] for stream fetch callbacks that also return hasMore.
StreamBufferFetchResult? streamCallWithBuffer(
  StreamBufferCallback fn, {
  int? maxSize,
  int? initialSize,
}) {
  final limit = maxSize ?? maxBufferSize;
  var size = initialSize ?? initialBufferSize;
  while (size <= limit) {
    final buf = malloc<ffi.Uint8>(size);
    final outWritten = malloc<ffi.Uint32>()..value = 0;
    final hasMore = malloc<ffi.Uint8>()..value = 0;
    try {
      final code = fn(buf, size, outWritten, hasMore);
      if (code == 0) {
        final n = outWritten.value;
        final more = hasMore.value != 0;
        malloc
          ..free(outWritten)
          ..free(hasMore);
        final data = n > 0
            ? materializeFfiBytes(
                buf,
                n,
                transferOwnership: true,
                allowZeroCopy: isZeroCopyResultBufferAvailable,
              )
            : null;
        return StreamBufferFetchResult(data: data, hasMore: more);
      }
      if (code == -2) {
        final requested = outWritten.value;
        malloc
          ..free(buf)
          ..free(outWritten)
          ..free(hasMore);
        size = requested > size ? requested : size * 2;
        continue;
      }
      malloc
        ..free(buf)
        ..free(outWritten)
        ..free(hasMore);
      return null;
    } on Object {
      malloc
        ..free(buf)
        ..free(outWritten)
        ..free(hasMore);
      rethrow;
    }
  }
  return null;
}

/// Materializes FFI bytes using the same zero-copy policy as [callWithBuffer].
Uint8List materializeFfiBytes(
  ffi.Pointer<ffi.Uint8> buf,
  int length, {
  required bool transferOwnership,
  required bool allowZeroCopy,
}) =>
    _materializeFfiBytes(
      buf,
      length,
      transferOwnership: transferOwnership,
      allowZeroCopy: allowZeroCopy,
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
///
/// Payloads at or above [zeroCopyResultThresholdBytes] use a transient native
/// allocation and return a view with a [`NativeFinalizer`] when
/// [isZeroCopyResultBufferAvailable]; otherwise they copy into the Dart heap.
Uint8List? callWithBuffer(
  BufferCallback fn, {
  int? maxSize,
  int? initialSize,
  bool preferTransient = false,
  bool? allowZeroCopy,
}) {
  final limit = maxSize ?? maxBufferSize;
  final size = initialSize ?? initialBufferSize;
  final zeroCopy = allowZeroCopy ?? isZeroCopyResultBufferAvailable;
  if (zeroCopy && (preferTransient || limit >= zeroCopyResultThresholdBytes)) {
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
      allowZeroCopy: zeroCopy,
    );
  }
  try {
    return scratch.call(
      fn,
      limit: limit,
      initialSize: size,
      allowZeroCopy: zeroCopy,
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
        malloc
          ..free(buf)
          ..free(outWritten);
        size = requested > size ? requested : size * 2;
        continue;
      }
      malloc
        ..free(buf)
        ..free(outWritten);
      return null;
    } on Object {
      malloc
        ..free(buf)
        ..free(outWritten);
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
    final owner = _ZeroCopyFfiOwner();
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
        .lookup<
            ffi.NativeFunction<
                ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Uint32)>>(
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
