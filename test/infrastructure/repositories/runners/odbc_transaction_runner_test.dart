/// Unit tests for [OdbcTransactionRunner] savepoint validation boundaries.
library;

import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_transaction_runner.dart';
import 'package:test/test.dart';

import '../../../helpers/fake_async_native_for_errors.dart';

void main() {
  group('OdbcTransactionRunner savepoint validation', () {
    late FakeAsyncNativeForRepositoryErrors native;
    late OdbcRepositoryState state;
    late OdbcTransactionRunner runner;

    setUp(() {
      native = FakeAsyncNativeForRepositoryErrors();
      state = OdbcRepositoryState();
      state.connectionIds['conn-1'] = 42;
      runner = OdbcTransactionRunner(
        ffi: OdbcFfiDispatch(AsyncBackend(native)),
        state: state,
      );
    });

    test('should_return_ValidationError_when_savepoint_name_is_empty',
        () async {
      final result = await runner.createSavepoint('conn-1', 1, '   ');
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<ValidationError>());
      expect(
        (result.exceptionOrNull()! as ValidationError).message,
        contains('cannot be empty'),
      );
      expect(native.lastSavepointName, isNull);
    });

    test('should_return_ValidationError_when_txnId_is_invalid', () async {
      final result = await runner.rollbackToSavepoint('conn-1', 0, 'sp1');
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<ValidationError>());
      expect(
        (result.exceptionOrNull()! as ValidationError).message,
        contains('Invalid transaction ID'),
      );
    });

    test(
      'should_delegate_identifier_injection_checks_to_native_for_valid_names',
      () async {
        // Rust A1 validates/quotes identifiers; Dart only checks emptiness.
        native.createSavepointSuccess = false;
        final result = await runner.createSavepoint('conn-1', 3, 'sp_ok');
        expect(result.isError(), isTrue);
        expect(native.lastSavepointName, equals('sp_ok'));
        expect(native.lastTxnId, equals(3));
      },
    );
  });
}
