/// Test suite for `OdbcService.runInXaTransaction` (service-layer XA helper).
library;

import 'dart:typed_data';

import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

import '../../helpers/mock_odbc_repository.dart';

void main() {
  group('OdbcService.runInXaTransaction', () {
    late MockOdbcRepository mockRepo;
    late OdbcService service;
    late Xid xid;

    setUp(() {
      xid = Xid(gtrid: Uint8List.fromList([1]), formatId: 1);
      mockRepo = MockOdbcRepository()
        ..xaStartReturn = _FakeXa(xid)
        ..xaStartShouldFail = false;
      service = OdbcService(mockRepo);
    });

    tearDown(() {
      mockRepo.dispose();
    });

    test('2PC: Success → end, prepare, commit_prepared', () async {
      final fake = mockRepo.xaStartReturn! as _FakeXa;
      final result = await service.runInXaTransaction<int>(
        'conn-1',
        xid,
        (_) async => const Success(7),
      );

      expect(result.getOrNull(), 7);
      expect(fake.endCalls, 1);
      expect(fake.prepareCalls, 1);
      expect(fake.commitPreparedCalls, 1);
      expect(mockRepo.xaStartCalled, isTrue);
    });

    test('onePhase: Success → commit_one_phase only', () async {
      final fake = mockRepo.xaStartReturn! as _FakeXa;
      final result = await service.runInXaTransaction<int>(
        'conn-1',
        xid,
        (_) async => const Success(99),
        onePhase: true,
      );

      expect(result.getOrNull(), 99);
      expect(fake.commitOnePhaseCalls, 1);
      expect(fake.endCalls, 0);
      expect(fake.prepareCalls, 0);
    });

    test('action Failure → abort path', () async {
      const original = QueryError(message: 'no');
      final result = await service.runInXaTransaction<int>(
        'conn-1',
        xid,
        (_) async => const Failure(original),
      );

      expect(result.exceptionOrNull(), same(original));
      final fake = mockRepo.xaStartReturn! as _FakeXa;
      expect(fake.endCalls, greaterThan(0));
    });

    test('xa_start null handle → QueryError', () async {
      mockRepo.xaStartReturn = null;
      final result = await service.runInXaTransaction<int>(
        'conn-1',
        xid,
        (_) async => const Success(1),
      );

      expect(result.isError(), isTrue);
      expect(
        (result.exceptionOrNull()! as QueryError).message,
        contains('mock: xa_start null handle'),
      );
    });

    test('xaStart Failure from repository → surfaces', () async {
      mockRepo.xaStartShouldFail = true;
      final result = await service.runInXaTransaction<int>(
        'conn-1',
        xid,
        (_) async => const Success(1),
      );

      expect(result.isError(), isTrue);
      expect(
        result.exceptionOrNull(),
        isA<ValidationError>(),
      );
    });

    group('failure branches', () {
      test('onePhase: action threw → abort + QueryError surfaces stack',
          () async {
        final result = await service.runInXaTransaction<int>(
          'conn-1',
          xid,
          (_) async => throw StateError('action exploded'),
          onePhase: true,
        );

        expect(result.isError(), isTrue);
        final err = result.exceptionOrNull()!;
        expect(err, isA<QueryError>());
        expect((err as QueryError).message, contains('action threw'));
        final fake = mockRepo.xaStartReturn! as _FakeXa;
        expect(fake.endCalls + fake.commitOnePhaseCalls, greaterThan(0));
      });

      test('onePhase: commit_one_phase failure → QueryError with xid',
          () async {
        final fake = _FailingFakeXa(xid, failCommitOnePhase: true);
        mockRepo.xaStartReturn = fake;

        final result = await service.runInXaTransaction<int>(
          'conn-1',
          xid,
          (_) async => const Success(1),
          onePhase: true,
        );

        expect(result.isError(), isTrue);
        expect(
          (result.exceptionOrNull()! as QueryError).message,
          contains('xa_commit_one_phase failed'),
        );
      });

      test('2PC: end() failure → QueryError with xid', () async {
        final fake = _FailingFakeXa(xid, failEnd: true);
        mockRepo.xaStartReturn = fake;

        final result = await service.runInXaTransaction<int>(
          'conn-1',
          xid,
          (_) async => const Success(1),
        );

        expect(result.isError(), isTrue);
        expect(
          (result.exceptionOrNull()! as QueryError).message,
          contains('xa_end failed'),
        );
      });

      test('2PC: prepare() failure → QueryError with xid', () async {
        final fake = _FailingFakeXa(xid, failPrepare: true);
        mockRepo.xaStartReturn = fake;

        final result = await service.runInXaTransaction<int>(
          'conn-1',
          xid,
          (_) async => const Success(1),
        );

        expect(result.isError(), isTrue);
        expect(
          (result.exceptionOrNull()! as QueryError).message,
          contains('xa_prepare failed'),
        );
      });

      test('2PC: commitPrepared() failure → QueryError with xid', () async {
        final fake = _FailingFakeXa(xid, failCommitPrepared: true);
        mockRepo.xaStartReturn = fake;

        final result = await service.runInXaTransaction<int>(
          'conn-1',
          xid,
          (_) async => const Success(1),
        );

        expect(result.isError(), isTrue);
        expect(
          (result.exceptionOrNull()! as QueryError).message,
          contains('xa_commit_prepared failed'),
        );
      });

      test('2PC: action threw → abort + QueryError with stack', () async {
        final result = await service.runInXaTransaction<int>(
          'conn-1',
          xid,
          (_) async => throw StateError('mid-transaction crash'),
        );

        expect(result.isError(), isTrue);
        expect(
          (result.exceptionOrNull()! as QueryError).message,
          contains('action threw'),
        );
      });
    });
  });
}

/// Configurable variant of [_FakeXa] that lets each step fail
/// individually to drive the corresponding error branch in
/// `OdbcService.runInXaTransaction`.
class _NoopXaBackend implements XaTransactionBackend {
  const _NoopXaBackend();

  @override
  Future<int> xaCommitOnePhase(int xaId) async => 0;

  @override
  Future<int> xaCommitPrepared(int xaId) async => 0;

  @override
  Future<int> xaEnd(int xaId) async => 0;

  @override
  Future<int> xaPrepare(int xaId) async => 0;

  @override
  Future<int> xaRollbackActive(int xaId) async => 0;

  @override
  Future<int> xaRollbackPrepared(int xaId) async => 0;
}

class _FailingFakeXa extends XaTransactionHandle {
  _FailingFakeXa(
    Xid xid, {
    this.failEnd = false,
    this.failPrepare = false,
    this.failCommitPrepared = false,
    this.failCommitOnePhase = false,
  }) : super.withBackend(
          xaId: 1,
          xid: xid,
          backend: const _NoopXaBackend(),
        );

  final bool failEnd;
  final bool failPrepare;
  final bool failCommitPrepared;
  final bool failCommitOnePhase;

  XaState _st = XaState.active;

  @override
  XaState get state => _st;

  @override
  Future<bool> end() async {
    if (failEnd) {
      _st = XaState.failed;
      return false;
    }
    _st = XaState.idle;
    return true;
  }

  @override
  Future<bool> prepare() async {
    if (failPrepare) {
      _st = XaState.failedAfterPrepare;
      return false;
    }
    _st = XaState.prepared;
    return true;
  }

  @override
  Future<bool> commitPrepared() async {
    if (failCommitPrepared) {
      _st = XaState.failedAfterPrepare;
      return false;
    }
    _st = XaState.committed;
    return true;
  }

  @override
  Future<bool> commitOnePhase() async {
    if (failCommitOnePhase) {
      _st = XaState.failed;
      return false;
    }
    _st = XaState.committed;
    return true;
  }

  @override
  Future<bool> rollback() async {
    _st = XaState.rolledBack;
    return true;
  }

  @override
  Future<bool> rollbackPrepared() async {
    _st = XaState.rolledBack;
    return true;
  }
}

class _FakeXa extends XaTransactionHandle {
  _FakeXa(Xid xid)
      : super.withBackend(
          xaId: 1,
          xid: xid,
          backend: const _NoopXaBackend(),
        );

  int endCalls = 0;
  int prepareCalls = 0;
  int commitPreparedCalls = 0;
  int commitOnePhaseCalls = 0;
  int rollbackCalls = 0;

  XaState _st = XaState.active;

  @override
  XaState get state => _st;

  @override
  Future<bool> end() async {
    endCalls++;
    _st = XaState.idle;
    return true;
  }

  @override
  Future<bool> prepare() async {
    prepareCalls++;
    _st = XaState.prepared;
    return true;
  }

  @override
  Future<bool> commitPrepared() async {
    commitPreparedCalls++;
    _st = XaState.committed;
    return true;
  }

  @override
  Future<bool> commitOnePhase() async {
    commitOnePhaseCalls++;
    _st = XaState.committed;
    return true;
  }

  @override
  Future<bool> rollback() async {
    rollbackCalls++;
    _st = XaState.rolledBack;
    return true;
  }

  @override
  Future<bool> rollbackPrepared() async {
    _st = XaState.rolledBack;
    return true;
  }
}
