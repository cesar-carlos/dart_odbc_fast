import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/columnar_decompress_ffi.dart';

Future<void> main(List<String> args) async {
  final fixture = File(args.first).readAsBytesSync();
  final expectCopy = args.contains('--expect-copy');
  if (args.contains('--fault-registration')) {
    if (columnarDecompressAllocationCountForTest() == null) {
      throw StateError('Allocation diagnostics required for fault test');
    }
    for (final stage in ['create_view', 'register_view']) {
      for (var attempt = 0; attempt < 100; attempt++) {
        setColumnarDecompressRegistrationHookForTest((currentStage) {
          if (currentStage == stage) {
            throw Exception('Injected $stage failure');
          }
        });
        var failed = false;
        try {
          columnarDecompressWithNative(fixture, 1);
        } on Exception {
          failed = true;
        } finally {
          setColumnarDecompressRegistrationHookForTest(null);
        }
        if (!failed) throw StateError('Missing injected $stage failure');
        assertNoNativeAllocations();
      }
    }
    for (var attempt = 0; attempt < 100; attempt++) {
      final bytes = columnarDecompressWithNative(fixture, 1)!;
      releaseColumnarDecompressZeroCopyViewForTest(bytes);
      releaseColumnarDecompressZeroCopyViewForTest(bytes);
      assertNoNativeAllocations();
    }
  }
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
    await waitForNativeFinalizers();
  }
}

Future<void> waitForNativeFinalizers() async {
  final timer = Stopwatch()..start();
  while (true) {
    final count = columnarDecompressAllocationCountForTest();
    if (count == null || count == 0) return;
    if (timer.elapsed >= const Duration(seconds: 5)) {
      throw StateError('Finalizers left $count native allocations');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

void assertNoNativeAllocations() {
  final count = columnarDecompressAllocationCountForTest();
  if (count != null && count != 0) {
    throw StateError('Native allocations retained: $count');
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
