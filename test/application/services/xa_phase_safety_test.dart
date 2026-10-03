import 'dart:async';

import 'package:odbc_fast/application/services/odbc_transaction_service.dart';
import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/i_transaction_repository.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

class _Backend implements XaTransactionBackend {
  int commits = 0;
  int rollbacks = 0;
  String? failPhase;
  @override
  Future<int> xaEnd(int id) async => 0;
  @override
  Future<int> xaPrepare(int id) async {
    if (failPhase == 'prepare') throw StateError('Prepare response lost');
    return 0;
  }

  @override
  Future<int> xaCommitPrepared(int id) async {
    commits++;
    if (failPhase == 'commit') throw TimeoutException('Commit response lost');
    return 0;
  }

  @override
  Future<int> xaCommitOnePhase(int id) => xaCommitPrepared(id);
  @override
  Future<int> xaRollbackPrepared(int id) async {
    rollbacks++;
    return 0;
  }

  @override
  Future<int> xaRollbackActive(int id) => xaRollbackPrepared(id);
}

class _Repository implements ITransactionRepository {
  _Repository(this.handle);
  final XaTransactionHandle handle;
  @override
  Future<Result<XaTransactionHandle>> xaStart(
    String connectionId,
    Xid xid,
  ) async =>
      Success(handle);
  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _BeforeCallBackend extends _Backend implements XaExecutionBackend {
  @override
  bool get lastCallNotStarted => true;
  @override
  void registerReconciliation(void Function(String, int?) callback) {}
  @override
  Future<int> xaCommitPrepared(int id) async {
    commits++;
    return -1;
  }
}

void main() {
  for (final manual in [true, false]) {
    test('should_preserve_no_execution_evidence_without_repeating_$manual',
        () async {
      final backend = _BeforeCallBackend();
      final xid = Xid.fromStrings(gtrid: 'before-call');
      final xa = XaTransactionHandle.withBackend(
        xaId: 1,
        xid: xid,
        backend: backend,
      );
      final service = OdbcTransactionService(_Repository(xa));
      final result = await service.runInXaTransaction<int>(
        'connection',
        xid,
        (handle) async {
          if (manual) await handle.commitOnePhase();
          return const Success(42);
        },
        onePhase: true,
      );
      expect(result.isError(), isTrue);
      expect(
        (result.exceptionOrNull()! as OdbcError).details.outcomeUnknown,
        isFalse,
      );
      expect(xa.commitAttempted, isTrue);
      expect(backend.commits, 1);
      expect(backend.rollbacks, 0);
      expect(await xa.rollback(), isTrue);
    });
  }
  for (final phase in [
    'prepare',
    'commit',
    'manualCommit',
    'manualSuccess',
    'manualRollback',
  ]) {
    test('should_respect_xa_phase_completed_in_service_action_$phase',
        () async {
      final backend = _Backend()
        ..failPhase = phase == 'manualCommit' ? 'commit' : phase;
      final xid = Xid.fromStrings(gtrid: 'service');
      final handle = XaTransactionHandle.withBackend(
        xaId: 1,
        xid: xid,
        backend: backend,
      );
      final service = OdbcTransactionService(_Repository(handle));
      final result =
          await service.runInXaTransaction<int>('connection', xid, (xa) async {
        if (phase == 'manualCommit' || phase == 'manualSuccess') {
          await xa.commitOnePhase();
        }
        if (phase == 'manualRollback') await xa.rollback();
        return const Success(42);
      });
      expect(result.isSuccess(), phase == 'manualSuccess');
      expect(backend.rollbacks, phase == 'manualRollback' ? 1 : 0);
      expect(
        backend.commits,
        phase == 'prepare' || phase == 'manualRollback' ? 0 : 1,
      );
      if (phase == 'prepare' || phase == 'commit' || phase == 'manualCommit') {
        final error = result.exceptionOrNull()! as OdbcError;
        expect(error.details.outcomeUnknown, isTrue);
        expect(error.details.cause, isNotNull);
        expect(error.details.stackTrace, isNotNull);
      }
    });
  }
}
