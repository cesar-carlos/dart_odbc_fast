import 'load_env.dart';

const int defaultLiveQueryRowLimit = 5000;
const String fullTableScanEnvKey = 'MY_TEST_FULL_TABLE_SCAN';
const String liveQueryRowLimitEnvKey = 'MY_TEST_ROW_LIMIT';

bool get liveFullTableScanEnabled {
  final raw = getTestEnv(fullTableScanEnvKey);
  if (raw == null) return false;
  switch (raw.trim().toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'y':
      return true;
  }
  return false;
}

int readLiveQueryRowLimit([int fallback = defaultLiveQueryRowLimit]) {
  final raw = getTestEnv(liveQueryRowLimitEnvKey);
  if (raw == null || raw.trim().isEmpty) {
    return fallback;
  }
  final parsed = int.tryParse(raw.trim());
  if (parsed == null || parsed < 1) {
    return fallback;
  }
  return parsed;
}

String sqlServerSelectMaybeLimited(
  String tableName, {
  int? rowLimit,
}) {
  if (liveFullTableScanEnabled) {
    return 'SELECT * FROM $tableName';
  }

  final limit = rowLimit ?? readLiveQueryRowLimit();
  return 'SELECT TOP $limit * FROM $tableName';
}

/// Metrics from a single live streamed SELECT.
class LiveSelectTiming {
  const LiveSelectTiming({
    required this.label,
    required this.sql,
    required this.rowCount,
    required this.elapsedMs,
    required this.chunkCount,
  });

  final String label;
  final String sql;
  final int rowCount;
  final int elapsedMs;
  final int chunkCount;

  double get durationSec => elapsedMs / 1000.0;

  double get rowsPerSec => durationSec > 0 ? rowCount / durationSec : 0.0;
}

void printLiveSelectTiming(LiveSelectTiming timing) {
  print('');
  print('[SELECT TIMING] ${timing.label}');
  print('  SQL        : ${timing.sql}');
  print('  Rows       : ${timing.rowCount}');
  print(
    '  Duration   : ${timing.durationSec.toStringAsFixed(3)} s '
    '(${timing.elapsedMs} ms)',
  );
  print('  Throughput : ${timing.rowsPerSec.toStringAsFixed(0)} rows/s');
  print('  Chunks     : ${timing.chunkCount}');
}

void printLiveSelectTimingSummary(List<LiveSelectTiming> timings) {
  if (timings.isEmpty) {
    return;
  }

  var labelWidth = 'Select'.length;
  for (final timing in timings) {
    if (timing.label.length > labelWidth) {
      labelWidth = timing.label.length;
    }
  }

  print('');
  print('========== SELECT TIMING SUMMARY ==========');
  print(
    '${'Select'.padRight(labelWidth)} | '
    '${'Rows'.padLeft(8)} | '
    '${'Time (s)'.padLeft(10)} | '
    '${'ms'.padLeft(8)} | '
    '${'rows/s'.padLeft(10)}',
  );
  print(
    '${'-' * labelWidth}-+-'
    '${'-' * 8}-+-'
    '${'-' * 10}-+-'
    '${'-' * 8}-+-'
    '${'-' * 10}',
  );

  var totalMs = 0;
  var totalRows = 0;
  for (final timing in timings) {
    totalMs += timing.elapsedMs;
    totalRows += timing.rowCount;
    print(
      '${timing.label.padRight(labelWidth)} | '
      '${timing.rowCount.toString().padLeft(8)} | '
      '${timing.durationSec.toStringAsFixed(3).padLeft(10)} | '
      '${timing.elapsedMs.toString().padLeft(8)} | '
      '${timing.rowsPerSec.toStringAsFixed(0).padLeft(10)}',
    );
  }

  print(
    '${'-' * labelWidth}-+-'
    '${'-' * 8}-+-'
    '${'-' * 10}-+-'
    '${'-' * 8}-+-'
    '${'-' * 10}',
  );
  print(
    '${'TOTAL'.padRight(labelWidth)} | '
    '${totalRows.toString().padLeft(8)} | '
    '${(totalMs / 1000).toStringAsFixed(3).padLeft(10)} | '
    '${totalMs.toString().padLeft(8)} |',
  );
  print(
    'fullScan=$liveFullTableScanEnabled, '
    'rowLimit=${readLiveQueryRowLimit()}',
  );
  print('===========================================');
}
