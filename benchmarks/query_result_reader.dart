import 'dart:convert';

import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/helpers/query_result_access.dart';

import 'query_result_reader_baseline.dart';

Object? retainedReader;

// AOT paired comparison; alternating order reduces environmental drift.
void main() {
  final results = <String, Object>{};
  var checksum = 0;
  void measure(String name, int Function() before, int Function() after) {
    final warmup = Stopwatch()..start();
    var count = 0;
    while (warmup.elapsedMilliseconds < 300) {
      checksum ^= before();
      checksum ^= after();
      count++;
    }
    final rounds = (count ~/ 8).clamp(1, 100000);
    double timed(int Function() action) {
      final timer = Stopwatch()..start();
      for (var i = 0; i < rounds; i++) {
        checksum ^= action();
      }
      timer.stop();
      return timer.elapsedTicks * 1e6 / timer.frequency / rounds;
    }

    final baseline = <double>[];
    final candidate = <double>[];
    for (var i = 0; i < 31; i++) {
      if (i.isEven) {
        baseline.add(timed(before));
        candidate.add(timed(after));
      } else {
        candidate.add(timed(after));
        baseline.add(timed(before));
      }
    }
    results[name] = {'baseline': baseline, 'candidate': candidate};
  }

  for (final width in [1, 8, 256]) {
    final result = QueryResult(
      columns: List.generate(width, (i) => 'Column_$i'),
      rows: [List.generate(width, (i) => i)],
      rowCount: 1,
    );
    for (final folded in [false, true]) {
      final key = folded ? 'COLUMN_${width - 1}' : 'Column_${width - 1}';
      measure('construct_${width}_folded_$folded', () {
        final reader = BaselineQueryResultReader(result);
        retainedReader = reader;
        return reader.columnIndex(key, ignoreCase: folded)!;
      }, () {
        final reader = QueryResultReader(result);
        retainedReader = reader;
        return reader.columnIndex(key, ignoreCase: folded)!;
      });
      final baseline = BaselineQueryResultReader(result);
      final candidate = QueryResultReader(result);
      if (candidate.columnIndex(key, ignoreCase: folded) != width - 1) {
        throw StateError('Unexpected column index');
      }
      measure(
          'reuse_${width}_folded_$folded',
          () => baseline.columnIndex(key, ignoreCase: folded)!,
          () => candidate.columnIndex(key, ignoreCase: folded)!);
    }
  }
  print(jsonEncode({
    'unit': 'microseconds_per_operation',
    'samples': results,
    'checksum': checksum
  }));
}
