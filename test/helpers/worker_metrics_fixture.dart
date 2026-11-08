import 'dart:isolate';
import 'dart:mirrors';

import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';

// VM-only fixture: access private metrics without adding production test APIs
// or starting native workers. Reflection stays outside benchmark timing.
class WorkerMetricsFixture {
  WorkerMetricsFixture(
    int count, {
    AsyncNativeOdbcConnection? connection,
    int sampleOffset = 0,
  }) : connection =
            connection ?? AsyncNativeOdbcConnection(workerCount: count) {
    final reflected = reflect(this.connection);
    final library = reflected.type.owner! as LibraryMirror;
    Symbol private(String name) => MirrorSystem.getSymbol(name, library);
    final channel =
        library.declarations[private('_WorkerChannel')]! as ClassMirror;
    final workers =
        reflected.getField(private('_workers')).reflectee as List<Object?>;
    for (var i = 0; i < count; i++) {
      final worker = channel.newInstance(Symbol.empty, [], {
        #index: i,
        #receivePort: ReceivePort(),
        #generation: 0,
      });
      // Complete the handshake before cleanup to avoid a startup error.
      final port = worker.getField(#receivePort).reflectee as ReceivePort;
      worker.getField(#handshake).invoke(#complete, [port.sendPort]);
      workers.add(worker.reflectee);
      for (final field in [
        'activeRequests',
        'totalRouted',
        'completedRequests',
        'failedRequests',
        'timeouts',
        'fallbacksToBlocking',
        'cancelAttempts',
        'cancelSucceeded',
        'cancelUnsupported',
      ]) {
        worker.setField(Symbol(field), i + 1);
      }
      final latency =
          worker.getField(#recordLatency).reflectee as void Function(int);
      final queue =
          worker.getField(#recordQueueWait).reflectee as void Function(int);
      final execution =
          worker.getField(#recordExecution).reflectee as void Function(int);
      for (var j = 0; j < 256; j++) {
        latency(sampleOffset + (j * 73 + i * 31) % 1009);
        queue(sampleOffset + (j * 19 + i * 7) % 101);
        execution(sampleOffset + (j * 53 + i * 13) % 503);
      }
      recorders.add((latency, queue, execution));
    }
    percentile = channel.getField(private('_percentile')).reflectee as int
        Function(Iterable<int>, int);
  }

  final AsyncNativeOdbcConnection connection;
  final recorders =
      <(void Function(int), void Function(int), void Function(int))>[];
  late final int Function(Iterable<int>, int) percentile;

  void update(int value) {
    for (final (latency, queue, execution) in recorders) {
      latency(value);
      queue(value ~/ 3);
      execution(value ~/ 2);
    }
  }

  void dispose() => connection.dispose();
}
