// Demonstrates opt-in result encodings for parameterized query execution.
//
// Row-major remains the default. Use columnar modes only after validating the
// target workload and driver.
//
// Run:
//   dart run example/columnar_result_encoding_demo.dart
//
// Optional:
//   ODBC_TEST_DSN=...
//   ODBC_COLUMNAR_QUERY="SELECT 1 AS id, 'alpha' AS label"

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final sql = Platform.environment['ODBC_COLUMNAR_QUERY'] ??
      "SELECT 1 AS id, 'alpha' AS label";
  final native = NativeOdbcConnection();
  final repository = OdbcRepositoryImpl(native);
  final service = OdbcService(repository);

  if ((await service.initialize()).isError()) {
    AppLogger.severe('initialize failed');
    return;
  }
  final connect = await service.connect(dsn);
  if (connect.isError()) {
    AppLogger.severe('connect: ${connect.exceptionOrNull()}');
    return;
  }

  final connId = connect.getOrThrow().id;
  try {
    for (final encoding in ResultEncoding.values) {
      final result = await service.executeQueryParams(
        connId,
        sql,
        const <Object?>[],
        resultEncoding: encoding,
      );
      result.fold(
        (ok) => AppLogger.info(
          '${encoding.name}: rowCount=${ok.rowCount}, '
          'columns=${ok.columns.length}, '
          'firstRow=${ok.rows.isEmpty ? const <Object?>[] : ok.rows.first}',
        ),
        (error) => AppLogger.warning(
          '${encoding.name} failed: $error. '
          'For compressed columnar, confirm the loaded native library exports '
          'odbc_columnar_decompress.',
        ),
      );
    }
  } finally {
    await service.disconnect(connId);
  }
}
