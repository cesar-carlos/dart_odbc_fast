import 'dart:async';

import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:test/test.dart';

class _Backend implements XaTransactionBackend {
  int rollbacks = 0;
  int commits = 0;
  int ends = 0;
  int prepares = 0;
  Completer<int>? commitGate;
  bool fail = true;
  String? throwingPhase;
  @override
  Future<int> xaEnd(int id) async {
    ends++;
    return 0;
  }

  @override
  Future<int> xaPrepare(int id) async {
    prepares++;
    if (throwingPhase == 'prepare') throw StateError('Prepare response lost');
    return 0;
  }

  @override
  Future<int> xaCommitPrepared(int id) async {
    commits++;
    if (commitGate != null) return commitGate!.future;
    if (fail) throw TimeoutException('Response lost');
    return 0;
  }

  @override
  Future<int> xaCommitOnePhase(int id) => xaCommitPrepared(id);
  @override
  Future<int> xaRollbackPrepared(int id) async {
    rollbacks++;
    if (throwingPhase == 'rollback') throw StateError('Rollback response lost');
    return 0;
  }

  @override
  Future<int> xaRollbackActive(int id) => xaRollbackPrepared(id);
}

void main() {
  test('should_reject_concurrent_phases_before_a_second_backend_call',
      () async {
    final gate = Completer<int>();
    final backend = _Backend()..commitGate = gate;
    final xa = XaTransactionHandle.withBackend(
      xaId: 1,
      xid: Xid.fromStrings(gtrid: 'concurrent'),
      backend: backend,
      initialState: XaState.prepared,
    );
    final first = xa.commitPrepared();
    await expectLater(xa.rollbackPrepared(), throwsA(isA<ValidationError>()));
    expect(backend.rollbacks, 0);
    gate.complete(0);
    expect(await first, isTrue);
    expect(backend.commits, 1);
  });
  test('should_not_repeat_prepare_completed_inside_action', () async {
    final backend = _Backend()..fail = false;
    final xa = XaTransactionHandle.withBackend(
      xaId: 1,
      xid: Xid.fromStrings(gtrid: 'prepared'),
      backend: backend,
    );
    final value =
        await XaTransactionHandle.runWithStart(() => xa, (handle) async {
      await handle.end();
      await handle.prepare();
      return 42;
    });
    expect(value, 42);
    expect(backend.ends, 1);
    expect(backend.prepares, 1);
    expect(backend.commits, 1);
  });
  for (final phase in ['prepare', 'rollback']) {
    test('should_preserve_unknown_outcome_after_${phase}_exception', () async {
      final backend = _Backend()..throwingPhase = phase;
      final xa = XaTransactionHandle.withBackend(
        xaId: 1,
        xid: Xid.fromStrings(gtrid: 'phase'),
        backend: backend,
        initialState: phase == 'prepare' ? XaState.idle : XaState.prepared,
      );
      await expectLater(
        phase == 'prepare' ? xa.prepare() : xa.rollbackPrepared(),
        throwsStateError,
      );
      expect(xa.outcomeUnknown, isTrue);
      expect(xa.lastError!.details.stackTrace, isNotNull);
      await expectLater(xa.commitPrepared(), throwsA(isA<Object>()));
      expect(backend.commits, 0);
    });
  }
  test('should_preserve_uncertain_prepared_commit_without_rollback', () async {
    final backend = _Backend();
    final xa = XaTransactionHandle.withBackend(
      xaId: 1,
      xid: Xid.fromStrings(gtrid: 'test'),
      backend: backend,
      initialState: XaState.prepared,
    );
    await expectLater(
      XaTransactionHandle.runWithStart(() => xa, (handle) async {
        await handle.commitPrepared();
        return 1;
      }),
      throwsA(isA<TimeoutException>()),
    );
    expect(xa.state, XaState.failedAfterPrepare);
    expect(xa.lastError, isNotNull);
    expect(backend.rollbacks, 0);
  });

  test('should_not_repeat_commit_completed_inside_action', () async {
    final backend = _Backend()..fail = false;
    final xa = XaTransactionHandle.withBackend(
      xaId: 1,
      xid: Xid.fromStrings(gtrid: 'test'),
      backend: backend,
    );
    final value = await XaTransactionHandle.runWithStartOnePhase(() => xa,
        (handle) async {
      await handle.commitOnePhase();
      return 42;
    });
    expect(value, 42);
    expect(backend.commits, 1);
  });
}
