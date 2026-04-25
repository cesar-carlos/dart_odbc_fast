import 'dart:convert';
import 'dart:typed_data';

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
