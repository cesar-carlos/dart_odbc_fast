// High-concurrency native pool demo through async ServiceLocator.
//
// Focus: pool checkout / release under `OdbcUsageProfile.highThroughput`.
// `executeQuery` stays on row-major QueryResult wire (forQueryResultWire).
// For typed columnar analytics on checkouts, use executeQueryColumnar* /
// streamQueryColumnar* — see stream_query_columnar_demo.dart.
//
// Run: dart run example/high_concurrency_pool_demo.dart

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  const profile = OdbcUsageProfile.highThroughput;
  const taskCount = 24;
  final query = _envOr('ODBC_CONCURRENCY_QUERY', 'SELECT 1 AS value');

  final locator = ServiceLocator()..initialize(profile: profile);
  final service = locator.asyncService;
  final tuning = locator.resolvedUsageProfile;
  final poolSize = tuning.recommendedPoolMaxSize;
  final maxInFlight = poolSize;

  var poolId = 0;
  try {
    final init = await service.initialize();
    if (init.isError()) {
      Object? error;
      init.fold((_) {}, (e) => error = e);
      throw StateError('service.initialize failed: $error');
    }

    poolId = _unwrap<int>(
      await service.poolCreate(dsn, poolSize),
      'poolCreate',
    );

    _log(
      'Pool ready: poolId=$poolId, poolSize=$poolSize, '
      'profile=${tuning.profile.name}, workers=${tuning.workerCount}, '
      'pendingCap=${tuning.maxPendingRequests}, maxInFlight=$maxInFlight, '
      'recommendedEncoding=${tuning.recommendedResultEncoding.name} '
      '(applies to columnar APIs; executeQuery below stays row-major)',
    );
    _log(
      'The ${tuning.profile.name} profile starts multiple Dart worker '
      'isolates; the native pool supplies separate checkouts so tasks are not '
      'serialized on one connection.',
    );
    _log('Query: $query');

    final elapsed = await _measure(() async {
      await _runLimited<void>(
        taskCount,
        maxInFlight,
        (index) => _checkoutQueryRelease(service, poolId, index, query),
      );
    });

    final state = await service.poolGetState(poolId);
    state.fold(
      (s) => _log('Final pool state: size=${s.size}, idle=${s.idle}'),
      (e) => AppLogger.warning('poolGetState failed: $e'),
    );

    _log(
      'Completed $taskCount checkout/query/release tasks in '
      '${elapsed.inMilliseconds} ms',
    );
    _log(
      'The explicit maxInFlight limit keeps concurrent work aligned with '
      'pool size instead of queueing unbounded tasks inside the driver.',
    );
  } finally {
    if (poolId != 0) {
      final close = await service.poolClose(poolId);
      close.fold(
        (_) => AppLogger.info('Pool closed'),
        (e) => AppLogger.warning('poolClose failed: $e'),
      );
    }
    locator.shutdown();
  }
}

Future<void> _checkoutQueryRelease(
  OdbcService service,
  int poolId,
  int index,
  String query,
) async {
  final pooled = _unwrap<Connection>(
    await service.poolGetConnection(poolId),
    'poolGetConnection[$index]',
  );

  try {
    final result = _unwrap<QueryResult>(
      await service.executeQuery(
        query,
        connectionId: pooled.id,
      ),
      'executeQuery[$index]',
    );
    if (result.rowCount != 1) {
      throw StateError('executeQuery[$index] returned ${result.rowCount} rows');
    }
  } finally {
    final release = await service.poolReleaseConnection(pooled.id);
    release.fold(
      (_) {},
      (e) => AppLogger.warning('poolReleaseConnection[$index] failed: $e'),
    );
  }
}

String _envOr(String name, String fallback) {
  final value = Platform.environment[name];
  if (value != null && value.isNotEmpty) return value;
  return fallback;
}

void _log(String message) {
  stdout.writeln(message);
  AppLogger.info(message);
}

Future<Duration> _measure(Future<void> Function() action) async {
  final stopwatch = Stopwatch()..start();
  await action();
  stopwatch.stop();
  return stopwatch.elapsed;
}

Future<List<T>> _runLimited<T>(
  int count,
  int maxInFlight,
  Future<T> Function(int index) task,
) async {
  final results = List<T?>.filled(count, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= count) {
        return;
      }
      results[index] = await task(index);
    }
  }

  await Future.wait(List.generate(maxInFlight, (_) => worker()));
  return results.cast<T>();
}

T _unwrap<T extends Object>(Result<T> result, String operation) {
  final value = result.getOrNull();
  if (value != null) {
    return value;
  }

  Object? error;
  result.fold((_) {}, (e) => error = e);
  throw StateError('$operation failed: $error');
}
