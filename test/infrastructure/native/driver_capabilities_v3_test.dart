import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities_v3.dart';
import 'package:test/test.dart';

void main() {
  group('DmlVerb', () {
    test('exposes native wire codes', () {
      expect(DmlVerb.insert.code, 0);
      expect(DmlVerb.update.code, 1);
      expect(DmlVerb.delete.code, 2);
    });
  });

  group('SessionOptions', () {
    test('omits null and empty fields from JSON payload', () {
      const options = SessionOptions();

      expect(options.toJson(), isEmpty);
    });

    test('serializes only configured fields', () {
      const options = SessionOptions(
        applicationName: 'odbc-fast',
        timezone: 'UTC',
        charset: 'utf8',
        schema: 'public',
        extraSql: ['SET lock_timeout = 1000'],
      );

      expect(options.toJson(), {
        'application_name': 'odbc-fast',
        'timezone': 'UTC',
        'charset': 'utf8',
        'schema': 'public',
        'extra_sql': ['SET lock_timeout = 1000'],
      });
    });

    test('serializes extraSql only when it is the sole field', () {
      const options = SessionOptions(extraSql: ['SET x=1']);

      expect(options.toJson(), {
        'extra_sql': ['SET x=1'],
      });
    });
  });

  group('OdbcDriverFeatures', () {
    test('returns null without calling backend when API is unavailable', () {
      final backend = _FakeDriverFeatureBackend(supportsApi: false);
      final features = OdbcDriverFeatures.withBackend(backend);

      expect(features.supportsApi, isFalse);
      expect(
        features.buildUpsertSql(
          connectionString: 'DSN=Test',
          table: 'users',
          columns: const ['id'],
          conflictColumns: const ['id'],
        ),
        isNull,
      );
      expect(
        features.appendReturningClause(
          connectionString: 'DSN=Test',
          sql: 'INSERT INTO users(id) VALUES (?)',
          verb: DmlVerb.insert,
          columns: const ['id'],
        ),
        isNull,
      );
      expect(
        features.getSessionInitSql(connectionString: 'DSN=Test'),
        isNull,
      );
      expect(backend.calls, isEmpty);
    });

    test('buildUpsertSql encodes payload and decodes SQL response', () {
      final backend = _FakeDriverFeatureBackend()
        ..upsertResponse = 'INSERT ... ON CONFLICT'.utf8Bytes;
      final features = OdbcDriverFeatures.withBackend(backend);

      final sql = features.buildUpsertSql(
        connectionString: 'DSN=Postgres',
        table: 'users',
        columns: const ['id', 'name'],
        conflictColumns: const ['id'],
        updateColumns: const ['name'],
      );

      expect(sql, 'INSERT ... ON CONFLICT');
      expect(backend.calls, ['upsert']);
      expect(backend.lastConnectionString, 'DSN=Postgres');
      expect(backend.lastTable, 'users');
      expect(jsonDecode(backend.lastPayloadJson!), {
        'columns': ['id', 'name'],
        'conflict': ['id'],
        'update': ['name'],
      });
    });

    test('buildUpsertSql omits update key when updateColumns not passed', () {
      final backend = _FakeDriverFeatureBackend()
        ..upsertResponse = 'SQL'.utf8Bytes;
      final features = OdbcDriverFeatures.withBackend(backend);

      final sql = features.buildUpsertSql(
        connectionString: 'DSN=X',
        table: 't',
        columns: const ['id'],
        conflictColumns: const ['id'],
      );

      expect(sql, 'SQL');
      expect(jsonDecode(backend.lastPayloadJson!), {
        'columns': ['id'],
        'conflict': ['id'],
      });
    });

    test('appendReturningClause passes empty CSV when columns empty', () {
      final backend = _FakeDriverFeatureBackend()
        ..returningResponse = Uint8List(0);
      final features = OdbcDriverFeatures.withBackend(backend);

      final sql = features.appendReturningClause(
        connectionString: 'DSN=X',
        sql: 'INSERT INTO t(id) VALUES (?)',
        verb: DmlVerb.insert,
        columns: const [],
      );

      expect(sql, '');
      expect(backend.lastColumnsCsv, '');
    });

    test('getSessionInitSql returns empty list when backend returns JSON []',
        () {
      final backend = _FakeDriverFeatureBackend()
        ..sessionResponse = jsonEncode([]).utf8Bytes;
      final features = OdbcDriverFeatures.withBackend(backend);

      final statements = features.getSessionInitSql(connectionString: 'DSN=X');

      expect(statements, isEmpty);
      expect(backend.lastOptionsJson, isNull);
    });

    test('appendReturningClause joins columns and passes verb code', () {
      final backend = _FakeDriverFeatureBackend()
        ..returningResponse = 'INSERT INTO t OUTPUT inserted.id'.utf8Bytes;
      final features = OdbcDriverFeatures.withBackend(backend);

      final sql = features.appendReturningClause(
        connectionString: 'DSN=SqlServer',
        sql: 'INSERT INTO t(id) VALUES (?)',
        verb: DmlVerb.insert,
        columns: const ['id', 'name'],
      );

      expect(sql, 'INSERT INTO t OUTPUT inserted.id');
      expect(backend.lastVerbCode, DmlVerb.insert.code);
      expect(backend.lastColumnsCsv, 'id,name');
    });

    test('appendReturningClause passes update verb code', () {
      final backend = _FakeDriverFeatureBackend()
        ..returningResponse =
            'UPDATE t SET name=? OUTPUT inserted.id'.utf8Bytes;
      OdbcDriverFeatures.withBackend(backend).appendReturningClause(
        connectionString: 'DSN=SqlServer',
        sql: 'UPDATE t SET name=?',
        verb: DmlVerb.update,
        columns: const ['id'],
      );

      expect(backend.lastVerbCode, DmlVerb.update.code);
      expect(backend.lastVerbCode, 1);
    });

    test('appendReturningClause passes delete verb code', () {
      final backend = _FakeDriverFeatureBackend()
        ..returningResponse = 'DELETE FROM t OUTPUT deleted.id'.utf8Bytes;
      OdbcDriverFeatures.withBackend(backend).appendReturningClause(
        connectionString: 'DSN=SqlServer',
        sql: 'DELETE FROM t WHERE id=?',
        verb: DmlVerb.delete,
        columns: const ['id'],
      );

      expect(backend.lastVerbCode, DmlVerb.delete.code);
      expect(backend.lastVerbCode, 2);
    });

    test('getSessionInitSql serializes options and handles non-list payloads',
        () {
      final backend = _FakeDriverFeatureBackend()
        ..sessionResponse = jsonEncode(['SET search_path=public']).utf8Bytes;
      final features = OdbcDriverFeatures.withBackend(backend);

      final statements = features.getSessionInitSql(
        connectionString: 'DSN=Postgres',
        options: const SessionOptions(schema: 'public'),
      );

      expect(statements, ['SET search_path=public']);
      expect(jsonDecode(backend.lastOptionsJson!), {'schema': 'public'});

      backend.sessionResponse = jsonEncode({'ignored': true}).utf8Bytes;
      expect(
        features.getSessionInitSql(connectionString: 'DSN=Postgres'),
        isEmpty,
      );
      expect(backend.lastOptionsJson, isNull);
    });

    test('getSessionInitSql passes options JSON when only extraSql set', () {
      final backend = _FakeDriverFeatureBackend()
        ..sessionResponse = jsonEncode(['SET x=1']).utf8Bytes;
      final features = OdbcDriverFeatures.withBackend(backend);

      final statements = features.getSessionInitSql(
        connectionString: 'DSN=Postgres',
        options: const SessionOptions(extraSql: ['SET x=1']),
      );

      expect(statements, ['SET x=1']);
      expect(jsonDecode(backend.lastOptionsJson!), {
        'extra_sql': ['SET x=1'],
      });
    });

    test('getSessionInitSql decodes multiple session statements', () {
      final backend = _FakeDriverFeatureBackend()
        ..sessionResponse = jsonEncode([
          'SET search_path=public',
          'SET timezone=UTC',
        ]).utf8Bytes;
      final features = OdbcDriverFeatures.withBackend(backend);

      final statements = features.getSessionInitSql(connectionString: 'CONN');

      expect(statements, ['SET search_path=public', 'SET timezone=UTC']);
      expect(backend.calls, ['session']);
      expect(backend.lastConnectionString, 'CONN');
    });

    test('appendReturningClause forwards sql to backend', () {
      final backend = _FakeDriverFeatureBackend()
        ..returningResponse = 'SELECT * FROM t'.utf8Bytes;
      final features = OdbcDriverFeatures.withBackend(backend);

      final sql = features.appendReturningClause(
        connectionString: 'CONN',
        sql: 'INSERT INTO t(id) VALUES (?)',
        verb: DmlVerb.insert,
        columns: const ['id'],
      );

      expect(sql, 'SELECT * FROM t');
      expect(backend.lastSql, 'INSERT INTO t(id) VALUES (?)');
    });

    test('returns null when backend buffer call fails', () {
      final backend = _FakeDriverFeatureBackend()
        ..upsertResponse = null
        ..returningResponse = null
        ..sessionResponse = null;
      final features = OdbcDriverFeatures.withBackend(backend);

      expect(
        features.buildUpsertSql(
          connectionString: 'DSN=Test',
          table: 'users',
          columns: const ['id'],
          conflictColumns: const ['id'],
        ),
        isNull,
      );
      expect(
        features.appendReturningClause(
          connectionString: 'DSN=Test',
          sql: 'INSERT INTO users(id) VALUES (?)',
          verb: DmlVerb.insert,
          columns: const ['id'],
        ),
        isNull,
      );
      expect(
        features.getSessionInitSql(connectionString: 'DSN=Test'),
        isNull,
      );
    });
  });

  group('OdbcDriverFeatures (native FFI)', () {
    const postgresConn = 'Driver={PostgreSQL Unicode};Server=db;Database=app';

    late OdbcNative native;
    OdbcDriverFeatures? features;

    setUp(() {
      native = OdbcNative();
      if (native.init()) {
        features = OdbcDriverFeatures(native);
      }
    });

    tearDown(() => native.dispose());

    test('native constructor exposes capability API when symbols exist', () {
      final f = features;
      if (f == null || !f.supportsApi) {
        return;
      }
      expect(f.supportsApi, isTrue);
    });

    test('buildUpsertSql returns dialect SQL without connecting', () {
      final f = features;
      if (f == null || !f.supportsApi) {
        return;
      }
      final sql = f.buildUpsertSql(
        connectionString: postgresConn,
        table: 'public.users',
        columns: const ['id', 'name'],
        conflictColumns: const ['id'],
        updateColumns: const ['name'],
      );

      expect(sql, isNotNull);
      expect(sql!.toUpperCase(), contains('INSERT'));
      expect(sql.toUpperCase(), contains('CONFLICT'));
    });

    test('appendReturningClause returns RETURNING clause for PostgreSQL', () {
      final f = features;
      if (f == null || !f.supportsApi) {
        return;
      }
      final sql = f.appendReturningClause(
        connectionString: postgresConn,
        sql: 'INSERT INTO users (id) VALUES (?)',
        verb: DmlVerb.insert,
        columns: const ['id'],
      );

      expect(sql, isNotNull);
      expect(sql!.toUpperCase(), contains('RETURNING'));
    });

    test('getSessionInitSql decodes session statements from native backend',
        () {
      final f = features;
      if (f == null || !f.supportsApi) {
        return;
      }
      expect(
        f.getSessionInitSql(connectionString: postgresConn),
        isNotNull,
      );
      final statements = f.getSessionInitSql(
        connectionString: postgresConn,
        options: const SessionOptions(
          applicationName: 'odbc_fast_test',
          schema: 'public',
        ),
      );

      expect(statements, isNotNull);
    });
  });
}

extension on String {
  Uint8List get utf8Bytes => Uint8List.fromList(utf8.encode(this));
}

class _FakeDriverFeatureBackend implements OdbcDriverFeatureBackend {
  _FakeDriverFeatureBackend({this.supportsApi = true});

  @override
  final bool supportsApi;

  final List<String> calls = [];
  String? lastConnectionString;
  String? lastTable;
  String? lastPayloadJson;
  String? lastSql;
  int? lastVerbCode;
  String? lastColumnsCsv;
  String? lastOptionsJson;
  Uint8List? upsertResponse;
  Uint8List? returningResponse;
  Uint8List? sessionResponse;

  @override
  Uint8List? buildUpsertSql(
    String connectionString,
    String table,
    String payloadJson,
  ) {
    calls.add('upsert');
    lastConnectionString = connectionString;
    lastTable = table;
    lastPayloadJson = payloadJson;
    return upsertResponse;
  }

  @override
  Uint8List? appendReturningClause(
    String connectionString,
    String sql,
    int verbCode,
    String columnsCsv,
  ) {
    calls.add('returning');
    lastConnectionString = connectionString;
    lastSql = sql;
    lastVerbCode = verbCode;
    lastColumnsCsv = columnsCsv;
    return returningResponse;
  }

  @override
  Uint8List? getSessionInitSql(String connectionString, String? optionsJson) {
    calls.add('session');
    lastConnectionString = connectionString;
    lastOptionsJson = optionsJson;
    return sessionResponse;
  }
}
