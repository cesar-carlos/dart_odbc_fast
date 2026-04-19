/// Unit tests for [XaTransactionHandle.runWithStart] and
/// [XaTransactionHandle.runWithStartOnePhase] — the
/// exception-safety contract.
///
/// We don't touch the FFI layer here; instead we drive the helpers
/// through a `_FakeXa` subclass that overrides every state-mutating
/// method with a deterministic counter. The base
/// [XaTransactionHandle] constructor still needs a
/// `NativeOdbcConnection` (the field is non-nullable), so we pass
/// the no-op `NativeOdbcConnection()` — the override ensures we
/// never reach into its FFI surface.
library;

import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/wrappers/xa_transaction_handle.dart';
import 'package:test/test.dart';

void main() {
  Xid mkXid(String label) => Xid(
    formatId: 0,
    gtrid: Uint8List.fromList(label.codeUnits),
    bqual: Uint8List.fromList('b'.codeUnits),
  );

  group('XaTransactionHandle.runWithStart', () {
    test('happy path: end → prepare → commitPrepared, returns value', () async {
      final fake = _FakeXa(mkXid('happy'));

      final result = await XaTransactionHandle.runWithStart<int>(
        () => fake,
        (xa) async => 42,
      );

      expect(result, 42);
      expect(fake.endCalls, 1);
      expect(fake.prepareCalls, 1);
      expect(fake.commitPreparedCalls, 1);
      expect(fake.commitOnePhaseCalls, 0);
      expect(fake.rollbackCalls, 0);
      expect(fake.rollbackPreparedCalls, 0);
    });

    test('action throws while Active → end + rollback, rethrows', () async {
      final fake = _FakeXa(mkXid('throw-active'));
      final error = StateError('action failed');

      await expectLater(
        XaTransactionHandle.runWithStart<void>(
          () => fake,
          (xa) async => throw error,
        ),
        throwsA(same(error)),
      );

      expect(fake.endCalls, 1, reason: 'end emitted before rollback');
      expect(fake.rollbackCalls, 1, reason: 'Active branch -> xa_rollback');
      expect(fake.rollbackPreparedCalls, 0);
      expect(fake.commitPreparedCalls, 0);
    });

    test('action throws while Prepared → rollbackPrepared, rethrows', () async {
      // Simulate the user driving the branch all the way to Prepared
      // *inside* the action, then throwing. Cleanup should pick the
      // Phase-2 rollback path because state == Prepared.
      final fake = _FakeXa(mkXid('throw-prepared'));
      final error = StateError('after prepare');

      await expectLater(
        XaTransactionHandle.runWithStart<void>(() => fake, (xa) async {
          xa.end();
          xa.prepare();
          throw error;
        }),
        throwsA(same(error)),
      );

      // end was called twice (manually + cleanup is no-op once idle).
      expect(fake.endCalls, greaterThanOrEqualTo(1));
      expect(fake.prepareCalls, 1);
      expect(fake.rollbackPreparedCalls, 1);
      expect(fake.rollbackCalls, 0);
      expect(fake.commitPreparedCalls, 0);
    });

    test('startFn returns null → throws StateError with hint', () async {
      await expectLater(
        XaTransactionHandle.runWithStart<int>(
          () => null,
          (xa) async => 1,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('xa_start returned null'),
          ),
        ),
      );
    });

    test(
      'end failure on happy path → throws StateError, no commit',
      () async {
        final fake = _FakeXa(mkXid('end-fail'))..failOn = _FailOn.end;

        await expectLater(
          XaTransactionHandle.runWithStart<int>(
            () => fake,
            (xa) async => 99,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('xa_end failed'),
            ),
          ),
        );

        expect(fake.commitPreparedCalls, 0);
      },
    );

    test('prepare failure on happy path → throws, no commit', () async {
      final fake = _FakeXa(mkXid('prep-fail'))..failOn = _FailOn.prepare;

      await expectLater(
        XaTransactionHandle.runWithStart<int>(
          () => fake,
          (xa) async => 99,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('xa_prepare failed'),
          ),
        ),
      );

      expect(fake.commitPreparedCalls, 0);
    });

    test('commitPrepared failure → throws StateError with hint', () async {
      final fake = _FakeXa(mkXid('cp-fail'))..failOn = _FailOn.commitPrepared;

      await expectLater(
        XaTransactionHandle.runWithStart<int>(
          () => fake,
          (xa) async => 99,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('xa_commit_prepared failed'),
          ),
        ),
      );
    });
  });

  group('XaTransactionHandle.runWithStartOnePhase', () {
    test('happy path: only commitOnePhase is called, returns value', () async {
      final fake = _FakeXa(mkXid('1rm-happy'));

      final result = await XaTransactionHandle.runWithStartOnePhase<int>(
        () => fake,
        (xa) async => 7,
      );

      expect(result, 7);
      expect(fake.commitOnePhaseCalls, 1);
      expect(fake.endCalls, 0, reason: '1RM skips end');
      expect(fake.prepareCalls, 0, reason: '1RM skips prepare');
      expect(fake.commitPreparedCalls, 0);
    });

    test('action throws → end + rollback, rethrows', () async {
      final fake = _FakeXa(mkXid('1rm-throw'));
      final error = ArgumentError('oops');

      await expectLater(
        XaTransactionHandle.runWithStartOnePhase<void>(
          () => fake,
          (xa) async => throw error,
        ),
        throwsA(same(error)),
      );

      expect(fake.endCalls, 1);
      expect(fake.rollbackCalls, 1);
      expect(fake.commitOnePhaseCalls, 0);
    });

    test('commitOnePhase failure → throws StateError with hint', () async {
      final fake = _FakeXa(mkXid('1rm-fail'))..failOn = _FailOn.commitOnePhase;

      await expectLater(
        XaTransactionHandle.runWithStartOnePhase<int>(
          () => fake,
          (xa) async => 1,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('xa_commit_one_phase'),
          ),
        ),
      );
    });

    test('startFn returns null → throws StateError', () async {
      await expectLater(
        XaTransactionHandle.runWithStartOnePhase<int>(
          () => null,
          (xa) async => 1,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}

/// Identifies which step the fake should fail at, for the
/// "step X reports false" tests.
enum _FailOn { none, end, prepare, commitPrepared, commitOnePhase, rollback }

/// Test double for [XaTransactionHandle] that doesn't touch FFI.
///
/// We pass `NativeOdbcConnection()` to super only because the field
/// is non-nullable; every state-mutating method below is overridden
/// so the underlying FFI surface is never reached.
class _FakeXa extends XaTransactionHandle {
  _FakeXa(Xid xid)
    : super(xaId: 1, xid: xid, conn: NativeOdbcConnection());

  _FailOn failOn = _FailOn.none;

  int endCalls = 0;
  int prepareCalls = 0;
  int commitPreparedCalls = 0;
  int rollbackPreparedCalls = 0;
  int commitOnePhaseCalls = 0;
  int rollbackCalls = 0;

  XaState _fakeState = XaState.active;

  @override
  XaState get state => _fakeState;

  @override
  bool end() {
    endCalls++;
    if (failOn == _FailOn.end) {
      _fakeState = XaState.failed;
      return false;
    }
    _fakeState = XaState.idle;
    return true;
  }

  @override
  bool prepare() {
    prepareCalls++;
    if (failOn == _FailOn.prepare) {
      _fakeState = XaState.failed;
      return false;
    }
    _fakeState = XaState.prepared;
    return true;
  }

  @override
  bool commitPrepared() {
    commitPreparedCalls++;
    if (failOn == _FailOn.commitPrepared) {
      _fakeState = XaState.failed;
      return false;
    }
    _fakeState = XaState.committed;
    return true;
  }

  @override
  bool rollbackPrepared() {
    rollbackPreparedCalls++;
    _fakeState = XaState.rolledBack;
    return true;
  }

  @override
  bool commitOnePhase() {
    commitOnePhaseCalls++;
    if (failOn == _FailOn.commitOnePhase) {
      _fakeState = XaState.failed;
      return false;
    }
    _fakeState = XaState.committed;
    return true;
  }

  @override
  bool rollback() {
    rollbackCalls++;
    if (failOn == _FailOn.rollback) {
      _fakeState = XaState.failed;
      return false;
    }
    _fakeState = XaState.rolledBack;
    return true;
  }
}
