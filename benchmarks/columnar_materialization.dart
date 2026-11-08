import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';

import 'columnar_materialization_baseline.dart' as baseline;

// Compile unchanged with dart compile exe against baseline and candidate.
void main() {
  final results = <String, List<double>>{};
  var checksum = 0;
  void measure(String name, int Function() candidate, int Function() original) {
    final warmup = Stopwatch()..start();
    var iterations = 0;
    while (warmup.elapsedMilliseconds < 400) {
      checksum ^= candidate();
      checksum ^= original();
      iterations++;
    }
    final rounds = (iterations ~/ 8).clamp(1, 100000);
    final before = <double>[];
    final after = <double>[];
    double timed(int Function() action) {
      final timer = Stopwatch()..start();
      for (var i = 0; i < rounds; i++) {
        checksum ^= action();
      }
      timer.stop();
      return timer.elapsedTicks * 1e6 / timer.frequency / rounds;
    }

    for (var sample = 0; sample < 31; sample++) {
      if (sample.isEven) {
        before.add(timed(original));
        after.add(timed(candidate));
      } else {
        after.add(timed(candidate));
        before.add(timed(original));
      }
    }
    results['$name/baseline'] = before;
    results['$name/candidate'] = after;
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
        }, () {
          final converted = baseline.fromTypedColumnar(result);
          return converted.rows.last.first as int;
        });
      }
    }
  }
  print(
      jsonEncode({'samplesMicrosPerOperation': results, 'checksum': checksum}));
}
