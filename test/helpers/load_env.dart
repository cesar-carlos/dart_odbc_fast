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
