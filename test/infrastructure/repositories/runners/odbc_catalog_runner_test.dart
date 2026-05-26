/// Unit tests for [OdbcCatalogRunner].
library;

import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_catalog_runner.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

class _FakeNativeForCatalog extends NativeOdbcConnection {
  Uint8List? catalogTablesResult;
  Uint8List? catalogColumnsResult;
  Uint8List? catalogTypeInfoResult;
  Uint8List? catalogPrimaryKeysResult;
  Uint8List? catalogForeignKeysResult;
  Uint8List? catalogIndexesResult;

  String? lastTable;
  String? lastCatalog;
  String? lastSchema;

  @override
  Uint8List? catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  }) {
    lastCatalog = catalog;
    lastSchema = schema;
    return catalogTablesResult;
  }

  @override
  Uint8List? catalogColumns(int connectionId, String table) {
    lastTable = table;
    return catalogColumnsResult;
  }

  @override
  Uint8List? catalogTypeInfo(int connectionId) => catalogTypeInfoResult;

  @override
  Uint8List? catalogPrimaryKeys(int connectionId, String table) {
    lastTable = table;
    return catalogPrimaryKeysResult;
  }

  @override
  Uint8List? catalogForeignKeys(int connectionId, String table) {
    lastTable = table;
    return catalogForeignKeysResult;
  }

  @override
  Uint8List? catalogIndexes(int connectionId, String table) {
    lastTable = table;
    return catalogIndexesResult;
  }
}

QueryResult? _stubParser(Uint8List? buf) {
  if (buf == null || buf.isEmpty) return null;
  return const QueryResult(columns: ['c1'], rows: [], rowCount: 0);
}

Future<Failure<QueryResult, OdbcError>> _stubConvertError({
  required String fallbackMessage,
  int? nativeConnectionId,
}) async =>
    Failure<QueryResult, OdbcError>(QueryError(message: fallbackMessage));

void main() {
  group('OdbcCatalogRunner', () {
    late _FakeNativeForCatalog native;
    late OdbcCatalogRunner runner;

    setUp(() {
      native = _FakeNativeForCatalog();
      runner = OdbcCatalogRunner(
        backend: SyncBackend(native),
        nativeIdLookup: (id) => id == 'good' ? 42 : null,
        parseBuffer: _stubParser,
        convertQueryError: _stubConvertError,
      );
    });

    tearDown(() => native.dispose());

    test(
      'should_return_ValidationError_when_connectionId_is_unknown',
      () async {
        final r = await runner.catalogTables('unknown');
        expect(r.isError(), isTrue);
        expect(r.exceptionOrNull(), isA<ValidationError>());
      },
    );

    test('catalogTables forwards catalog and schema arguments', () async {
      native.catalogTablesResult = Uint8List.fromList([1, 2, 3]);
      await runner.catalogTables('good', catalog: 'cat', schema: 'sch');
      expect(native.lastCatalog, equals('cat'));
      expect(native.lastSchema, equals('sch'));
    });

    test('catalogColumns wraps successful buffer into QueryResult', () async {
      native.catalogColumnsResult = Uint8List.fromList([9]);
      final r = await runner.catalogColumns('good', 'users');
      expect(r.isSuccess(), isTrue);
      expect(native.lastTable, equals('users'));
    });

    test('catalogTypeInfo converts null buffer to QueryError', () async {
      native.catalogTypeInfoResult = null;
      final r = await runner.catalogTypeInfo('good');
      expect(r.isError(), isTrue);
      final err = r.exceptionOrNull()! as QueryError;
      expect(err.message, contains('catalog type info'));
    });

    test('catalogPrimaryKeys propagates the table argument', () async {
      native.catalogPrimaryKeysResult = Uint8List.fromList([1]);
      await runner.catalogPrimaryKeys('good', 'orders');
      expect(native.lastTable, equals('orders'));
    });

    test('catalogForeignKeys returns Success on non-empty buffer', () async {
      native.catalogForeignKeysResult = Uint8List.fromList([1]);
      final r = await runner.catalogForeignKeys('good', 'orders');
      expect(r.isSuccess(), isTrue);
    });

    test('catalogIndexes routes through the same scaffolding', () async {
      native.catalogIndexesResult = Uint8List.fromList([1]);
      final r = await runner.catalogIndexes('good', 'orders');
      expect(r.isSuccess(), isTrue);
      expect(native.lastTable, equals('orders'));
    });
  });
}
