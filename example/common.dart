import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:odbc_fast/odbc_fast.dart';

const _envPath = '.env';

String _exampleEnvPath() =>
    '${Directory.current.path}${Platform.pathSeparator}$_envPath';

String? loadExampleDsn() {
  final path = _exampleEnvPath();
  final file = File(path);

  if (file.existsSync()) {
    final env = DotEnv(includePlatformEnvironment: true)..load([path]);
    final fromFile = env['ODBC_TEST_DSN'];
    if (fromFile != null && fromFile.isNotEmpty) {
      return fromFile;
    }
  }

  final fromEnv =
      Platform.environment['ODBC_TEST_DSN'] ?? Platform.environment['ODBC_DSN'];
  if (fromEnv == null || fromEnv.isEmpty) {
    return null;
  }
  return fromEnv;
}

String? requireExampleDsn() {
  final dsn = loadExampleDsn();
  if (dsn == null || dsn.isEmpty) {
    AppLogger.warning(
      'ODBC_TEST_DSN (or ODBC_DSN) not set. '
      'Create .env with ODBC_TEST_DSN=... or set environment variable. '
      'Skipping DB-dependent example.',
    );
    return null;
  }
  return dsn;
}
