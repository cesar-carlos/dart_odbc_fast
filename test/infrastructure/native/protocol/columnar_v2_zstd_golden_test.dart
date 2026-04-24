import 'dart:io';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/columnar_decompress_ffi.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:test/test.dart';

/// Golden buffer from Rust:
/// `native/odbc_engine/tests/columnar_v2_zstd_golden_file.rs` (regenerate:
/// `UPDATE_GOLDEN=1` with that test).
void main() {
  test(
    'columnar v2 zstd golden parses when native decompress FFI is available',
    () {
      resetColumnarDecompressForTest();
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

      if (!isColumnarNativeDecompressAvailable) {
        // Linux CI / no local DLL: golden still checked by the Rust *sync* test.
        return;
      }

      final parsed = BinaryProtocolParser.parse(Uint8List.fromList(data));
      expect(parsed.rowCount, 30);
      expect(parsed.columnCount, 1);
      expect(parsed.columns[0].name, 'n');
      for (var i = 0; i < 30; i++) {
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
