import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/odbc_fast.dart';

import '../example/common.dart' show loadExampleDsn;

String _query(int count, int runLength) => '''
WITH digits(n) AS (
 SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS d(n)
), numbers AS (
 SELECT a.n+10*b.n+100*c.n+1000*d.n+10000*e.n AS id FROM digits a
 CROSS JOIN digits b CROSS JOIN digits c CROSS JOIN digits d
 CROSS JOIN (VALUES (0),(1)) AS e(n)
)
SELECT DATEADD(second, id / $runLength, CAST('20240506 12:13:14.123456' AS datetime2(6))) a,
 CASE WHEN id % 7<>0 THEN DATEADD(second, -(id / $runLength),
 CAST('20240506 12:13:14.987654' AS datetime2(6))) END b
FROM numbers WHERE id<$count ORDER BY id''';

void _verify(List<List<dynamic>> rows, List<(DateTime, DateTime?)> expected) {
  if (rows.length != expected.length) throw StateError('Unexpected row count');
  for (var i = 0; i < expected.length; i++) {
    final row = rows[i];
    if (row.length != 2 ||
        row[0] != expected[i].$1 ||
        row[1] != expected[i].$2) {
      throw StateError('Unexpected synthetic row $i: $row, types '
          '${row.map((value) => value.runtimeType).toList()}');
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first != '--trace-timers') {
    return _run(args);
  }
  var elapsed = 0;
  await runZoned(
    () => _run(args.sublist(1), timerMicros: () => elapsed),
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration != const Duration(milliseconds: 1)) {
          return parent.createTimer(zone, duration, callback);
        }
        final timer = Stopwatch()..start();
        return parent.createTimer(zone, duration, () {
          elapsed += timer.elapsedMicroseconds;
          callback();
        });
      },
    ),
  );
}

Future<void> _run(List<String> args, {int Function()? timerMicros}) async {
  final runLength = switch (args) {
    [] || ['--rows-512'] || ['--row-api-512'] => 1,
    ['--clustered'] => 64,
    _ => throw ArgumentError('Expected --clustered, --rows-512, '
        '--row-api-512 or no arguments'),
  };
  final rowApiOnly = args.contains('--row-api-512');
  final focusRows = args.contains('--rows-512') || rowApiOnly;
  final dsn = loadExampleDsn();
  if (dsn == null) throw StateError('Test DSN required');
  final locator = ServiceLocator()
    ..initialize(profile: OdbcUsageProfile.balancedServer);
  final native = OdbcNative();
  if (!native.init()) throw StateError('Native initialization failed');
  final id = native.connect(dsn);
  if (id <= 0) throw StateError('Connection failed');
  final samples = <String, List<int>>{};
  try {
    final service = locator.service;
    (await service.initialize()).getOrThrow();
    final conn = (await service.connect(
      dsn,
      options: locator.recommendedConnectionOptions,
    ))
        .getOrThrow();
    try {
      for (final n in focusRows ? const [512] : const [1, 512, 16384]) {
        final sql = _query(n, runLength);
        final expected = List.generate(n, (i) {
          final seconds = i ~/ runLength;
          return (
            DateTime(2024, 5, 6, 12, 13, 14 + seconds, 123, 456),
            i % 7 == 0
                ? null
                : DateTime(2024, 5, 6, 12, 13, 14 - seconds, 987, 654),
          );
        });
        final frames = {
          for (final enc in ResultEncoding.values)
            enc: native.execQueryParams(id, sql, null, resultEncoding: enc) ??
                (throw StateError('Frame missing')),
        };
        for (final entry in frames.entries) {
          final version = ByteData.sublistView(entry.value).getUint16(
            4,
            Endian.little,
          );
          if (version != (entry.key.isColumnar ? 2 : 1)) {
            throw StateError('Unexpected protocol version for ${entry.key}');
          }
        }
        for (var i = focusRows ? -5 : -3; i < (focusRows ? 25 : 9); i++) {
          for (var j = 0; j < (rowApiOnly ? 1 : 5); j++) {
            final path = rowApiOnly ? 0 : (i + j) % 5;
            final waitStart = timerMicros?.call() ?? 0;
            final timer = Stopwatch()..start();
            List<List<dynamic>>? rows;
            TypedColumnarResult? typed;
            if (path == 0) {
              rows = (await service.executeQuery(sql, connectionId: conn.id))
                  .getOrThrow()
                  .rows;
            } else if (path == 1) {
              typed =
                  (await service.executeQueryColumnarParamValues(conn.id, sql))
                      .getOrThrow();
            } else if (path == 2) {
              rows =
                  BinaryProtocolParser.parse(frames[ResultEncoding.rowMajor]!)
                      .rows;
            } else {
              typed = BinaryProtocolParser.parseColumnarToTyped(
                frames[ResultEncoding.values[path - 2]]!,
              );
            }
            timer.stop();
            if (i >= 0 && path == 0 && timerMicros != null) {
              (samples['api_row_1ms_timer_us_$n'] ??= [])
                  .add(timerMicros() - waitStart);
            }
            _verify(rows ?? fromTypedColumnar(typed!).rows, expected);
            if (i >= 0) {
              const paths = [
                'api_row',
                'api_column',
                'parse_row',
                'parse_column',
                'parse_compressed',
              ];
              (samples['${paths[path]}_$n'] ??= [])
                  .add(timer.elapsedMicroseconds);
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
  stdout.writeln(jsonEncode({'run_length': runLength, 'samples_us': samples}));
}
