import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:odbc_fast/infrastructure/native/bindings/ffi_copy_budget.dart';
import 'package:odbc_fast/infrastructure/native/bindings/native_byte_view.dart';

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

/// All transient FFI buffers in this file are allocated by `package:ffi`
/// `malloc`, so `nativeFree` is the matching allocator on every supported
/// host. This deliberately does not depend on an optional native symbol.
final ffi.NativeFinalizer _zeroCopyFinalizer =
    ffi.NativeFinalizer(malloc.nativeFree);

final class _ZeroCopyFfiOwner implements ffi.Finalizable {}

/// Process-local malloc address sent between isolates instead of copying bytes.
final class AdoptedNativePayload {
  const AdoptedNativePayload({
    required this.address,
    required this.length,
  });

  final int address;
  final int length;
}

/// True because result buffers are owned by Dart-side `malloc`.
bool get isZeroCopyResultBufferAvailable => true;

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
    final buf = _transientPool.acquire(size);
    outWritten.value = 0;
    hasMore.value = 0;
    try {
      final code = fn(buf, size, outWritten, hasMore);
      if (code == 0) {
        final n = outWritten.value;
        final more = hasMore.value != 0;
        final Uint8List? data;
        if (n > 0) {
          data = _materializePooledBytes(
            buf,
            size,
            n,
            allowZeroCopy: allowZeroCopy,
          );
        } else {
          _transientPool.release(buf, size);
          data = null;
        }
        return StreamBufferFetchResult(data: data, hasMore: more);
      }
      if (code == -2) {
        final requested = outWritten.value;
        _transientPool.release(buf, size);
        size = requested > size ? requested : size * 2;
        continue;
      }
      _transientPool.release(buf, size);
      return null;
    } on Object {
      _transientPool.release(buf, size);
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
    final buf = _transientPool.acquire(size);
    outWritten.value = 0;
    try {
      final code = fn(buf, size, outWritten);
      if (code == 0) {
        final n = outWritten.value;
        return _materializePooledBytes(
          buf,
          size,
          n,
          allowZeroCopy: allowZeroCopy,
        );
      }
      if (code == -2) {
        final requested = outWritten.value;
        _transientPool.release(buf, size);
        size = requested > size ? requested : size * 2;
        continue;
      }
      _transientPool.release(buf, size);
      return null;
    } on Object {
      _transientPool.release(buf, size);
      rethrow;
    }
  }
  return null;
}

Uint8List _materializePooledBytes(
  ffi.Pointer<ffi.Uint8> buf,
  int pooledSize,
  int length, {
  required bool allowZeroCopy,
}) {
  if (length == 0) {
    _transientPool.release(buf, pooledSize);
    return Uint8List(0);
  }
  if (allowZeroCopy && length >= zeroCopyResultThresholdBytes) {
    return _materializeFfiBytes(
      buf,
      length,
      transferOwnership: true,
      allowZeroCopy: true,
    );
  }
  recordFfiResultCopy(length);
  final copy = Uint8List.fromList(buf.asTypedList(length));
  _transientPool.release(buf, pooledSize);
  return copy;
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
      length >= zeroCopyResultThresholdBytes) {
    final view = buf.asTypedList(length);
    final owner = _ZeroCopyFfiOwner();
    _zeroCopyFinalizer.attach(
      owner,
      buf.cast(),
      detach: owner,
      externalSize: length,
    );
    registerNativeByteBacking(view, buf, owner);
    recordFfiZeroCopyView();
    return view;
  }
  recordFfiResultCopy(length);
  try {
    return Uint8List.fromList(buf.asTypedList(length));
  } finally {
    if (transferOwnership) {
      malloc.free(buf);
    }
  }
}

/// Detaches a zero-copy malloc so another isolate can adopt it.
///
/// Returns null when [bytes] is below the zero-copy floor or has no native
/// backing. The caller must either [attachAdoptedNativePayload] or
/// [releaseAdoptedNativePayload].
AdoptedNativePayload? detachZeroCopyPayload(Uint8List bytes) {
  if (bytes.length < zeroCopyResultThresholdBytes) {
    return null;
  }
  final owner = nativeFinalizerOwner(bytes);
  final pointer = nativeBackingPointer(bytes);
  if (owner == null || pointer == null) {
    return null;
  }
  _zeroCopyFinalizer.detach(owner);
  return AdoptedNativePayload(address: pointer.address, length: bytes.length);
}

/// Rebuilds a zero-copy view for a payload adopted from another isolate.
Uint8List attachAdoptedNativePayload(AdoptedNativePayload payload) {
  final buf = ffi.Pointer<ffi.Uint8>.fromAddress(payload.address);
  return _materializeFfiBytes(
    buf,
    payload.length,
    transferOwnership: true,
    allowZeroCopy: true,
  );
}

/// Frees an adopted payload that was never attached on the receiving isolate.
void releaseAdoptedNativePayload(AdoptedNativePayload payload) {
  malloc.free(ffi.Pointer<ffi.Uint8>.fromAddress(payload.address));
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
        // Scratch memory is reused on the next call, so a NativeFinalizer
        // view would be unsound. Copy into the Dart heap even when n is
        // at or above the zero-copy floor.
        recordFfiResultScratchCopy(n);
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
    recordFfiResultMalloc();
    _buffer = malloc<ffi.Uint8>(size);
    _capacity = size;
  }
}

/// Recycles transient result buffers whose payload stayed below the zero-copy
/// floor so small queries reuse the 64 KiB / 256 KiB seed instead of malloc.
final class _TransientFfiBufferPool {
  static const int _maxPooledBlocks = 8;

  final List<({ffi.Pointer<ffi.Uint8> buf, int size})> _free =
      <({ffi.Pointer<ffi.Uint8> buf, int size})>[];

  ffi.Pointer<ffi.Uint8> acquire(int size) {
    for (var i = 0; i < _free.length; i++) {
      if (_free[i].size == size) {
        final slot = _free.removeAt(i);
        return slot.buf;
      }
    }
    recordFfiResultMalloc();
    return malloc<ffi.Uint8>(size);
  }

  void release(ffi.Pointer<ffi.Uint8> buf, int size) {
    if (_free.length >= _maxPooledBlocks) {
      malloc.free(buf);
      return;
    }
    _free.add((buf: buf, size: size));
  }

  void clearForTest() {
    for (final slot in _free) {
      malloc.free(slot.buf);
    }
    _free.clear();
  }
}

final _TransientFfiBufferPool _transientPool = _TransientFfiBufferPool();

/// Retained for source-compatible tests. Zero-copy availability is no longer
/// tied to a dynamically resolved native symbol.
void resetZeroCopyResultBufferBindingForTest() {
  resetFfiCopyBudgetForTest();
  resetTransientFfiBufferPoolForTest();
}

/// Frees pooled transient result buffers. Tests call this via
/// [resetZeroCopyResultBufferBindingForTest].
void resetTransientFfiBufferPoolForTest() {
  _transientPool.clearForTest();
}
