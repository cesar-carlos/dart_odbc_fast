// Streaming performance benchmark for streamQuery and streamQueryBatched.
// Run: dart run example/streaming_performance_benchmark.dart

import 'dart:convert';
import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:odbc_fast/odbc_fast_native.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) return;

  final query = _envOr('ODBC_STREAM_BENCH_QUERY', 'SELECT 1 AS value');
  final fetchSize = _envInt('ODBC_STREAM_BENCH_FETCH_SIZE', 1000);
  final chunkSize = _envInt('ODBC_STREAM_BENCH_CHUNK_SIZE', 64 * 1024);

  final native = NativeOdbcConnection();
  if (!native.initialize()) {
    AppLogger.severe('ODBC environment initialization failed');
    return;
  }

  final connId = native.connect(dsn);
  if (connId == 0) {
    AppLogger.severe('Connection failed: ${native.getError()}');
    return;
  }

  try {
    final results = <_StreamingBenchmarkResult>[
      await _benchStreamQuery(
        native,
        connId,
        query,
        chunkSize: chunkSize,
      ),
      await _benchStreamQueryBatched(
        native,
        connId,
        query,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      ),
    ];
    _writeResults(results);
  } finally {
    native.disconnect(connId);
  }
}

Future<_StreamingBenchmarkResult> _benchStreamQuery(
  NativeOdbcConnection native,
  int connId,
  String query, {
  required int chunkSize,
}) async {
  var chunks = 0;
  var rows = 0;
  final stopwatch = Stopwatch()..start();
  await for (final chunk in native.streamQuery(
    connId,
    query,
    chunkSize: chunkSize,
  )) {
    chunks++;
    rows += chunk.rowCount;
  }
  stopwatch.stop();
  return _StreamingBenchmarkResult(
    scenario: 'streamQuery',
    elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
    rows: rows,
    chunks: chunks,
    fetchSize: null,
    chunkSize: chunkSize,
  );
}

Future<_StreamingBenchmarkResult> _benchStreamQueryBatched(
  NativeOdbcConnection native,
  int connId,
  String query, {
  required int fetchSize,
  required int chunkSize,
}) async {
  var chunks = 0;
  var rows = 0;
  final stopwatch = Stopwatch()..start();
  await for (final chunk in native.streamQueryBatched(
    connId,
    query,
    fetchSize: fetchSize,
    chunkSize: chunkSize,
  )) {
    chunks++;
    rows += chunk.rowCount;
  }
  stopwatch.stop();
  return _StreamingBenchmarkResult(
    scenario: 'streamQueryBatched',
    elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
    rows: rows,
    chunks: chunks,
    fetchSize: fetchSize,
    chunkSize: chunkSize,
  );
}

void _writeResults(List<_StreamingBenchmarkResult> results) {
  final format = _envOr('ODBC_STREAM_BENCH_OUTPUT', 'text').toLowerCase();
  final outFile = Platform.environment['ODBC_STREAM_BENCH_OUT_FILE'];
  final content = switch (format) {
    'json' => const JsonEncoder.withIndent('  ').convert(
        results.map((result) => result.toJson()).toList(growable: false),
      ),
    'csv' => _toCsv(results),
    _ => _toText(results),
  };

  if (outFile != null && outFile.isNotEmpty) {
    File(outFile).writeAsStringSync(content);
    stdout.writeln('Streaming benchmark results written to $outFile');
  } else {
    stdout.writeln(content);
  }
}

String _toText(List<_StreamingBenchmarkResult> results) {
  return results
      .map(
        (result) => '${result.scenario}: ${result.elapsedMs} ms, '
            'rows=${result.rows}, chunks=${result.chunks}, '
            'rowsPerSecond=${result.rowsPerSecond.toStringAsFixed(0)}, '
            'fetchSize=${result.fetchSize ?? 0}, '
            'chunkSize=${result.chunkSize}',
      )
      .join('\n');
}

String _toCsv(List<_StreamingBenchmarkResult> results) {
  const header =
      'scenario,elapsedMs,rows,chunks,rowsPerSecond,fetchSize,chunkSize';
  final rows = results.map((result) {
    return [
      result.scenario,
      result.elapsedMs,
      result.rows,
      result.chunks,
      result.rowsPerSecond.toStringAsFixed(0),
      result.fetchSize ?? '',
      result.chunkSize,
    ].join(',');
  });
  return [header, ...rows].join('\n');
}

String _envOr(String name, String fallback) {
  final value = Platform.environment[name];
  if (value != null && value.isNotEmpty) return value;
  return fallback;
}

int _envInt(String name, int fallback) {
  final raw = Platform.environment[name];
  if (raw == null || raw.isEmpty) return fallback;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 1) return fallback;
  return parsed;
}

final class _StreamingBenchmarkResult {
  const _StreamingBenchmarkResult({
    required this.scenario,
    required this.elapsedMs,
    required this.rows,
    required this.chunks,
    required this.fetchSize,
    required this.chunkSize,
  });

  final String scenario;
  final double elapsedMs;
  final int rows;
  final int chunks;
  final int? fetchSize;
  final int chunkSize;

  double get rowsPerSecond {
    if (elapsedMs <= 0) return 0;
    return rows / (elapsedMs / 1000);
  }

  Map<String, Object?> toJson() {
    return {
      'scenario': scenario,
      'elapsedMs': elapsedMs,
      'rows': rows,
      'chunks': chunks,
      'rowsPerSecond': rowsPerSecond,
      'fetchSize': fetchSize,
      'chunkSize': chunkSize,
    };
  }
}
