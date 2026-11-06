import 'dart:convert';

import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart';

void main() {
  final columns = List.generate(96, (i) => 'column_$i').join(', ');
  final parameters = List.generate(96, (i) => ':p$i').join(', ');
  final scenarios = <String, (List<String>, int, int)>{
    'cold_no_parameters': (
      List.generate(512, (i) => 'SELECT $columns FROM table_$i'),
      8,
      0,
    ),
    'cold_two_parameters': (
      List.generate(
          512,
          (i) =>
              'SELECT $columns FROM table_$i WHERE id = :id AND parent = @parent'),
      8,
      2,
    ),
    'cold_many_parameters': (
      List.generate(512, (i) => 'INSERT INTO table_$i VALUES ($parameters)'),
      8,
      96,
    ),
    'warm_cache': (
      List.generate(128, (i) => 'SELECT :id FROM hot_table_$i'),
      4096,
      1,
    ),
  };
  var checksum = 0;
  for (final scenario in scenarios.entries) {
    final (queries, rounds, expectedCount) = scenario.value;
    final samples = <int>[];
    for (var sample = -8; sample < 21; sample++) {
      final watch = Stopwatch()..start();
      for (var round = 0; round < rounds; round++) {
        for (final sql in queries) {
          final parsed = NamedParameterParser.extract(sql);
          if (parsed.paramNames.length != expectedCount) {
            throw StateError('Unexpected parameter count');
          }
          checksum += parsed.cleanedSql.length + parsed.paramNames.length;
        }
      }
      watch.stop();
      if (sample >= 0) samples.add(watch.elapsedMicroseconds);
    }
    final sorted = [...samples]..sort();
    print(jsonEncode({
      'scenario': scenario.key,
      'calls': queries.length * rounds,
      'samples_us': samples,
      'median_us': sorted[sorted.length ~/ 2],
      'checksum': checksum,
    }));
  }
}
