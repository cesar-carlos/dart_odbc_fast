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
