import 'dart:convert';

import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

void main() {
  final scenarios = <String, List<ParamValue>>{
    'single_int': [const ParamValueInt32(42)],
    'integers_256': List.generate(
      256,
      (i) => i.isEven ? ParamValueInt32(i) : ParamValueInt64(-i),
    ),
    'mixed_256': List.generate(
      256,
      (i) => switch (i % 4) {
        0 => ParamValueInt32(i),
        1 => const ParamValueString('value-ação'),
        2 => const ParamValueNull(),
        _ => const ParamValueDecimal('123.450'),
      },
    ),
  };
  var checksum = 0;
  for (final scenario in scenarios.entries) {
    final wire = serializeParams(scenario.value);
    final rounds = scenario.value.length == 1 ? 100000 : 2000;
    final samples = <int>[];
    for (var sample = -8; sample < 21; sample++) {
      final watch = Stopwatch()..start();
      for (var round = 0; round < rounds; round++) {
        final decoded = deserializeParamValues(wire);
        checksum += decoded.length + (decoded.first as ParamValueInt32).value;
      }
      watch.stop();
      if (sample >= 0) samples.add(watch.elapsedMicroseconds);
    }
    final sorted = [...samples]..sort();
    print(jsonEncode({
      'scenario': scenario.key,
      'rounds': rounds,
      'samples_us': samples,
      'median_us': sorted[sorted.length ~/ 2],
      'checksum': checksum,
    }));
  }
}
