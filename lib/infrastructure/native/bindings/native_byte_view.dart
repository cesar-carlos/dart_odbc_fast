import 'dart:ffi' as ffi;
import 'dart:typed_data';

/// Internal byte view that retains the native allocation backing a zero-copy
/// FFI result and can derive native pointers for contiguous slices.
///
/// The public protocol APIs continue to accept [Uint8List]. This type only
/// carries provenance while the infrastructure parser still needs it.
final class NativeByteView {
  const NativeByteView._(this.bytes, this._backing, this._offset);

  factory NativeByteView.fromBytes(Uint8List bytes) {
    final backing =
        _nativeByteBackings[bytes] ?? _nativeBufferBackings[bytes.buffer];
    final offset =
        backing == null ? 0 : bytes.offsetInBytes - backing.rootOffset;
    return NativeByteView._(bytes, backing, offset);
  }

  final Uint8List bytes;
  final _NativeByteBacking? _backing;
  final int _offset;

  bool get hasNativeBacking => _backing != null;

  /// Returns a slice retaining the original native allocation, when present.
  NativeByteView slice(int start, int end) {
    RangeError.checkValidRange(start, end, bytes.length);
    final slice = Uint8List.sublistView(bytes, start, end);
    final backing = _backing;
    if (backing != null) {
      _nativeByteBackings[slice] = backing;
    }
    return NativeByteView._(slice, backing, _offset + start);
  }

  /// Returns the native pointer at [offset], or null for Dart-owned bytes.
  ffi.Pointer<ffi.Uint8>? pointerAt(int offset) {
    RangeError.checkValidIndex(offset, bytes, 'offset');
    final backing = _backing;
    if (backing == null) return null;
    return backing.pointer + _offset + offset;
  }
}

final class _NativeByteBacking {
  const _NativeByteBacking(this.pointer, this.owner, this.rootOffset);

  final ffi.Pointer<ffi.Uint8> pointer;

  /// Retaining this object also retains the [ffi.NativeFinalizer] owner.
  final ffi.Finalizable owner;

  final int rootOffset;
}

final Expando<_NativeByteBacking> _nativeByteBackings =
    Expando<_NativeByteBacking>();
final Expando<_NativeByteBacking> _nativeBufferBackings =
    Expando<_NativeByteBacking>();

/// Registers the native allocation that backs [bytes].
///
/// Called only by the FFI buffer helper after it attaches the allocation's
/// finalizer. Slices created through [NativeByteView.slice] inherit it.
void registerNativeByteBacking(
  Uint8List bytes,
  ffi.Pointer<ffi.Uint8> pointer,
  ffi.Finalizable owner,
) {
  final backing = _NativeByteBacking(pointer, owner, bytes.offsetInBytes);
  _nativeByteBackings[bytes] = backing;
  _nativeBufferBackings[bytes.buffer] = backing;
}
