import 'dart:io';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/columnar_decompress_ffi.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:test/test.dart';

/// Golden buffer from Rust:
/// `native/odbc_engine/tests/columnar_v2_zstd_golden_file.rs` (regenerate:
/// `UPDATE_GOLDEN=1` with that test). The fixture row count is chosen by the
/// Rust test to exceed the compression threshold and force the zstd path.
void main() {
  resetColumnarDecompressForTest();
  final skipNative = isColumnarNativeDecompressAvailable
      ? null
      : 'odbc_columnar_decompress symbols not loaded (Rust golden test covers '
          'encoding)';

  // Single-segment zstd frame. Its one RLE block expands to 512 null markers.
  Uint8List compressedNulls(int rows, {bool mixed = false}) {
    const zstd = [0x28, 0xb5, 0x2f, 0xfd, 0x60, 0, 1, 3, 0x10, 0, 1];
    const intColumnN = [2, 0, 1, 0, 0x6e];
    const intColumnM = [2, 0, 1, 0, 0x6d];
    final payload = BytesBuilder()
      ..add(intColumnN)
      ..add([1, 1, zstd.length, 0, 0, 0])
      ..add(zstd);
    if (mixed) {
      // Uncompressed m: 511 null markers followed by the int32 value 42.
      payload
        ..add(intColumnM)
        ..add([0, 4, 2, 0, 0])
        ..add(List.filled(511, 1))
        ..add([0, 42, 0, 0, 0]);
    }
    final header = ByteData(BinaryProtocolParser.headerSizeColumnarV2)
      ..setUint32(0, BinaryProtocolParser.magic, Endian.little)
      ..setUint16(
        4,
        BinaryProtocolParser.protocolVersionColumnarV2,
        Endian.little,
      )
      ..setUint16(8, mixed ? 2 : 1, Endian.little)
      ..setUint32(10, rows, Endian.little)
      ..setUint8(14, 1)
      ..setUint32(15, payload.length, Endian.little);
    return Uint8List.fromList(
      [...header.buffer.asUint8List(), ...payload.takeBytes()],
    );
  }

  test('should_preserve_column_order_with_mixed_compression', skip: skipNative,
      () {
    final data = compressedNulls(512, mixed: true);
    final rows = BinaryProtocolParser.parse(data).rows;
    expect(rows.first, [null, null]);
    expect(rows.last, [null, 42]);
    final typed = BinaryProtocolParser.parseColumnarToTyped(data);
    expect(typed.columns.map((c) => c.name), ['n', 'm']);
    expect(typed.columns.last.isNullAt(510), isTrue);
    expect(typed.columns.last.isNullAt(511), isFalse);
  });

  test('should_decode_more_rows_than_compressed_bytes', skip: skipNative, () {
    final data = compressedNulls(512);
    final rows = BinaryProtocolParser.parse(data).rows;
    expect(rows, hasLength(512));
    expect(rows, everyElement(equals([null])));
    final typed = BinaryProtocolParser.parseColumnarToTyped(data);
    expect(typed.rowCount, 512);
    expect(typed.columns.single.isNullAt(511), isTrue);
  });

  test('should_require_one_null_marker_per_row_after_decompression',
      skip: skipNative, () {
    final data = compressedNulls(513);
    expect(() => BinaryProtocolParser.parse(data), throwsFormatException);
    expect(
      () => BinaryProtocolParser.parseColumnarToTyped(data),
      throwsFormatException,
    );
  });

  test(
    'should_parse_columnar_v2_zstd_golden_when_native_decompress_available',
    skip: skipNative,
    () {
      final projectRoot = _findProjectRoot();
      if (projectRoot == null) {
        fail(
          'Could not locate pubspec.yaml; run tests from package root or '
          'subdir',
        );
      }
      final golden = File(
        <String>[
          projectRoot,
          'test',
          'fixtures',
          'columnar_v2_int32_zstd.golden',
        ].join(Platform.pathSeparator),
      );
      expect(golden.existsSync(), isTrue, reason: golden.path);
      final data = golden.readAsBytesSync();

      const expectedRowCount = 214;
      final parsed = BinaryProtocolParser.parse(Uint8List.fromList(data));
      expect(parsed.rowCount, expectedRowCount);
      expect(parsed.columnCount, 1);
      expect(parsed.columns[0].name, 'n');
      for (var i = 0; i < expectedRowCount; i++) {
        expect(parsed.rows[i][0], i);
      }
    },
  );
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
