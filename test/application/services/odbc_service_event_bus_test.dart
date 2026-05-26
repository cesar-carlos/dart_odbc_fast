/// Tests for the [OdbcService] connection-lifecycle event bus.
library;

import 'dart:async';

import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:test/test.dart';

import '../../helpers/mock_odbc_repository.dart';

class _ControllerMockRepo extends MockOdbcRepository {
  final StreamController<OdbcEvent> controller =
      StreamController<OdbcEvent>.broadcast(sync: true);

  @override
  Stream<OdbcEvent> get events => controller.stream;
}

void main() {
  group('OdbcService event bus', () {
    late _ControllerMockRepo repo;
    late OdbcService service;

    setUp(() {
      repo = _ControllerMockRepo();
      service = OdbcService(repo);
    });

    tearDown(() async {
      await service.closeEvents();
      await repo.controller.close();
    });

    test('forwards repository events to listeners', () async {
      final received = <OdbcEvent>[];
      service.events.listen(received.add);

      final ts = DateTime.utc(2026);
      repo.controller.add(WorkerRecovered(timestamp: ts));
      repo.controller.add(
        PoolResize(timestamp: ts, poolId: 1, oldSize: 4, newSize: 8),
      );

      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(2));
      expect(received[0], isA<WorkerRecovered>());
      expect(received[1], isA<PoolResize>());
    });

    test('multiple listeners all receive events (broadcast)', () async {
      final a = <OdbcEvent>[];
      final b = <OdbcEvent>[];
      service.events.listen(a.add);
      service.events.listen(b.add);

      repo.controller.add(WorkerRecovered(timestamp: DateTime.utc(2026)));
      await Future<void>.delayed(Duration.zero);

      expect(a, hasLength(1));
      expect(b, hasLength(1));
    });

    test('closeEvents cancels the bridge subscription', () async {
      final received = <OdbcEvent>[];
      service.events.listen(received.add);

      await service.closeEvents();

      // After closeEvents the bridge is gone; subsequent emissions on
      // the repo controller must not surface to the listener.
      repo.controller.add(WorkerRecovered(timestamp: DateTime.utc(2026)));
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
    });

    test('listener attached after emission still works (broadcast tail)',
        () async {
      // Broadcast streams don't replay history; this test pins the
      // contract: late subscribers see future events but not past ones.
      repo.controller.add(WorkerRecovered(timestamp: DateTime.utc(2026)));
      await Future<void>.delayed(Duration.zero);

      final received = <OdbcEvent>[];
      service.events.listen(received.add);

      repo.controller.add(
        PoolResize(
          timestamp: DateTime.utc(2026),
          poolId: 1,
          oldSize: 1,
          newSize: 2,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.first, isA<PoolResize>());
    });
  });
}
