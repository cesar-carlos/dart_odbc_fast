import 'dart:io';

import 'package:dotenv/dotenv.dart';

DotEnv? _testEnv;

String _envPath() {
  final sep = Platform.pathSeparator;
  var current = Directory.current;

  while (true) {
    final candidatePath = '${current.path}$sep.env';
    if (File(candidatePath).existsSync()) {
      return candidatePath;
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      break;
    }
    current = parent;
  }

  return '${Directory.current.path}$sep.env';
}

const int kInvalidConnectionId = 999;

void loadTestEnv() {
  final envPath = _envPath();
  final envFile = File(envPath);
  if (envFile.existsSync()) {
    _testEnv = DotEnv(includePlatformEnvironment: true)..load([envPath]);
  }
}

String? getTestEnv(String key) {
  final v = _testEnv?.map[key];
  if (v != null && v.isNotEmpty) {
    return v;
  }
  final platformValue = Platform.environment[key];
  if (platformValue != null && platformValue.isNotEmpty) {
    return platformValue;
  }
  return null;
}

bool isE2eEnabled() {
  final raw = getTestEnv('ENABLE_E2E_TESTS');
  final parsed = _parseEnvBool(raw);
  return parsed ?? false;
}

bool? _parseEnvBool(String? raw) {
  if (raw == null) return null;
  final normalized = raw.trim().toLowerCase();
  if (normalized.isEmpty) return null;

  switch (normalized) {
    case '1':
    case 'true':
    case 'yes':
    case 'y':
      return true;
    case '0':
    case 'false':
    case 'no':
    case 'n':
      return false;
  }

  return null;
}

/// Database types supported by the ODBC driver
enum DatabaseType {
  sqlServer,
  postgresql,
  mysql,
  oracle,
  sqlite,
  unknown,
}

/// Detects the database type from a connection string (DSN)
DatabaseType detectDatabaseType(String? connectionString) {
  if (connectionString == null || connectionString.isEmpty) {
    return DatabaseType.unknown;
  }

  final lower = connectionString.toLowerCase();

  // Check driver name patterns
  if (lower.contains('sql server') || lower.contains('sqlserver')) {
    return DatabaseType.sqlServer;
  }
  if (lower.contains('postgresql') || lower.contains('postgres')) {
    return DatabaseType.postgresql;
  }
  if (lower.contains('mysql')) {
    return DatabaseType.mysql;
  }
  if (lower.contains('oracle')) {
    return DatabaseType.oracle;
  }
  if (lower.contains('sqlite')) {
    return DatabaseType.sqlite;
  }

  return DatabaseType.unknown;
}

/// Gets the database type from the test environment DSN
DatabaseType getTestDatabaseType() {
  final dsn = getTestEnv('ODBC_TEST_DSN');
  return detectDatabaseType(dsn);
}

/// Returns true if the current test database is one of the specified types
bool isDatabaseType(List<DatabaseType> types) {
  final dbType = getTestDatabaseType();
  return types.contains(dbType);
}

/// Returns a skip reason if the test should be skipped for the current database
String? skipIfDatabase(
  List<DatabaseType> skipFor, {
  String? reason,
}) {
  final dbType = getTestDatabaseType();
  if (skipFor.contains(dbType)) {
    final dbName = dbType.toString().split('.').last;
    return reason ?? 'Not supported on $dbName';
  }
  return null;
}

/// Returns a skip reason if the test should ONLY run on specific databases
String? skipUnlessDatabase(
  List<DatabaseType> onlyFor, {
  String? reason,
}) {
  final dbType = getTestDatabaseType();
  if (!onlyFor.contains(dbType)) {
    final dbNames = onlyFor.map((t) => t.toString().split('.').last).join(', ');
    return reason ?? 'Only supported on: $dbNames';
  }
  return null;
}
