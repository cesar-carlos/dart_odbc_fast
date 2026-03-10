import 'dart:io';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/bulk_insert_builder.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:test/test.dart';

List<int> _legacyU32Le(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return b.buffer.asUint8List(0, 4).toList();
}

List<int> _optimizedU32Le(int v) {
  final buffer = Uint8List(4);
  ByteData.view(buffer.buffer).setUint32(0, v, Endian.little);
  return buffer;
}

String _legacyUnsupportedTypeMessage(Object value) {
  return 'Unsupported parameter type: ${value.runtimeType}. '
      'Expected one of: null, int, String, List<int>, bool, double, DateTime, '
      'or ParamValue. '
      'Use explicit ParamValue wrapper if needed, e.g., '
      'ParamValueString(value) for custom string conversion.';
}

String _stringBufferUnsupportedTypeMessage(Object value) {
  final buffer = StringBuffer()
    ..write('Unsupported parameter type: ')
    ..write(value.runtimeType)
    ..write('. ')
    ..write(
      'Expected one of: null, int, String, List<int>, bool, double, DateTime, '
      'or ParamValue. ',
    )
    ..write('Use explicit ParamValue wrapper if needed, e.g., ')
    ..write('ParamValueString(value) for custom string conversion.');
  return buffer.toString();
}

class _PerfUnsupportedType {}

void main() {
  group('Protocol Performance Benchmarks', () {
    test('P1.1 serialization helper benchmark (legacy vs optimized)', () {
      const iterations = 200000;

      final legacyWatch = Stopwatch()..start();
      var legacyChecksum = 0;
      for (var i = 0; i < iterations; i++) {
        final bytes = _legacyU32Le(i);
        legacyChecksum ^= bytes[0];
      }
      legacyWatch.stop();

      final optimizedWatch = Stopwatch()..start();
      var optimizedChecksum = 0;
      for (var i = 0; i < iterations; i++) {
        final bytes = _optimizedU32Le(i);
        optimizedChecksum ^= bytes[0];
      }
      optimizedWatch.stop();

      print('P1.1 benchmark iterations: $iterations');
      print(
        'legacy _u32Le: ${legacyWatch.elapsedMilliseconds}ms '
        '(checksum=$legacyChecksum)',
      );
      print(
        'optimized _u32Le: ${optimizedWatch.elapsedMilliseconds}ms '
        '(checksum=$optimizedChecksum)',
      );
      final ratio =
          optimizedWatch.elapsedMicroseconds / legacyWatch.elapsedMicroseconds;
      print('optimized/legacy ratio: ${ratio.toStringAsFixed(3)}');

      // Correctness and sanity checks.
      expect(legacyChecksum, equals(optimizedChecksum));
      expect(legacyWatch.elapsedMilliseconds, greaterThanOrEqualTo(0));
      expect(optimizedWatch.elapsedMilliseconds, greaterThanOrEqualTo(0));
    });

    test('P1.2 addRow ownership benchmark (copy vs reference)', () {
      const rows = 25000;

      List<List<dynamic>> buildRows() {
        return List<List<dynamic>>.generate(
          rows,
          (i) => <dynamic>[i, 'name_$i', i * 2],
          growable: false,
        );
      }

      final dataForCopy = buildRows();
      final rssBeforeCopy = ProcessInfo.currentRss;
      final copyWatch = Stopwatch()..start();
      final copiedRows = <List<dynamic>>[];
      for (final row in dataForCopy) {
        copiedRows.add(List<dynamic>.from(row));
      }
      copyWatch.stop();
      final rssAfterCopy = ProcessInfo.currentRss;

      final dataForRef = buildRows();
      final rssBeforeRef = ProcessInfo.currentRss;
      final refWatch = Stopwatch()..start();
      final refRows = <List<dynamic>>[];
      dataForRef.forEach(refRows.add);
      refWatch.stop();
      final rssAfterRef = ProcessInfo.currentRss;

      print('P1.2 benchmark rows: $rows');
      print(
        'copy path: ${copyWatch.elapsedMilliseconds}ms, '
        'rss delta: ${rssAfterCopy - rssBeforeCopy} bytes',
      );
      print(
        'reference path: ${refWatch.elapsedMilliseconds}ms, '
        'rss delta: ${rssAfterRef - rssBeforeRef} bytes',
      );

      // Sanity checks.
      expect(copiedRows.length, equals(rows));
      expect(refRows.length, equals(rows));

      // Smoke check against actual builder path.
      final builder = BulkInsertBuilder()
          .table('perf_table')
          .addColumn('a', BulkColumnType.i32)
          .addColumn('b', BulkColumnType.text, maxLen: 32)
          .addColumn('c', BulkColumnType.i32);
      dataForRef.take(1000).forEach(builder.addRow);
      final payload = builder.build();
      expect(payload.isNotEmpty, isTrue);
    });

    test('P1.1 end-to-end ParamValue serialization smoke benchmark', () {
      const iterations = 50000;
      final params = <ParamValue>[
        const ParamValueInt32(123),
        const ParamValueInt64(9999999999),
        const ParamValueString('hello'),
        const ParamValueDecimal('123.456'),
        const ParamValueBinary(<int>[1, 2, 3, 4]),
      ];

      final watch = Stopwatch()..start();
      var totalBytes = 0;
      for (var i = 0; i < iterations; i++) {
        totalBytes += serializeParams(params).length;
      }
      watch.stop();

      print(
        'ParamValue serializeParams x$iterations: '
        '${watch.elapsedMilliseconds}ms, totalBytes=$totalBytes',
      );
      expect(totalBytes, greaterThan(0));
    });

    test('P3.5 error-message construction benchmark', () {
      const iterations = 200000;
      final sample = _PerfUnsupportedType();

      final legacyWatch = Stopwatch()..start();
      var legacyTotalLength = 0;
      for (var i = 0; i < iterations; i++) {
        legacyTotalLength += _legacyUnsupportedTypeMessage(sample).length;
      }
      legacyWatch.stop();

      final bufferWatch = Stopwatch()..start();
      var bufferTotalLength = 0;
      for (var i = 0; i < iterations; i++) {
        bufferTotalLength += _stringBufferUnsupportedTypeMessage(sample).length;
      }
      bufferWatch.stop();

      print('P3.5 benchmark iterations: $iterations');
      print(
        'legacy interpolation message: ${legacyWatch.elapsedMilliseconds}ms, '
        'totalLength=$legacyTotalLength',
      );
      print(
        'StringBuffer message: ${bufferWatch.elapsedMilliseconds}ms, '
        'totalLength=$bufferTotalLength',
      );

      expect(bufferTotalLength, equals(legacyTotalLength));
    });
  });
}
