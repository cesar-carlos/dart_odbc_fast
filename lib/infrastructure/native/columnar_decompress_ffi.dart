// Columnar v2: decompress a column block using the same algorithms as
// `native/odbc_engine` (`odbc_columnar_decompress` / _free`).

// NativeFunction/typedef C shapes are intentionally paired; malloc frees
// are clearer as separate lines than cascades.
// ignore_for_file: avoid_private_typedef_functions, cascade_invocations

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:odbc_fast/infrastructure/native/bindings/ffi_buffer_helper.dart'
    show zeroCopyResultThresholdBytes;
import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart';

// ---------------------------------------------------------------------------
// Native (C) signatures — `NativeFunction<…>` and `asFunction<…>` differ.
// ---------------------------------------------------------------------------
typedef _OdbcDecompressC = ffi.Int32 Function(
  ffi.Uint8,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
  ffi.Pointer<ffi.Uint32>,
  ffi.Pointer<ffi.Uint32>,
);
typedef _OdbcDecompressD = int Function(
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
  ffi.Pointer<ffi.Uint32>,
  ffi.Pointer<ffi.Uint32>,
);
typedef _OdbcDecompressFreeC = ffi.Void Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
  ffi.Uint32,
);
typedef _OdbcDecompressFreeD = void Function(
  ffi.Pointer<ffi.Uint8>,
  int,
  int,
);

_OdbcDecompressD? _decomp;
_OdbcDecompressFreeD? _decompFree;
ffi.NativeFinalizer? _decompressFinalizer;
final Map<int, (int len, int cap)> _pendingDecompressRelease = {};
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
  return _decomp != null && _decompFree != null;
}

/// [algorithm] is `1` = zstd, `2` = lz4 (see Rust `CompressionType`).
Uint8List? columnarDecompressWithNative(
  Uint8List compressed,
  int algorithm,
) {
  _bindOnce();
  final d = _decomp;
  final freeFn = _decompFree;
  if (d == null || freeFn == null) {
    return null;
  }
  final inLen = compressed.lengthInBytes;
  if (inLen > 0x7fffffff) {
    return null;
  }
  var inP = ffi.Pointer<ffi.Uint8>.fromAddress(0);
  var inOwned = false;
  if (inLen > 0) {
    inP = malloc<ffi.Uint8>(inLen);
    inOwned = true;
    inP.asTypedList(inLen).setAll(0, compressed);
  }
  final outP = malloc<ffi.Pointer<ffi.Uint8>>();
  outP.value = ffi.Pointer<ffi.Uint8>.fromAddress(0);
  final oLen = malloc<ffi.Uint32>();
  final oCap = malloc<ffi.Uint32>();
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
      final view = ptr.asTypedList(len);
      final owner = _DecompressZeroCopyOwner(ptr.address);
      try {
        _decompressZeroCopyOwners[view] = owner;
        _decompressFinalizer!.attach(
          owner,
          ptr.cast(),
          detach: owner,
          externalSize: len,
        );
      } on Object {
        freeFn(ptr, len, cap);
        rethrow;
      }
      _pendingDecompressRelease[ptr.address] = (len, cap);
      return view;
    }
    final out = Uint8List.fromList(ptr.asTypedList(len));
    freeFn(ptr, len, cap);
    return out;
  } finally {
    if (inOwned) {
      malloc.free(inP);
    }
    malloc.free(outP);
    malloc.free(oLen);
    malloc.free(oCap);
  }
}

void _columnarDecompressNativeFree(ffi.Pointer<ffi.Void> pointer) {
  final ptr = pointer.cast<ffi.Uint8>();
  final meta = _pendingDecompressRelease.remove(ptr.address);
  final freeFn = _decompFree;
  if (meta != null && freeFn != null) {
    freeFn(ptr, meta.$1, meta.$2);
  }
}

void _bindOnce() {
  if (_tried) {
    return;
  }
  _tried = true;
  try {
    final lib = loadOdbcLibrary();
    _decomp = lib
        .lookup<ffi.NativeFunction<_OdbcDecompressC>>(
          'odbc_columnar_decompress',
        )
        .asFunction<_OdbcDecompressD>();
    _decompFree = lib
        .lookup<ffi.NativeFunction<_OdbcDecompressFreeC>>(
          'odbc_columnar_decompress_free',
        )
        .asFunction<_OdbcDecompressFreeD>();
    _decompressFinalizer = ffi.NativeFinalizer(
      ffi.Pointer.fromFunction(_columnarDecompressNativeFree),
    );
  } on Object {
    _decomp = null;
    _decompFree = null;
    _decompressFinalizer = null;
  }
}

void resetColumnarDecompressForTest() {
  _tried = false;
  _decomp = null;
  _decompFree = null;
  _decompressFinalizer = null;
  _pendingDecompressRelease.clear();
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
  _columnarDecompressNativeFree(
    ffi.Pointer<ffi.Void>.fromAddress(owner.pointerAddress),
  );
}
