import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';

import '../test/helpers/worker_metrics_fixture.dart';

// Run unchanged against baseline and candidate using the same warmed-up Dart VM.
void main() {
  final results = <String, List<double>>{};
  var checksum = 0;
  void measure(String name, int Function() action) {
    final warmup = Stopwatch()..start();
    var iterations = 0;
    while (warmup.elapsedMilliseconds < 400) {
      checksum ^= action();
      iterations++;
    }
    final rounds = (iterations ~/ 8).clamp(1, 100000);
    final samples = <double>[];
    for (var sample = 0; sample < 21; sample++) {
      final timer = Stopwatch()..start();
      for (var i = 0; i < rounds; i++) {
        checksum ^= action();
      }
      timer.stop();
      samples.add(timer.elapsedTicks * 1e6 / timer.frequency / rounds);
    }
    results[name] = samples;
  }

  for (final rows in [8, 1024, 16384]) {
    for (final width in [1, 8]) {
      for (final nullable in [false, true]) {
        final result = TypedColumnarResult(
          rowCount: rows,
          columns: List.generate(width, (c) {
            final bitmap = Uint8List((rows + 7) ~/ 8);
            if (nullable) bitmap.fillRange(0, bitmap.length, 0x55);
            return switch (c % 4) {
              0 => TypedColumnInt32(
                  name: 'c$c',
                  values: Int32List.fromList(List.generate(rows, (r) => r)),
                  nullBitmap: bitmap),
              1 => TypedColumnInt64(
                  name: 'c$c', values: Int64List(rows), nullBitmap: bitmap),
              2 => TypedColumnFloat64(
                  name: 'c$c', values: Float64List(rows), nullBitmap: bitmap),
              _ => TypedColumnObject<String>(
                  name: 'c$c',
                  kind: TypedColumnKind.string,
                  values: List.generate(
                      rows, (r) => nullable && r.isEven ? null : 'value$r')),
            };
          }),
        );
        final check = fromTypedColumnar(result);
        if (check.rows.length != rows || check.rows.last.length != width)
          throw StateError('shape');
        measure('columnar_${rows}x${width}_nulls_$nullable', () {
          final converted = fromTypedColumnar(result);
          return converted.rows.last.first as int;
        });
      }
    }
  }
  for (final count in [1, 4, 16, 64]) {
    final fixture = WorkerMetricsFixture(count);
    final read = fixture.connection.getWorkerPoolStats;
    var sequence = 0;
    measure('snapshot_cached_$count', () => read().totalRouted);
    measure('snapshot_updated_$count', () {
      fixture.update(sequence++ % 1009);
      return read().latencyP95Micros;
    });
    fixture.dispose();
  }
  print(
      jsonEncode({'samplesMicrosPerOperation': results, 'checksum': checksum}));
}
