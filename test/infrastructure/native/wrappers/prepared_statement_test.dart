/// Unit tests for [PreparedStatement] wrapper.
library;

import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/native/wrappers/prepared_statement.dart';
import 'package:test/test.dart';

import '../../../helpers/fake_odbc_backend.dart';

void main() {
  group('PreparedStatement', () {
    late FakeOdbcConnectionBackend backend;
    late PreparedStatement stmt;

    setUp(() {
      backend = FakeOdbcConnectionBackend();
      stmt = PreparedStatement(backend, 5);
    });

    test('stmtId returns constructor value', () {
      expect(stmt.stmtId, 5);
    });

    test('execute returns backend result', () {
      final data = Uint8List.fromList([1, 2, 3]);
      backend.executePreparedResult = data;
      expect(stmt.execute(), data);

      backend.executePreparedResult = null;
      expect(stmt.execute(), isNull);
    });

    test('execute with params passes to backend', () {
      backend.executePreparedResult = Uint8List(0);
      stmt.execute(params: [const ParamValueString('value')]);
      expect(backend.executePreparedResult, isNotNull);
    });

    test('execute with options passes timeout and fetchSize', () {
      backend.executePreparedResult = Uint8List(0);
      stmt.execute(
        timeoutOverrideMs: 5000,
        fetchSize: 500,
        maxBufferBytes: 10000,
      );
      expect(backend.executePreparedResult, isNotNull);
    });

    test('close calls backend closeStatement', () {
      backend.closeStatementResult = true;
      stmt.close();
    });

    test('executeNamed throws when paramNamesForNamedExecution is null', () {
      expect(
        () => stmt.executeNamed(namedParams: {'x': 'value'}),
        throwsA(isA<StateError>()),
      );
    });

    test('executeNamed converts named to positional when params provided', () {
      final stmtWithNames = PreparedStatement(
        backend,
        6,
        paramNamesForNamedExecution: ['id', 'name'],
      );
      backend.executePreparedResult = Uint8List(0);
      final result = stmtWithNames.executeNamed(
        namedParams: {'id': 1, 'name': 'Alice'},
      );
      expect(result, isNotNull);
    });
  });
}
