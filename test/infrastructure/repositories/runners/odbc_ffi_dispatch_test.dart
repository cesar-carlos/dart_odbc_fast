/// Unit tests for [OdbcFfiDispatch].
library;

import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:test/test.dart';

import '../../../helpers/fake_async_native_for_errors.dart';

class _FakeSyncNative extends NativeOdbcConnection {
  bool boolResult = true;
  int intResult = 3;
  String errorMessage = 'sync failure';
  StructuredError? structuredError;

  @override
  bool commitTransaction(int txnId) => boolResult;

  @override
  int poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) =>
      intResult;

  @override
  String getError() => errorMessage;

  @override
  StructuredError? getStructuredError() => structuredError;
}

void main() {
  group('OdbcFfiDispatch', () {
    test('runBoolFfi returns Success when sync backend returns true', () async {
      final dispatch = OdbcFfiDispatch(SyncBackend(_FakeSyncNative()));
      final result = await dispatch.runBoolFfi(
        sync: (n) => n.commitTransaction(1),
        async: (a) => a.commitTransaction(1),
        errorFactory: odbcQueryErrorFactory,
      );
      expect(result.isSuccess(), isTrue);
    });

    test('runIntFfi maps zero pool id to native error', () async {
      final native = _FakeSyncNative()..intResult = 0;
      final dispatch = OdbcFfiDispatch(SyncBackend(native));
      final result = await dispatch.runIntFfi(
        sync: (n) => n.poolCreate('DSN=x', 4),
        async: (a) => a.poolCreate('DSN=x', 4),
        isSuccess: (id) => id != 0,
        errorFactory: odbcConnectionErrorFactory,
        fallbackMessage: 'pool create failed',
      );
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<ConnectionError>());
      expect(
        (result.exceptionOrNull()! as ConnectionError).message,
        equals('sync failure'),
      );
    });

    test('convertNativeErrorToFailure prefers structured native error',
        () async {
      final native = FakeAsyncNativeForRepositoryErrors()
        ..globalStructuredError = const StructuredError(
          sqlState: [72, 89, 48, 48, 48],
          nativeCode: 500,
          message: 'structured failure',
        );
      final dispatch = OdbcFfiDispatch(AsyncBackend(native));
      final failure = await dispatch.convertNativeErrorToFailure<int>(
        errorFactory: odbcQueryErrorFactory,
        fallbackMessage: 'fallback',
      );
      final err = failure.exceptionOrNull() as QueryError;
      expect(err.message, equals('structured failure'));
      expect(err.sqlState, equals('HY000'));
      expect(err.nativeCode, equals(500));
    });
  });
}
