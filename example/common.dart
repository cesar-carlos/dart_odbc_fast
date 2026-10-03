import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';

const _envPath = '.env';
const _disableDsnEnv = 'ODBC_EXAMPLE_DISABLE_DSN';

String _exampleEnvPath() =>
    '${Directory.current.path}${Platform.pathSeparator}$_envPath';

String? loadExampleDsn() {
  if (Platform.environment[_disableDsnEnv] == '1') {
    return null;
  }

  final fromEnv = _firstNonEmpty(
    Platform.environment['ODBC_TEST_DSN'],
    Platform.environment['ODBC_DSN'],
  );
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }

  final path = _exampleEnvPath();
  final file = File(path);

  if (file.existsSync()) {
    final env = DotEnv(includePlatformEnvironment: true)..load([path]);
    final fromFile = _firstNonEmpty(env['ODBC_TEST_DSN'], env['ODBC_DSN']);
    if (fromFile != null && fromFile.isNotEmpty) {
      return fromFile;
    }
  }
  return null;
}

String? requireExampleDsn() {
  final dsn = loadExampleDsn();
  if (dsn == null || dsn.isEmpty) {
    const message = 'ODBC_TEST_DSN (or ODBC_DSN) not set. '
        'Create .env with ODBC_TEST_DSN=... or set environment variable. '
        'Skipping DB-dependent example.';
    stderr.writeln(message);
    AppLogger.warning(message);
    return null;
  }
  return dsn;
}

String? _firstNonEmpty(String? first, String? second) {
  for (final value in [first, second]) {
    if (value != null && value.trim().isNotEmpty) return value;
  }
  return null;
}

/// Keeps initialization and shutdown outside the measured workload.
Future<void> withExampleService(
  Future<void> Function(ServiceLocator, IOdbcService, String) action, {
  OdbcUsageProfile profile = OdbcUsageProfile.balanced,
}) async {
  AppLogger.initialize();
  final dsn = requireExampleDsn();
  if (dsn == null) return;

  final locator = ServiceLocator();
  try {
    locator.initialize(profile: profile);
    final service = locator.service;
    (await service.initialize()).getOrThrow();
    await action(locator, service, dsn);
  } on Object catch (error, stackTrace) {
    reportExampleError(error, 'example');
    AppLogger.fine('Example failure stack: $stackTrace');
  } finally {
    try {
      locator.shutdown();
    } on Object catch (error, stackTrace) {
      reportExampleError(error, 'shutdown');
      AppLogger.fine('Shutdown failure stack: $stackTrace');
    }
  }
}

Future<void> withExampleConnection(
  Future<void> Function(ServiceLocator, IOdbcService, Connection) action, {
  OdbcUsageProfile profile = OdbcUsageProfile.balanced,
}) =>
    withExampleService(
      (locator, service, dsn) async {
        final connection = (await service.connect(
          dsn,
          options: locator.recommendedConnectionOptions,
        ))
            .getOrThrow();
        try {
          await action(locator, service, connection);
        } finally {
          reportExampleCleanup(
            await service.disconnect(connection.id),
            'disconnect',
          );
        }
      },
      profile: profile,
    );

Future<void> withExamplePool(
  Future<void> Function(ServiceLocator, IOdbcService, int) action, {
  OdbcUsageProfile profile = OdbcUsageProfile.highThroughput,
}) =>
    withExampleService(
      (locator, service, dsn) async {
        final poolId = (await service.poolCreate(
          dsn,
          locator.recommendedPoolMaxSize,
          options: locator.recommendedPoolOptions,
          connectionOptions: locator.recommendedConnectionOptions,
        ))
            .getOrThrow();
        try {
          await action(locator, service, poolId);
        } finally {
          reportExampleCleanup(await service.poolClose(poolId), 'poolClose');
        }
      },
      profile: profile,
    );

/// Prints batch/workload summaries in the CLI and forwards them to the logger.
void reportExampleProgress(String message) {
  stdout.writeln(message);
  AppLogger.info(message);
}

/// Reports cleanup separately so it cannot replace the workload's error.
void reportExampleCleanup(Result<void> result, String operation) {
  result.fold((_) {}, (error) => reportExampleError(error, operation));
}

void reportExampleError(Object error, String operation) {
  final failure = error is OdbcErrorConvertible ? error.toOdbcError() : error;
  exitCode = 1;
  final message = failure is OdbcError
      ? '${failure.code.name}: ${failure.userMessage} '
          '(operation=${failure.details.operation ?? operation}, '
          'outcomeUnknown=${failure.details.outcomeUnknown})'
      : failure is ArgumentError || failure is StateError
          ? '$operation: $failure'
          : 'The example could not be completed ($operation).';
  stderr.writeln(message);
  AppLogger.severe(message);
}

/// Starts only [maxInFlight] tasks and drains active tasks before failing.
/// No task/result list grows with the total number of requests.
Future<void> runBoundedExampleTasks(
  int count,
  int maxInFlight,
  Future<void> Function(int) action,
) async {
  if (count < 0) throw ArgumentError.value(count, 'count');
  if (maxInFlight <= 0) {
    throw ArgumentError.value(maxInFlight, 'maxInFlight');
  }
  var next = 0;
  Object? failure;
  StackTrace? failureStack;

  Future<void> worker() async {
    while (failure == null && next < count) {
      final index = next++;
      try {
        await action(index);
      } on Object catch (error, stackTrace) {
        failure ??= error;
        failureStack ??= stackTrace;
      }
    }
  }

  final workers = count < maxInFlight ? count : maxInFlight;
  await Future.wait(List.generate(workers, (_) => worker()));
  if (failure case final error?) {
    Error.throwWithStackTrace(error, failureStack ?? StackTrace.current);
  }
}

int positiveExampleEnvInt(String key, int fallback) {
  final value = Platform.environment[key];
  if (value == null || value.isEmpty) return fallback;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed <= 0) {
    throw ArgumentError('Expected a positive integer for $key.');
  }
  return parsed;
}
