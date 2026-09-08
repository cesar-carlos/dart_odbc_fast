import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:odbc_fast/infrastructure/native/bindings/native_byte_view.dart';
import 'package:test/test.dart';

final class _TestNativeOwner implements ffi.Finalizable {}

void main() {
  test('falls back cleanly for Dart-owned bytes', () {
    final view = NativeByteView.fromBytes(Uint8List.fromList([1, 2, 3]));

    expect(view.hasNativeBacking, isFalse);
    expect(view.pointerAt(0), isNull);
    expect(view.slice(1, 3).bytes, equals([2, 3]));
  });

  test('preserves native pointer offsets through slices', () {
    final pointer = malloc<ffi.Uint8>(6);
    final bytes = pointer.asTypedList(6)..setAll(0, [10, 11, 12, 13, 14, 15]);
    final owner = _TestNativeOwner();
    registerNativeByteBacking(bytes, pointer, owner);

    try {
      final slice = NativeByteView.fromBytes(bytes).slice(2, 5);
      final nestedSlice = NativeByteView.fromBytes(slice.bytes).slice(1, 3);

      expect(slice.hasNativeBacking, isTrue);
      expect(slice.pointerAt(0)!.address, (pointer + 2).address);
      expect(nestedSlice.pointerAt(0)!.address, (pointer + 3).address);
      expect(nestedSlice.bytes, equals([13, 14]));
    } finally {
      malloc.free(pointer);
    }
  });
}
