import 'dart:convert';
import 'dart:io';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/odbc_fast.dart';

import '../example/common.dart' show loadExampleDsn;

Future<void> main() async {
  final dsn = loadExampleDsn();
  if (dsn == null) throw StateError('Test DSN required');
  final locator = ServiceLocator()
    ..initialize(profile: OdbcUsageProfile.balancedServer);
  final service = locator.service;
  final native = OdbcNative();
  if (!native.init()) throw StateError('Native initialization failed');
  final id = native.connect(dsn);
  if (id <= 0) throw StateError('Native connection failed');
  final results = <String, List<int>>{};
  try {
    (await service.initialize()).getOrThrow();
    final conn = (await service.connect(
      dsn,
      options: locator.recommendedConnectionOptions,
    ))
        .getOrThrow();
    try {
      final template =
          File('benchmarks/large_result_read.sql').readAsStringSync();
      for (final text in [false, true]) {
        final sql = template.replaceFirst(
          '/*payload*/',
          text
              ? ', CASE WHEN id % 7 = 0 THEN NULL ELSE '
                  "REPLICATE(CAST(N'Z' AS nvarchar(max)), 2048) END AS payload"
              : '',
        );
        final expected = 'Z' * 2048;
        for (var i = -4; i < 21; i++) {
          const paths = ['ffi', 'dart', 'columnar'];
          for (var offset = 0; offset < paths.length; offset++) {
            final path = paths[(i + offset) % paths.length];
            final watch = Stopwatch()..start();
            final consumed = Stopwatch()..start();
            final List<List<dynamic>> rows;
            if (path == 'ffi') {
              final bytes = native.execQuery(id, sql);
              watch.stop();
              if (bytes == null) throw StateError('FFI query failed');
              rows = BinaryProtocolParser.parse(bytes).rows;
            } else if (path == 'columnar') {
              final result =
                  (await service.executeQueryColumnarParamValues(conn.id, sql))
                      .getOrThrow();
              watch.stop();
              rows = fromTypedColumnar(result).rows;
            } else {
              rows = (await service.executeQuery(sql, connectionId: conn.id))
                  .getOrThrow()
                  .rows;
              watch.stop();
            }
            if (rows.length != 512) throw StateError('Row count mismatch');
            for (var r = 0; r < 512; r++) {
              final row = rows[r];
              if (row.length != (text ? 3 : 2) ||
                  row[0] != r ||
                  row[1] != r * 3 ||
                  (text &&
                      row[2]?.toString() != (r % 7 == 0 ? null : expected))) {
                throw StateError('Value mismatch at row $r');
              }
            }
            if (i >= 0) {
              (results['${path}_text_$text'] ??= [])
                  .add(watch.elapsedMicroseconds);
              (results['${path}_checked_text_$text'] ??= [])
                  .add(consumed.elapsedMicroseconds);
            }
          }
        }
      }
    } finally {
      (await service.disconnect(conn.id)).getOrThrow();
    }
  } finally {
    native.disconnect(id);
    locator.shutdown();
  }
  stdout.writeln(jsonEncode(results));
}
