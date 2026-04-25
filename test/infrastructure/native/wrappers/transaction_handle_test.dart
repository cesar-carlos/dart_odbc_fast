/// Unit tests for [TransactionHandle] wrapper.
library;

import 'package:odbc_fast/infrastructure/native/wrappers/transaction_handle.dart';
import 'package:test/test.dart';

import '../../../helpers/fake_odbc_backend.dart';

void main() {
  group('TransactionHandle', () {
    late FakeOdbcConnectionBackend backend;
    late TransactionHandle handle;

    setUp(() {
      backend = FakeOdbcConnectionBackend();
      handle = TransactionHandle(backend, 7);
    });

    test('txnId returns constructor value', () {
      expect(handle.txnId, 7);
    });

    test('commit returns backend result', () {
      backend.commitTransactionResult = true;
      expect(handle.commit(), true);

      backend.commitTransactionResult = false;
      expect(handle.commit(), false);
    });

    test('rollback returns backend result', () {
      backend.rollbackTransactionResult = true;
      expect(handle.rollback(), true);

      backend.rollbackTransactionResult = false;
      expect(handle.rollback(), false);
    });

    test('savepoint methods delegate to backend while active', () {
      expect(handle.createSavepoint('sp1'), isTrue);
      expect(handle.rollbackToSavepoint('sp1'), isTrue);
      expect(handle.releaseSavepoint('sp1'), isTrue);

      backend
        ..createSavepointResult = false
        ..rollbackToSavepointResult = false
        ..releaseSavepointResult = false;

      expect(handle.createSavepoint('sp2'), isFalse);
      expect(handle.rollbackToSavepoint('sp2'), isFalse);
      expect(handle.releaseSavepoint('sp2'), isFalse);
    });

    test('withSavepoint releases savepoint on success', () async {
      final countingBackend = _CountingBackend();
      final txn = TransactionHandle(countingBackend, 9);

      final result = await txn.withSavepoint('sp', () async => 42);

      expect(result, 42);
      expect(countingBackend.createSavepointCalls, 1);
      expect(countingBackend.releaseSavepointCalls, 1);
      expect(countingBackend.rollbackToSavepointCalls, 0);
    });

    test('withSavepoint rolls back to savepoint and rethrows on error',
        () async {
      final countingBackend = _CountingBackend();
      final txn = TransactionHandle(countingBackend, 9);
      final error = StateError('boom');

      await expectLater(
        txn.withSavepoint('sp', () async => throw error),
        throwsA(same(error)),
      );

      expect(countingBackend.createSavepointCalls, 1);
      expect(countingBackend.releaseSavepointCalls, 0);
      expect(countingBackend.rollbackToSavepointCalls, 1);
    });

    test('withSavepoint throws when createSavepoint fails', () async {
      backend.createSavepointResult = false;

      await expectLater(
        handle.withSavepoint('sp', () async => 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Failed to create savepoint'),
          ),
        ),
      );
    });

    test('runWithBegin commits on success', () async {
      final countingBackend = _CountingBackend();
      final txn = TransactionHandle(countingBackend, 10);

      final result = await TransactionHandle.runWithBegin<int>(
        () => txn,
        (_) async => 7,
      );

      expect(result, 7);
      expect(countingBackend.commitCalls, 1);
      expect(countingBackend.rollbackCalls, 0);
      expect(txn.isActive, isFalse);
    });

    test('runWithBegin rolls back active transaction and rethrows', () async {
      final countingBackend = _CountingBackend();
      final txn = TransactionHandle(countingBackend, 10);
      final error = ArgumentError('bad');

      await expectLater(
        TransactionHandle.runWithBegin<void>(
          () => txn,
          (_) async => throw error,
        ),
        throwsA(same(error)),
      );

      expect(countingBackend.commitCalls, 0);
      expect(countingBackend.rollbackCalls, 1);
      expect(txn.isActive, isFalse);
    });

    test('runWithBegin throws when begin function returns null', () async {
      await expectLater(
        TransactionHandle.runWithBegin<int>(
          () => null,
          (_) async => 1,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('beginTransactionHandle returned null'),
          ),
        ),
      );
    });
  });
}

class _CountingBackend extends FakeOdbcConnectionBackend {
  int commitCalls = 0;
  int rollbackCalls = 0;
  int createSavepointCalls = 0;
  int rollbackToSavepointCalls = 0;
  int releaseSavepointCalls = 0;

  @override
  bool commitTransaction(int txnId) {
    commitCalls++;
    return super.commitTransaction(txnId);
  }

  @override
  bool rollbackTransaction(int txnId) {
    rollbackCalls++;
    return super.rollbackTransaction(txnId);
  }

  @override
  bool createSavepoint(int txnId, String name) {
    createSavepointCalls++;
    return super.createSavepoint(txnId, name);
  }

  @override
  bool rollbackToSavepoint(int txnId, String name) {
    rollbackToSavepointCalls++;
    return super.rollbackToSavepoint(txnId, name);
  }

  @override
  bool releaseSavepoint(int txnId, String name) {
    releaseSavepointCalls++;
    return super.releaseSavepoint(txnId, name);
  }
}
