import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:result_dart/result_dart.dart';

/// Centralises sync/async FFI dispatch and native error translation for
/// repository runners.
class OdbcFfiDispatch {
  OdbcFfiDispatch(this._backend);

  final OdbcBackend _backend;

  OdbcBackend get backend => _backend;

  bool get isAsync => _backend.isAsync;

  NativeOdbcConnection get sync => switch (_backend) {
        SyncBackend(:final connection) => connection,
        AsyncBackend() => throw StateError(
            'OdbcFfiDispatch: sync access on async backend',
          ),
      };

  AsyncNativeOdbcConnection get async => switch (_backend) {
        AsyncBackend(:final connection) => connection,
        SyncBackend() => throw StateError(
            'OdbcFfiDispatch: async access on sync backend',
          ),
      };

  Future<Result<Unit>> runBoolFfi({
    required bool Function(NativeOdbcConnection) sync,
    required Future<bool> Function(AsyncNativeOdbcConnection) async,
    required OdbcErrorFactoryFn errorFactory,
    String? fallbackMessage,
    int? nativeConnectionId,
  }) async {
    try {
      final ok = switch (_backend) {
        SyncBackend(:final connection) => sync(connection),
        AsyncBackend(:final connection) => await async(connection),
      };
      if (ok) return const Success(unit);
      return await convertNativeErrorToFailure<Unit>(
        errorFactory: errorFactory,
        fallbackMessage: fallbackMessage,
        nativeConnectionId: nativeConnectionId,
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(errorFactory(message: e.toString()));
    }
  }

  Future<Result<Unit>> runBoolFfiWithCleanup({
    required bool Function(NativeOdbcConnection) sync,
    required Future<bool> Function(AsyncNativeOdbcConnection) async,
    required void Function() onSuccess,
    required OdbcErrorFactoryFn errorFactory,
    String? fallbackMessage,
    int? nativeConnectionId,
  }) async {
    try {
      final ok = switch (_backend) {
        SyncBackend(:final connection) => sync(connection),
        AsyncBackend(:final connection) => await async(connection),
      };
      if (ok) {
        onSuccess();
        return const Success(unit);
      }
      return await convertNativeErrorToFailure<Unit>(
        errorFactory: errorFactory,
        fallbackMessage: fallbackMessage,
        nativeConnectionId: nativeConnectionId,
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(errorFactory(message: e.toString()));
    }
  }

  Future<Result<int>> runIntFfi({
    required int Function(NativeOdbcConnection) sync,
    required Future<int> Function(AsyncNativeOdbcConnection) async,
    required bool Function(int code) isSuccess,
    required OdbcErrorFactoryFn errorFactory,
    String? fallbackMessage,
    int? nativeConnectionId,
  }) async {
    try {
      final code = switch (_backend) {
        SyncBackend(:final connection) => sync(connection),
        AsyncBackend(:final connection) => await async(connection),
      };
      if (isSuccess(code)) return Success(code);
      return await convertNativeErrorToFailure<int>(
        errorFactory: errorFactory,
        fallbackMessage: fallbackMessage,
        nativeConnectionId: nativeConnectionId,
      );
    } on Exception catch (e) {
      return Failure<int, OdbcError>(errorFactory(message: e.toString()));
    }
  }

  Future<StructuredError?> getStructuredNativeError({
    int? nativeConnectionId,
  }) async {
    return switch (_backend) {
      SyncBackend(:final connection) => () {
          if (nativeConnectionId != null) {
            final scoped =
                connection.getStructuredErrorForConnection(nativeConnectionId);
            if (scoped != null) return scoped;
          }
          return connection.getStructuredError();
        }(),
      AsyncBackend(:final connection) => () async {
          if (nativeConnectionId != null) {
            final scoped = await connection
                .getStructuredErrorForConnection(nativeConnectionId);
            if (scoped != null) return scoped;
          }
          return connection.getStructuredError();
        }(),
    };
  }

  Future<Failure<T, OdbcError>> convertNativeErrorToFailure<T extends Object>({
    required OdbcErrorFactoryFn errorFactory,
    String? fallbackMessage,
    int? nativeConnectionId,
  }) async {
    final structuredError = await getStructuredNativeError(
      nativeConnectionId: nativeConnectionId,
    );

    if (structuredError != null) {
      return Failure<T, OdbcError>(
        errorFactory(
          message: structuredError.message,
          sqlState: structuredError.sqlStateString,
          nativeCode: structuredError.nativeCode,
        ),
      );
    }

    final errorMsg = isAsync ? await async.getError() : sync.getError();
    final finalMessage =
        errorMsg.isNotEmpty ? errorMsg : (fallbackMessage ?? 'Unknown error');

    return Failure<T, OdbcError>(
      errorFactory(message: finalMessage),
    );
  }
}
