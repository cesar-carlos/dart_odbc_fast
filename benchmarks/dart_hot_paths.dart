import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/helpers/query_result_access.dart';
import 'package:odbc_fast/infrastructure/native/protocol/frame_accumulator.dart';
import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';
import 'package:odbc_fast/infrastructure/native/protocol/protocol_byte_accumulator.dart';

/// Deterministic Dart-only scenarios; no driver, DSN or native library needed.
void main(List<String> args) {
  final results = <String, List<int>>{};
  final allocated = <String, int>{};
  final copied = <String, int>{};
  var checksum = 0;
  void measure(String name, int Function() action, {int rounds = 8}) {
    final samples = <int>[];
    final before = ProtocolByteAccumulator.allocatedBackingBytes;
    for (var sample = -6; sample < 15; sample++) {
      final timer = Stopwatch()..start();
      for (var round = 0; round < rounds; round++) {
        checksum += action();
      }
      if (sample >= 0) samples.add(timer.elapsedMicroseconds);
    }
    results[name] = samples;
    allocated[name] = ProtocolByteAccumulator.allocatedBackingBytes - before;
  }

  for (final config in [
    (500, 32),
    (2000, 32),
    (8000, 32),
    (16, 65536),
    (1, 65536)
  ]) {
    final bytes = Uint8List(config.$1 * config.$2)
      ..fillRange(0, config.$1 * config.$2, 65);
    measure('frames_${config.$1}x${config.$2}', () {
      final accumulator = ProtocolByteAccumulator()..add(bytes);
      var sum = 0;
      for (var i = 0; i < config.$1; i++) {
        sum += accumulator.take(config.$2)[0];
      }
      return sum;
    }, rounds: config.$1 == 1 ? 64 : 8);
  }

  final fragmented = Uint8List(1000 * 32);
  measure('fragmented_13_byte_chunks', () {
    final accumulator = ProtocolByteAccumulator();
    var sum = 0;
    for (var start = 0; start < fragmented.length; start += 13) {
      accumulator.add(Uint8List.sublistView(
          fragmented, start, (start + 13).clamp(0, fragmented.length)));
      while (accumulator.length >= 32) sum += accumulator.take(32).length;
    }
    return sum;
  });

  for (final size in [128 * 1024, 256 * 1024, 512 * 1024, 1024 * 1024]) {
    final frame = Uint8List(size);
    ByteData.sublistView(frame)
      ..setUint32(0, 0x4F444243, Endian.little)
      ..setUint16(4, 1, Endian.little)
      ..setUint32(12, size - 16, Endian.little);
    final name = 'framing_fragmented_${size}_1k';
    measure(name, () {
      final accumulator = BinaryFrameAccumulator();
      var length = 0;
      for (var offset = 0; offset < size; offset += 1024) {
        accumulator.add(Uint8List.sublistView(frame, offset, offset + 1024));
        for (final complete in accumulator.drainFrames()) {
          length += complete.length;
        }
      }
      copied[name] = accumulator.bytesCopied;
      return length;
    }, rounds: 1);
  }

  final textBytes = Uint8List(2000 * 32)..fillRange(0, 2000 * 32, 65);
  measure('retained_lazy_text', () {
    final accumulator = ProtocolByteAccumulator()..add(textBytes);
    final texts = <LazyString>[];
    while (accumulator.length >= 32)
      texts.add(LazyString(accumulator.take(32)));
    accumulator.add(Uint8List(textBytes.length));
    return texts.fold(0, (sum, text) => sum + text.value.length);
  });

  final result = QueryResult(
      columns: List.generate(256, (i) => 'column_$i'),
      rows: [List<int>.generate(256, (i) => i)],
      rowCount: 1);
  final read = args.contains('--linear') ? result.cell : result.reader().cell;
  measure('column_lookup', () {
    var sum = 0;
    for (var i = 0; i < 20000; i++)
      sum += read(0, 'COLUMN_255', ignoreCase: true)! as int;
    return sum;
  });
  print(jsonEncode({
    'samplesMicros': results,
    'checksum': checksum,
    'allocatedBackingBytes': allocated,
    'pendingBytesCopied': copied
  }));
}
