// Columnar v2: decompress a column block using the same algorithms as
// `native/odbc_engine` (`odbc_columnar_decompress` / _free`).

// NativeFunction/typedef C shapes are intentionally paired; malloc frees
// are clearer as separate lines than cascades.
// ignore_for_file: avoid_private_typedef_functions, cascade_invocations

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
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
var _tried = false;

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
  if (compressed.lengthInBytes > 0x7fffffff) {
    return null;
  }
  final inP = malloc<ffi.Uint8>(compressed.length);
  inP.asTypedList(compressed.length).setAll(0, compressed);
  final outP = malloc<ffi.Pointer<ffi.Uint8>>();
  outP.value = ffi.Pointer<ffi.Uint8>.fromAddress(0);
  final oLen = malloc<ffi.Uint32>();
  final oCap = malloc<ffi.Uint32>();
  try {
    final st = d(algorithm, inP, compressed.length, outP, oLen, oCap);
    if (st != 0) {
      return null;
    }
    final ptr = outP.value;
    if (ptr.address == 0) {
      return null;
    }
    final len = oLen.value;
    final out = Uint8List.fromList(ptr.asTypedList(len));
    freeFn(ptr, len, oCap.value);
    return out;
  } finally {
    malloc.free(inP);
    malloc.free(outP);
    malloc.free(oLen);
    malloc.free(oCap);
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
  } on Object {
    _decomp = null;
    _decompFree = null;
  }
}

void resetColumnarDecompressForTest() {
  _tried = false;
  _decomp = null;
  _decompFree = null;
}
