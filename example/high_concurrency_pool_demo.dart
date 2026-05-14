// High-concurrency native pool demo through async ServiceLocator.
// Run: dart run example/high_concurrency_pool_demo.dart

import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  const workerCount = 4;
  const poolSize = 4;
  const taskCount = 24;
  const maxInFlight = 4;

  final locator = ServiceLocator()
    ..initialize(
      useAsync: true,
      asyncWorkerCount: workerCount,
      asyncMaxPendingRequests: poolSize * 4,
    );
  final service = locator.asyncService;

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

    AppLogger.info(
      'Pool ready: poolId=$poolId, poolSize=$poolSize, '
      'workers=$workerCount, maxInFlight=$maxInFlight',
    );

    final elapsed = await _measure(() async {
      await _runLimited<void>(
        taskCount,
        maxInFlight,
        (index) => _checkoutQueryRelease(service, poolId, index),
      );
    });

    final state = await service.poolGetState(poolId);
    state.fold(
      (s) => AppLogger.info('Final pool state: size=${s.size}, idle=${s.idle}'),
      (e) => AppLogger.warning('poolGetState failed: $e'),
    );

    AppLogger.info(
      'Completed $taskCount checkout/query/release tasks in '
      '${elapsed.inMilliseconds} ms',
    );
    AppLogger.info(
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
) async {
  final pooled = _unwrap<Connection>(
    await service.poolGetConnection(poolId),
    'poolGetConnection[$index]',
  );

  try {
    final result = _unwrap<QueryResult>(
      await service.executeQuery(
        'SELECT 1 AS value',
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
