import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final options = _CompareOptions.parse(args);
  if (options == null) {
    stderr.writeln(
      'Usage: dart run tool/compare_benchmark_baseline.dart '
      '--baseline <file.json> --current <file.json> '
      '[--max-regression-percent 30]',
    );
    exitCode = 64;
    return;
  }

  final baseline = _loadResults(options.baselinePath);
  final current = _loadResults(options.currentPath);
  final regressions = <String>[];

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
  }

  if (regressions.isEmpty) {
    stdout.writeln(
      'Benchmark comparison passed: ${baseline.length} scenario(s), '
      'max regression ${options.maxRegression.toStringAsFixed(1)}%.',
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
  });

  static _CompareOptions? parse(List<String> args) {
    String? baselinePath;
    String? currentPath;
    var maxRegression = 30.0;

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
      }
    }

    if (baselinePath == null || currentPath == null) {
      return null;
    }
    return _CompareOptions(
      baselinePath: baselinePath,
      currentPath: currentPath,
      maxRegression: maxRegression < 0 ? 0 : maxRegression,
    );
  }

  final String baselinePath;
  final String currentPath;
  final double maxRegression;
}

final class _BenchmarkRecord {
  const _BenchmarkRecord({
    required this.elapsedMs,
    required this.rowsPerSecond,
  });

  final double elapsedMs;
  final double rowsPerSecond;
}
