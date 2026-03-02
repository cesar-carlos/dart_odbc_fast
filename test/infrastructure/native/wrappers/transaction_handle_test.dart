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
  });
}
