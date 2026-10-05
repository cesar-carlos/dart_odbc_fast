// Columnar v2: decompress a column block using the same algorithms as
// `native/odbc_engine` (`odbc_columnar_decompress` / _free`).

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:odbc_fast/infrastructure/native/bindings/columnar_decompress.g.dart';
import 'package:odbc_fast/infrastructure/native/bindings/ffi_buffer_helper.dart'
    show zeroCopyResultThresholdBytes;
import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart';
import 'package:odbc_fast/infrastructure/native/bindings/native_byte_view.dart';

ColumnarDecompressBindings? _bindings;
ffi.NativeFinalizer? _decompressFinalizer;

var _tried = false;

final class _DecompressZeroCopyOwner implements ffi.Finalizable {
  _DecompressZeroCopyOwner(this.pointerAddress);

  final int pointerAddress;
}

final Expando<ffi.Finalizable> _decompressZeroCopyOwners =
    Expando<ffi.Finalizable>();

/// True if `odbc_columnar_decompress` / _free` resolved after [loadOdbcLibrary].
bool get isColumnarNativeDecompressAvailable {
  _bindOnce();
  return _bindings != null;
}

/// [algorithm] is `1` = zstd, `2` = lz4 (see Rust `CompressionType`).
Uint8List? columnarDecompressWithNative(
  Uint8List compressed,
  int algorithm,
) {
  final inLen = compressed.lengthInBytes;
  if (inLen > 0x7fffffff) {
    return null;
  }
  if (inLen == 0) return null;
  final inP = malloc<ffi.Uint8>(inLen);
  inP.asTypedList(inLen).setAll(0, compressed);
  try {
    return _columnarDecompressNativeInput(inP, inLen, algorithm);
  } finally {
    malloc.free(inP);
  }
}

/// Decompresses a columnar payload already owned by native memory.
///
/// The pointer must remain readable for [compressedLength] bytes until this
/// synchronous call returns. Callers use this only for FFI result buffers;
/// Dart- and isolate-owned bytes must use [columnarDecompressWithNative].
Uint8List? columnarDecompressNativeInput(
  ffi.Pointer<ffi.Uint8> compressed,
  int compressedLength,
  int algorithm,
) {
  if (compressed.address == 0 ||
      compressedLength <= 0 ||
      compressedLength > 0x7fffffff) {
    return null;
  }
  return _columnarDecompressNativeInput(
    compressed,
    compressedLength,
    algorithm,
  );
}

Uint8List? _columnarDecompressNativeInput(
  ffi.Pointer<ffi.Uint8> inP,
  int inLen,
  int algorithm,
) {
  _bindOnce();
  final d = _bindings?.odbc_columnar_decompress;
  final freeFn = _bindings?.odbc_columnar_decompress_free;
  if (d == null || freeFn == null) {
    return null;
  }

  final outP = malloc<ffi.Pointer<ffi.Uint8>>()..value = ffi.nullptr;
  final oLen = malloc<ffi.UnsignedInt>();
  final oCap = malloc<ffi.UnsignedInt>();
  try {
    final st = d(algorithm, inP, inLen, outP, oLen, oCap);
    if (st != 0) {
      return null;
    }
    final ptr = outP.value;
    if (ptr.address == 0) {
      return null;
    }
    final len = oLen.value;
    final cap = oCap.value;
    if (len >= zeroCopyResultThresholdBytes && _decompressFinalizer != null) {
      final owner = _DecompressZeroCopyOwner(ptr.address);
      Uint8List? view;
      try {
        view = ptr.asTypedList(len);
        _decompressZeroCopyOwners[view] = owner;
        _decompressFinalizer!.attach(
          owner,
          ptr.cast(),
          detach: owner,
          externalSize: len,
        );
        registerNativeByteBacking(view, ptr, owner);
      } on Object {
        _decompressFinalizer!.detach(owner);
        if (view != null) _decompressZeroCopyOwners[view] = null;
        freeFn(ptr, len, cap);
        rethrow;
      }
      return view;
    }
    try {
      return Uint8List.fromList(ptr.asTypedList(len));
    } finally {
      freeFn(ptr, len, cap);
    }
  } finally {
    malloc
      ..free(outP)
      ..free(oLen)
      ..free(oCap);
  }
}

void _bindOnce() {
  if (_tried) {
    return;
  }
  _tried = true;
  try {
    final library = loadOdbcLibrary();
    if (!library.providesSymbol('odbc_columnar_decompress') ||
        !library.providesSymbol('odbc_columnar_decompress_free')) {
      return;
    }
    final bindings = ColumnarDecompressBindings(library);
    _bindings = bindings;
    if (library.providesSymbol('odbc_columnar_decompress_release')) {
      _decompressFinalizer = ffi.NativeFinalizer(
        bindings.addresses.odbc_columnar_decompress_release,
      );
    }
  } on Object {
    _bindings = null;
    _decompressFinalizer = null;
  }
}

void resetColumnarDecompressForTest() {
  _tried = false;
  _bindings = null;
  _decompressFinalizer = null;
}

/// True when [view] is a zero-copy native decompress buffer (tests only).
@visibleForTesting
bool isColumnarDecompressZeroCopyViewForTest(Uint8List view) =>
    _decompressZeroCopyOwners[view] != null;

/// Detaches the zero-copy finalizer and frees native memory (tests only).
@visibleForTesting
void releaseColumnarDecompressZeroCopyViewForTest(Uint8List view) {
  final owner = _decompressZeroCopyOwners[view];
  if (owner is! _DecompressZeroCopyOwner || _decompressFinalizer == null) {
    return;
  }
  _decompressFinalizer!.detach(owner);
  _decompressZeroCopyOwners[view] = null;
  _bindings!.odbc_columnar_decompress_free(
    ffi.Pointer<ffi.Uint8>.fromAddress(owner.pointerAddress),
    0,
    0,
  );
}
