/// Unit tests for [CatalogQuery] wrapper.
library;

import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/wrappers/catalog_query.dart';
import 'package:test/test.dart';

import '../../../helpers/binary_protocol_test_helper.dart';
import '../../../helpers/fake_odbc_backend.dart';

void main() {
  group('CatalogQuery', () {
    late FakeOdbcConnectionBackend backend;
    late CatalogQuery catalog;

    setUp(() {
      backend = FakeOdbcConnectionBackend();
      catalog = CatalogQuery(backend, 42);
    });

    test('connectionId returns constructor value', () {
      expect(catalog.connectionId, 42);
    });

    test('tables returns null when backend returns null', () {
      backend.catalogTablesResult = null;
      expect(catalog.tables(), isNull);
    });

    test('tables returns null when backend returns empty buffer', () {
      backend.catalogTablesResult = Uint8List(0);
      expect(catalog.tables(), isNull);
    });

    test('tables returns ParsedRowBuffer when backend returns valid data', () {
      backend.catalogTablesResult = createBinaryProtocolBuffer();
      final result = catalog.tables();
      expect(result, isNotNull);
      expect(result!.columnCount, 1);
      expect(result.rowCount, 0);
      expect(result.columns[0].name, 'id');
    });

    test('tables passes catalog and schema to backend', () {
      backend.catalogTablesResult = createBinaryProtocolBuffer();
      catalog.tables(catalog: 'MyDb', schema: 'dbo');
      expect(backend.catalogTablesResult, isNotNull);
    });

    test('columns returns null when backend returns null', () {
      backend.catalogColumnsResult = null;
      expect(catalog.columns('Users'), isNull);
    });

    test('columns returns ParsedRowBuffer when backend returns valid data', () {
      backend.catalogColumnsResult = createBinaryProtocolBuffer();
      final result = catalog.columns('Users');
      expect(result, isNotNull);
      expect(result!.columnCount, 1);
    });

    test('typeInfo returns null when backend returns null', () {
      backend.catalogTypeInfoResult = null;
      expect(catalog.typeInfo(), isNull);
    });

    test(
      'typeInfo returns ParsedRowBuffer when backend returns valid data',
      () {
        backend.catalogTypeInfoResult = createBinaryProtocolBuffer();
        final result = catalog.typeInfo();
        expect(result, isNotNull);
        expect(result!.columnCount, 1);
      },
    );

    test('tables returns null when parse throws FormatException', () {
      backend.catalogTablesResult = Uint8List.fromList([1, 2, 3, 4]);
      expect(catalog.tables(), isNull);
    });
  });
}
