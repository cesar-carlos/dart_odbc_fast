/// Test suite for `OdbcService.runInXaTransaction` (service-layer XA helper).
library;

import 'dart:typed_data';

import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/wrappers/xa_transaction_handle.dart';
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
  });
}

class _FakeXa extends XaTransactionHandle {
  _FakeXa(Xid xid) : super(xaId: 1, xid: xid, conn: NativeOdbcConnection());

  int endCalls = 0;
  int prepareCalls = 0;
  int commitPreparedCalls = 0;
  int commitOnePhaseCalls = 0;
  int rollbackCalls = 0;

  XaState _st = XaState.active;

  @override
  XaState get state => _st;

  @override
  bool end() {
    endCalls++;
    _st = XaState.idle;
    return true;
  }

  @override
  bool prepare() {
    prepareCalls++;
    _st = XaState.prepared;
    return true;
  }

  @override
  bool commitPrepared() {
    commitPreparedCalls++;
    _st = XaState.committed;
    return true;
  }

  @override
  bool commitOnePhase() {
    commitOnePhaseCalls++;
    _st = XaState.committed;
    return true;
  }

  @override
  bool rollback() {
    rollbackCalls++;
    _st = XaState.rolledBack;
    return true;
  }

  @override
  bool rollbackPrepared() {
    _st = XaState.rolledBack;
    return true;
  }
}
