import 'dart:io';

import 'package:dotenv/dotenv.dart';

DotEnv? _testEnv;

String _envPath() {
  return '${Directory.current.path}${Platform.pathSeparator}.env';
}

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
  return Platform.environment[key];
}
