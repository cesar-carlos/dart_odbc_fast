import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/columnar_decompress_ffi.dart';

Future<void> main(List<String> args) async {
  final fixture = File(args.first).readAsBytesSync();
  final expectCopy = args.contains('--expect-copy');
  for (var round = 0; round < 10; round++) {
    final done = ReceivePort();
    final errors = ReceivePort();
    await Isolate.spawn(
      decode,
      (done.sendPort, fixture, expectCopy),
      onError: errors.sendPort,
      onExit: done.sendPort,
    );
    final result = await Future.any([
      done.first.then((_) => true),
      errors.first.then((error) => throw StateError('$error')),
    ]).timeout(const Duration(seconds: 30));
    if (!result) throw StateError('decoder isolate did not finish');
    done.close();
    errors.close();
  }
}

void decode((SendPort, Uint8List, bool) input) {
  for (var i = 0; i < 100; i++) {
    final bytes = columnarDecompressWithNative(input.$2, 1);
    if (bytes == null || bytes.length < 32768 || bytes.first != 0x74) {
      throw StateError('Invalid large decompression');
    }
    if (input.$3 && isColumnarDecompressZeroCopyViewForTest(bytes)) {
      throw StateError('Legacy engine must use a copy');
    }
    // Allocations become unreachable; GC and isolate exit run native cleanup.
  }
}
