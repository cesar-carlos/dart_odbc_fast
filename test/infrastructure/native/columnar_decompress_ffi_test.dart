import 'dart:io';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/ffi_buffer_helper.dart'
    show zeroCopyResultThresholdBytes;
import 'package:odbc_fast/infrastructure/native/columnar_decompress_ffi.dart';
import 'package:test/test.dart';

/// zstd (level 3) of `hello` — matches `odbc_engine` `compress(..., Zstd)`.
/// Regenerate with zstd level 3, e.g. Python:
/// `z.ZstdCompressor(3).compress(b'hello')`.
const _smallZstdHello = <int>[
  40,
  181,
  47,
  253,
  32,
  5,
  41,
  0,
  0,
  104,
  101,
  108,
  108,
  111,
];

/// Large zstd payload decompressing to ≥ [zeroCopyResultThresholdBytes].
/// Regenerate: compress a ≥32 KiB repetitive UTF-8 phrase with zstd level 3
/// (same as `native/odbc_engine` `compress(..., Zstd)`).
void main() {
  resetColumnarDecompressForTest();
  final nativeAvailable = isColumnarNativeDecompressAvailable;
  final skipNative =
      nativeAvailable ? null : 'odbc_columnar_decompress symbols not loaded';

  test('isColumnarNativeDecompressAvailable is bool', () {
    expect(isColumnarNativeDecompressAvailable, isA<bool>());
  });

  test(
    'should_return_copied_list_when_decompressed_below_zero_copy_threshold',
    skip: skipNative,
    () {
      final decompressed = columnarDecompressWithNative(
        Uint8List.fromList(_smallZstdHello),
        1,
      );
      expect(decompressed, isNotNull);
      expect(decompressed, hasLength(5));
      expect(decompressed, equals([104, 101, 108, 108, 111]));
      expect(
        isColumnarDecompressZeroCopyViewForTest(decompressed!),
        isFalse,
      );
    },
  );

  test(
    'should_attach_mutable_finalizer_when_decompressed_at_or_above_threshold',
    skip: skipNative,
    () {
      final compressed = _loadLargeZstdFixture();
      final decompressed = columnarDecompressWithNative(compressed, 1);
      expect(decompressed, isNotNull);
      expect(
        decompressed!.length,
        greaterThanOrEqualTo(zeroCopyResultThresholdBytes),
      );
      expect(decompressed.first, equals(0x74)); // 't' from repeated phrase
      expect(isColumnarDecompressZeroCopyViewForTest(decompressed), isTrue);
      releaseColumnarDecompressZeroCopyViewForTest(decompressed);
    },
  );
}

Uint8List _loadLargeZstdFixture() {
  final projectRoot = _findProjectRoot();
  if (projectRoot == null) {
    fail(
      'Could not locate pubspec.yaml; run tests from package root or subdir',
    );
  }
  final golden = File(
    <String>[
      projectRoot,
      'test',
      'fixtures',
      'columnar_decompress_large_zstd.bin',
    ].join(Platform.pathSeparator),
  );
  expect(golden.existsSync(), isTrue, reason: golden.path);
  return golden.readAsBytesSync();
}

String? _findProjectRoot() {
  var dir = Directory.current;
  while (true) {
    final ps = Platform.pathSeparator;
    if (File('${dir.path}${ps}pubspec.yaml').existsSync()) {
      return dir.path;
    }
    if (dir.parent.path == dir.path) {
      return null;
    }
    dir = dir.parent;
  }
}
