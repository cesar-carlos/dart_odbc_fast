import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final options = _CompareOptions.parse(args);
  if (options == null) {
    stderr.writeln(
      'Usage: dart run tool/compare_benchmark_baseline.dart '
      '--baseline <file.json> --current <file.json> '
      '[--max-regression-percent 30] '
      '[--max-p95-regression-percent 30] '
      '[--max-fallbacks-delta 5] '
      '[--strict-scenarios]',
    );
    exitCode = 64;
    return;
  }

  final baseline = _loadResults(options.baselinePath);
  final current = _loadResults(options.currentPath);
  final regressions = <String>[];

  if (options.strictScenarios) {
    for (final scenario in current.keys) {
      if (!baseline.containsKey(scenario)) {
        regressions.add(
          'Strict mode: current has extra scenario "$scenario" not in baseline',
        );
      }
    }
  }

  for (final entry in baseline.entries) {
    final scenario = entry.key;
    final baselineResult = entry.value;
    final currentResult = current[scenario];
    if (currentResult == null) {
      regressions.add('Missing current scenario "$scenario"');
      continue;
    }

    final baselineElapsed = baselineResult.elapsedMs;
    final currentElapsed = currentResult.elapsedMs;
    if (baselineElapsed > 0 && currentElapsed > 0) {
      final maxElapsed = baselineElapsed * (1 + options.maxRegression / 100);
      if (currentElapsed > maxElapsed) {
        regressions.add(
          '$scenario elapsed regressed: ${currentElapsed}ms vs '
          '${baselineElapsed}ms baseline',
        );
      }
    }

    final baselineRowsPerSecond = baselineResult.rowsPerSecond;
    final currentRowsPerSecond = currentResult.rowsPerSecond;
    if (baselineRowsPerSecond > 0 && currentRowsPerSecond > 0) {
      final minRowsPerSecond =
          baselineRowsPerSecond * (1 - options.maxRegression / 100);
      if (currentRowsPerSecond < minRowsPerSecond) {
        regressions.add(
          '$scenario throughput regressed: '
          '${currentRowsPerSecond.toStringAsFixed(0)} rows/s vs '
          '${baselineRowsPerSecond.toStringAsFixed(0)} rows/s baseline',
        );
      }
    }

    final baselineQps = baselineResult.queriesPerSecond;
    final currentQps = currentResult.queriesPerSecond;
    if (baselineQps > 0 && currentQps > 0) {
      final minQps = baselineQps * (1 - options.maxRegression / 100);
      if (currentQps < minQps) {
        regressions.add(
          '$scenario queries/s regressed: '
          '${currentQps.toStringAsFixed(0)} vs '
          '${baselineQps.toStringAsFixed(0)} baseline',
        );
      }
    }

    final baselineP95 = baselineResult.latencyP95Micros;
    final currentP95 = currentResult.latencyP95Micros;
    if (baselineP95 > 0 && currentP95 > 0) {
      final maxP95 = baselineP95 * (1 + options.maxP95Regression / 100);
      if (currentP95 > maxP95) {
        regressions.add(
          '$scenario latencyP95Micros regressed: $currentP95 vs '
          '$baselineP95 baseline',
        );
      }
    }

    final baselineFb = baselineResult.fallbacksToBlocking;
    final currentFb = currentResult.fallbacksToBlocking;
    final delta = currentFb - baselineFb;
    if (delta > options.maxFallbacksDelta) {
      regressions.add(
        '$scenario fallbacksToBlocking regressed: $currentFb vs '
        '$baselineFb baseline (delta $delta, max allowed '
        '${options.maxFallbacksDelta})',
      );
    }
  }

  if (regressions.isEmpty) {
    stdout.writeln(
      'Benchmark comparison passed: ${baseline.length} scenario(s), '
      'max regression ${options.maxRegression.toStringAsFixed(1)}%, '
      'max p95 regression ${options.maxP95Regression.toStringAsFixed(1)}%, '
      'max fallbacks delta ${options.maxFallbacksDelta}.',
    );
    return;
  }

  stderr.writeln('Benchmark comparison failed:');
  for (final regression in regressions) {
    stderr.writeln('- $regression');
  }
  exitCode = 1;
}

Map<String, _BenchmarkRecord> _loadResults(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! List<Object?>) {
    throw FormatException('Expected a JSON list in $path');
  }

  final results = <String, _BenchmarkRecord>{};
  for (final item in decoded) {
    if (item is! Map<String, Object?>) {
      continue;
    }
    final scenario = item['scenario'];
    if (scenario is! String || scenario.isEmpty) {
      continue;
    }
    results[scenario] = _BenchmarkRecord(
      elapsedMs: _readNumber(item['elapsedMs']).toDouble(),
      rowsPerSecond: _readNumber(item['rowsPerSecond']).toDouble(),
      queriesPerSecond: _readNumber(item['queriesPerSecond']).toDouble(),
      latencyP95Micros: _readNumber(item['latencyP95Micros']).toInt(),
      fallbacksToBlocking: _readNumber(item['fallbacksToBlocking']).toInt(),
    );
  }
  return results;
}

num _readNumber(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value) ?? 0;
  return 0;
}

final class _CompareOptions {
  const _CompareOptions({
    required this.baselinePath,
    required this.currentPath,
    required this.maxRegression,
    required this.maxP95Regression,
    required this.maxFallbacksDelta,
    required this.strictScenarios,
  });

  static _CompareOptions? parse(List<String> args) {
    String? baselinePath;
    String? currentPath;
    var maxRegression = 30.0;
    var maxP95Regression = 30.0;
    var maxFallbacksDelta = 5.0;
    var strictScenarios = false;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--baseline' && i + 1 < args.length) {
        baselinePath = args[++i];
        continue;
      }
      if (arg == '--current' && i + 1 < args.length) {
        currentPath = args[++i];
        continue;
      }
      if (arg == '--max-regression-percent' && i + 1 < args.length) {
        maxRegression = double.tryParse(args[++i]) ?? maxRegression;
        continue;
      }
      if (arg == '--max-p95-regression-percent' && i + 1 < args.length) {
        maxP95Regression = double.tryParse(args[++i]) ?? maxP95Regression;
        continue;
      }
      if (arg == '--max-fallbacks-delta' && i + 1 < args.length) {
        maxFallbacksDelta = double.tryParse(args[++i]) ?? maxFallbacksDelta;
        continue;
      }
      if (arg == '--strict-scenarios') {
        strictScenarios = true;
        continue;
      }
    }

    if (baselinePath == null || currentPath == null) {
      return null;
    }
    return _CompareOptions(
      baselinePath: baselinePath,
      currentPath: currentPath,
      maxRegression: maxRegression < 0 ? 0 : maxRegression,
      maxP95Regression: maxP95Regression < 0 ? 0 : maxP95Regression,
      maxFallbacksDelta: maxFallbacksDelta < 0 ? 0 : maxFallbacksDelta,
      strictScenarios: strictScenarios,
    );
  }

  final String baselinePath;
  final String currentPath;
  final double maxRegression;
  final double maxP95Regression;
  final double maxFallbacksDelta;
  final bool strictScenarios;
}

final class _BenchmarkRecord {
  const _BenchmarkRecord({
    required this.elapsedMs,
    required this.rowsPerSecond,
    required this.queriesPerSecond,
    required this.latencyP95Micros,
    required this.fallbacksToBlocking,
  });

  final double elapsedMs;
  final double rowsPerSecond;
  final double queriesPerSecond;
  final int latencyP95Micros;
  final int fallbacksToBlocking;
}
