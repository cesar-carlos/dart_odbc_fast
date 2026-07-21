import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities_v3.dart';
import 'package:test/test.dart';

import '../../helpers/mock_odbc_repository.dart';

class _FakeDialectService implements IDialectService {
  @override
  bool get supportsDialectApi => true;

  @override
  String? buildUpsertSql({
    required String connectionString,
    required String table,
    required List<String> columns,
    required List<String> conflictColumns,
    List<String>? updateColumns,
  }) =>
      'UPSERT INTO $table';

  @override
  String? appendReturningClause({
    required String connectionString,
    required String sql,
    required DmlVerb verb,
    required List<String> columns,
  }) =>
      '$sql RETURNING ${columns.join(',')}';

  @override
  List<String>? getSessionInitSql({
    required String connectionString,
    SessionOptions? options,
  }) =>
      const ['SET x=1'];
}

void main() {
  group('OdbcService dialect ISP', () {
    late MockOdbcRepository mockRepo;
    late OdbcService service;

    setUp(() {
      mockRepo = MockOdbcRepository();
      service = OdbcService(mockRepo, dialect: _FakeDialectService());
    });

    tearDown(() {
      mockRepo.dispose();
    });

    test('should_forward_buildUpsertSql_to_injected_dialect', () {
      final sql = service.buildUpsertSql(
        connectionString: 'Driver={PostgreSQL}',
        table: 't',
        columns: const ['a'],
        conflictColumns: const ['a'],
      );
      expect(sql, equals('UPSERT INTO t'));
      expect(service.supportsDialectApi, isTrue);
    });

    test('should_forward_appendReturningClause_to_injected_dialect', () {
      final sql = service.appendReturningClause(
        connectionString: 'Driver={PostgreSQL}',
        sql: 'INSERT INTO t VALUES (1)',
        verb: DmlVerb.insert,
        columns: const ['id'],
      );
      expect(sql, equals('INSERT INTO t VALUES (1) RETURNING id'));
    });

    test('should_forward_getSessionInitSql_to_injected_dialect', () {
      final stmts = service.getSessionInitSql(
        connectionString: 'Driver={PostgreSQL}',
      );
      expect(stmts, equals(['SET x=1']));
    });
  });
}
