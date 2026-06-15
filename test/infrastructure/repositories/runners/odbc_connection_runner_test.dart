/// Unit tests for [OdbcConnectionRunner].
library;

import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_connection_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:test/test.dart';

class _FakeNativeForConnection extends NativeOdbcConnection {
  bool initializeResult = true;
  int connectResult = 7;
  bool disconnectResult = true;

  @override
  bool initialize() => initializeResult;

  @override
  int connect(String connectionString) => connectResult;

  @override
  bool disconnect(int connectionId) => disconnectResult;
}

void main() {
  group('OdbcConnectionRunner', () {
    late _FakeNativeForConnection native;
    late OdbcRepositoryState state;
    late OdbcConnectionRunner runner;

    setUp(() {
      native = _FakeNativeForConnection();
      state = OdbcRepositoryState();
      runner = OdbcConnectionRunner(
        ffi: OdbcFfiDispatch(SyncBackend(native)),
        state: state,
        emit: (_) {},
        maybeEmitSlowQuery: ({
          required connectionId,
          required sql,
          stopwatch,
        }) {},
      );
    });

    tearDown(() => native.dispose());

    test('should_return_EnvironmentNotInitializedError_when_init_fails',
        () async {
      native.initializeResult = false;
      final result = await runner.initialize();
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<EnvironmentNotInitializedError>());
    });

    test('should_reject_empty_connection_string_on_connect', () async {
      final result = await runner.connect('');
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<ValidationError>());
    });

    test('should_register_connection_id_on_successful_connect', () async {
      final result = await runner.connect(
        'DSN=test',
        options: const ConnectionOptions(queryTimeout: Duration(seconds: 5)),
      );
      expect(result.isSuccess(), isTrue);
      final conn = result.getOrNull()!;
      expect(state.connectionIds[conn.id], equals(7));
      expect(state.connectionStrings[conn.id], equals('DSN=test'));
    });

    test('should_reject_disconnect_for_pooled_connection', () async {
      state.connectionIds['pooled'] = 9;
      state.connectionPoolId['pooled'] = 1;
      final result = await runner.disconnect('pooled');
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<ValidationError>());
      expect(
        (result.exceptionOrNull()! as ValidationError).message,
        contains('poolReleaseConnection'),
      );
    });
  });
}
