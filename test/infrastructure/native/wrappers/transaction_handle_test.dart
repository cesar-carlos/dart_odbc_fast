/// Unit tests for [TransactionHandle] wrapper.
library;

import 'package:odbc_fast/infrastructure/native/wrappers/transaction_completion_status.dart';
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

    test('should_keep_handle_active_when_native_commit_is_busy', () {
      final statusBackend = _StatusBackend()..commitStatuses.addAll([2, 0]);
      final txn = TransactionHandle(statusBackend, 21);

      expect(txn.commit(), isFalse);
      expect(txn.isActive, isTrue);
      expect(txn.commit(), isTrue);
      expect(txn.isActive, isFalse);
      expect(statusBackend.commitCalls, 2);
    });

    test('should_keep_handle_active_when_native_rollback_is_busy', () {
      final statusBackend = _StatusBackend()..rollbackStatuses.addAll([2, 0]);
      final txn = TransactionHandle(statusBackend, 22);

      expect(txn.rollback(), isFalse);
      expect(txn.isActive, isTrue);
      expect(txn.rollback(), isTrue);
      expect(txn.isActive, isFalse);
      expect(statusBackend.rollbackCalls, 2);
    });

    test('should_end_handle_when_native_completion_fails_terminally', () {
      final statusBackend = _StatusBackend()..commitStatuses.add(1);
      final txn = TransactionHandle(statusBackend, 23);

      expect(txn.commit(), isFalse);
      expect(txn.isActive, isFalse);
      expect(txn.commit(), isFalse);
      expect(statusBackend.commitCalls, 1);
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

    test('runWithBegin throws when commit fails', () async {
      final countingBackend = _CountingBackend()
        ..commitTransactionResult = false;
      final txn = TransactionHandle(countingBackend, 10);

      await expectLater(
        TransactionHandle.runWithBegin<int>(
          () => txn,
          (_) async => 7,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Failed to commit transaction'),
          ),
        ),
      );

      expect(countingBackend.commitCalls, 1);
      expect(countingBackend.rollbackCalls, 0);
      expect(txn.isActive, isFalse);
    });

    test('should_preserve_retryable_handle_when_commit_and_cleanup_are_busy',
        () async {
      final statusBackend = _StatusBackend()
        ..commitStatuses.add(2)
        ..rollbackStatuses.add(2);
      final txn = TransactionHandle(statusBackend, 24);

      await expectLater(
        TransactionHandle.runWithBegin<int>(() => txn, (_) async => 7),
        throwsA(isA<StateError>()),
      );
      expect(txn.isActive, isTrue);
      expect(statusBackend.rollbackCalls, 1);

      statusBackend.rollbackStatuses.add(0);
      expect(txn.rollback(), isTrue);
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

class _StatusBackend extends FakeOdbcConnectionBackend
    implements TransactionCompletionStatus {
  final List<int> commitStatuses = [];
  final List<int> rollbackStatuses = [];
  int commitCalls = 0;
  int rollbackCalls = 0;

  @override
  int commitTransactionStatus(int txnId) {
    commitCalls++;
    return commitStatuses.removeAt(0);
  }

  @override
  int rollbackTransactionStatus(int txnId) {
    rollbackCalls++;
    return rollbackStatuses.removeAt(0);
  }
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
