import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('dispose & disconnect cleanup', () {
    test(
      'should_clear_dart_side_state_after_dispose',
      () async {
        // Establish a fresh repo + connection so we have state to clear.
        final localNative = FakeRepoNative();
        addTearDown(localNative.dispose);
        final localRepo = OdbcRepositoryImpl(localNative);
        await localRepo.initialize();
        final connId =
            (await localRepo.connect('Driver={Test}')).getOrNull()!.id;

        // Sanity check: prepare succeeds against the live connection.
        final beforePrepare = await localRepo.prepare(connId, 'SELECT 1');
        expect(beforePrepare.isSuccess(), isTrue);

        localRepo.dispose();

        // After dispose, the same connectionId must read as invalid —
        // proving the Dart-side _connectionIds map was cleared.
        final afterPrepare = await localRepo.prepare(connId, 'SELECT 1');
        expect(afterPrepare.isError(), isTrue);
        afterPrepare.fold(
          (_) => fail('Expected failure after dispose'),
          (e) => expect(
            (e as ValidationError).message,
            contains('Invalid connection ID'),
          ),
        );
      },
    );

    test(
      'should_clear_dart_state_when_disconnect_native_fails',
      () async {
        final localNative = FakeRepoNative()..disconnectSuccess = false;
        addTearDown(localNative.dispose);
        final localRepo = OdbcRepositoryImpl(localNative);
        await localRepo.initialize();
        final connId =
            (await localRepo.connect('Driver={Test}')).getOrNull()!.id;

        final result = await localRepo.disconnect(connId);
        expect(result.isError(), isTrue);

        // Even though disconnect failed at the native layer, Dart-side
        // state must have been cleared so the next op fails fast with
        // ValidationError instead of misleading errors.
        final next = await localRepo.prepare(connId, 'SELECT 1');
        next.fold(
          (_) => fail('Expected failure after failed disconnect'),
          (e) => expect(
            (e as ValidationError).message,
            contains('Invalid connection ID'),
          ),
        );
      },
    );
  });
  group('worker recovery + events', () {
    test(
      'onWorkerRecovered should_clear_state_and_emit_WorkerRecovered_event',
      () async {
        final localNative = FakeRepoNative();
        addTearDown(localNative.dispose);
        final localRepo = OdbcRepositoryImpl(localNative);
        await localRepo.initialize();

        final connId =
            (await localRepo.connect('Driver={Test}')).getOrNull()!.id;
        // Seed statement metadata so we can prove it's cleared too.
        final prepareResult = await localRepo.prepare(connId, 'SELECT 1');
        expect(prepareResult.isSuccess(), isTrue);

        // Subscribe before triggering recovery so the broadcast stream
        // delivers the event synchronously.
        final events = <OdbcEvent>[];
        final sub = localRepo.events.listen(events.add);
        addTearDown(sub.cancel);

        // Trigger the callback exactly as `_recoverWorkerInternal` does.
        final cb = localNative.onWorkerRecovered;
        expect(cb, isNotNull);
        cb!();

        expect(events, hasLength(1));
        expect(events.single, isA<WorkerRecovered>());

        // State must be cleared — old connectionId should now read as
        // invalid through any repository entrypoint.
        final after = await localRepo.prepare(connId, 'SELECT 1');
        expect(after.isError(), isTrue);
        after.fold(
          (_) => fail('Expected ValidationError after recovery'),
          (e) => expect(
            (e as ValidationError).message,
            contains('Invalid connection ID'),
          ),
        );

        // The Dart-side metrics must reflect the clear-all.
        final metrics = localRepo.dartSideMetrics();
        expect(metrics.connectionCount, equals(0));
        expect(metrics.statementCount, equals(0));
      },
    );

    test(
      'onWorkerRecovered should_be_safe_when_no_listener_subscribed',
      () async {
        final localNative = FakeRepoNative();
        addTearDown(localNative.dispose);
        final localRepo = OdbcRepositoryImpl(localNative);
        await localRepo.initialize();
        await localRepo.connect('Driver={Test}');

        // No listener attached — _emit must short-circuit gracefully.
        expect(() => localNative.onWorkerRecovered!(), returnsNormally);
      },
    );

    test(
      'fromBackend constructor should_wire_recovery_callback',
      () async {
        final localNative = FakeRepoNative();
        addTearDown(localNative.dispose);
        await localNative.initialize();

        final localRepo = OdbcRepositoryImpl.fromBackend(
          AsyncBackend(localNative),
        );
        addTearDown(localRepo.dispose);

        expect(localNative.onWorkerRecovered, isNotNull);

        final events = <OdbcEvent>[];
        final sub = localRepo.events.listen(events.add);
        addTearDown(sub.cancel);

        localNative.onWorkerRecovered!();
        expect(events.whereType<WorkerRecovered>(), hasLength(1));
      },
    );

    test(
      'events stream should_not_emit_after_dispose_closes_controller',
      () async {
        final localNative = FakeRepoNative();
        addTearDown(localNative.dispose);
        final localRepo = OdbcRepositoryImpl(localNative);
        await localRepo.initialize();
        await localRepo.connect('Driver={Test}');

        final events = <OdbcEvent>[];
        final sub = localRepo.events.listen(events.add);
        await sub.cancel();
        localRepo.dispose();

        // Calling the recovery callback after dispose must not throw.
        expect(() => localNative.onWorkerRecovered?.call(), returnsNormally);
        expect(events, isEmpty);
      },
    );
  });
}
