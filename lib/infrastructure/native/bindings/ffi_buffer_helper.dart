import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart';

/// Initial buffer size for FFI buffer allocations (256 KB).
///
/// Sized to cover typical medium result frames on the first attempt and avoid
/// a `-2` resize round-trip. Callers with known budgets should still pass
/// [callWithBuffer]'s `initialSize` / `maxSize` (streams: use `chunkSize`).
const int initialBufferSize = 256 * 1024;

/// Maximum buffer size for FFI buffer allocations (16 MB).
const int maxBufferSize = 16 * 1024 * 1024;

/// Reusable FFI scratch slots per isolate.
///
/// Sized for high-throughput async worker presets (up to 6 workers) plus
/// headroom for reentrant [callWithBuffer] on the same isolate.
const int ffiScratchPoolSlotCount = 8;

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
///
/// Prefer passing [initialSize] equal to the stream `chunkSize` so the first
/// allocation matches the native copy budget and avoids a -2 resize round-trip.
/// Streaming payloads are typically large; this path uses a transient native
/// buffer and the same zero-copy materialization policy as [callWithBuffer]
/// (no scratch pool — reused scratch would force an extra copy for ≥32 KiB).
StreamBufferFetchResult? streamCallWithBuffer(
  StreamBufferCallback fn, {
  int? maxSize,
  int? initialSize,
  bool? allowZeroCopy,
}) {
  final limit = maxSize ?? maxBufferSize;
  final size = initialSize ?? initialBufferSize;
  final zeroCopy = allowZeroCopy ?? isZeroCopyResultBufferAvailable;
  return _streamCallWithTransientBuffer(
    fn,
    limit: limit,
    initialSize: size,
    allowZeroCopy: zeroCopy,
  );
}

StreamBufferFetchResult? _streamCallWithTransientBuffer(
  StreamBufferCallback fn, {
  required int limit,
  required int initialSize,
  required bool allowZeroCopy,
}) {
  final outWritten = _streamStatusOutWritten;
  final hasMore = _streamStatusHasMore;
  var size = initialSize <= limit ? initialSize : limit;
  while (size <= limit) {
    final buf = malloc<ffi.Uint8>(size);
    outWritten.value = 0;
    hasMore.value = 0;
    try {
      final code = fn(buf, size, outWritten, hasMore);
      if (code == 0) {
        final n = outWritten.value;
        final more = hasMore.value != 0;
        final data = n > 0
            ? materializeFfiBytes(
                buf,
                n,
                transferOwnership: true,
                allowZeroCopy: allowZeroCopy,
              )
            : null;
        return StreamBufferFetchResult(data: data, hasMore: more);
      }
      if (code == -2) {
        final requested = outWritten.value;
        malloc.free(buf);
        size = requested > size ? requested : size * 2;
        continue;
      }
      malloc.free(buf);
      return null;
    } on Object {
      malloc.free(buf);
      rethrow;
    }
  }
  return null;
}

/// Reused per-isolate status pointers for stream fetches (data buffer stays
/// transient for zero-copy).
final ffi.Pointer<ffi.Uint32> _streamStatusOutWritten = malloc<ffi.Uint32>();
final ffi.Pointer<ffi.Uint8> _streamStatusHasMore = malloc<ffi.Uint8>();

/// Reused per-isolate `outWritten` for transient query buffers.
final ffi.Pointer<ffi.Uint32> _transientOutWritten = malloc<ffi.Uint32>();

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
  // Prefer transient when the caller opts in or the seed is already at/above
  // the zero-copy floor (32 KiB). Mid-size frames (32–256 KiB) skip the scratch
  // pool so successful results can return a NativeFinalizer view without an
  // extra copy. Smaller seeds still use the scratch pool.
  if (zeroCopy && (preferTransient || size >= zeroCopyResultThresholdBytes)) {
    return _callWithTransientBuffer(
      fn,
      limit: limit,
      initialSize: size,
      allowZeroCopy: true,
    );
  }
  final scratch = _sharedScratchPool.tryAcquire();
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
  // initialSize still enter the loop instead of skipping it entirely.
  var size = initialSize <= limit ? initialSize : limit;
  final outWritten = _transientOutWritten;
  while (size <= limit) {
    final buf = malloc<ffi.Uint8>(size);
    outWritten.value = 0;
    try {
      final code = fn(buf, size, outWritten);
      if (code == 0) {
        final n = outWritten.value;
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
        size = requested > size ? requested : size * 2;
        continue;
      }
      malloc.free(buf);
      return null;
    } on Object {
      malloc.free(buf);
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
    _zeroCopyFinalizer!.attach(
      owner,
      buf.cast(),
      detach: owner,
      externalSize: length,
    );
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

final _ReusableFfiScratchPool _sharedScratchPool =
    _ReusableFfiScratchPool(ffiScratchPoolSlotCount);

final class _ReusableFfiScratchPool {
  _ReusableFfiScratchPool(int slotCount)
      : _slots = List.generate(slotCount, (_) => _ReusableFfiScratch());

  final List<_ReusableFfiScratch> _slots;

  _ReusableFfiScratch? tryAcquire() {
    for (final slot in _slots) {
      final acquired = slot.tryAcquire();
      if (acquired != null) {
        return acquired;
      }
    }
    return null;
  }
}

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
        if (allowZeroCopy && size >= zeroCopyResultThresholdBytes) {
          // Large resize: leave the scratch pool and use a transient buffer so
          // zero-copy materialization does not need a scratch→owned copy.
          return _callWithTransientBuffer(
            fn,
            limit: limit,
            initialSize: size <= limit ? size : limit,
            allowZeroCopy: true,
          );
        }
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
