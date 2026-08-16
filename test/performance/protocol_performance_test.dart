import 'dart:io';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/bulk_insert_builder.dart';
import 'package:odbc_fast/infrastructure/native/protocol/frame_accumulator.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/native/protocol/protocol_byte_accumulator.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
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

      // Smoke check against actual builder path (addRow + full build).
      final builder = BulkInsertBuilder()
          .table('perf_table')
          .addColumn('a', BulkColumnType.i32)
          .addColumn('b', BulkColumnType.text, maxLen: 32)
          .addColumn('c', BulkColumnType.i32);
      final buildWatch = Stopwatch()..start();
      for (var i = 0; i < rows; i++) {
        builder.addRow(<dynamic>[i, 'name_$i', i * 2]);
      }
      final payload = builder.build();
      buildWatch.stop();
      print(
        'P1.2 BulkInsertBuilder addRow+build x$rows: '
        '${buildWatch.elapsedMilliseconds}ms',
      );
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
      const warmupIterations = 20000;
      final sample = _PerfUnsupportedType();

      // Warm up both code paths so JIT compilation is amortized
      // before either Stopwatch starts. Without warmup the first loop
      // pays the JIT cost and the comparison becomes flaky under
      // concurrent CI load (the suite-level run was failing while
      // isolated runs passed). See `test/performance/README` for the
      // policy on perf-test stability.
      var warmupLegacy = 0;
      var warmupBuffer = 0;
      for (var i = 0; i < warmupIterations; i++) {
        warmupLegacy += _legacyUnsupportedTypeMessage(sample).length;
        warmupBuffer += _stringBufferUnsupportedTypeMessage(sample).length;
      }
      // Touch the warmup totals so the optimizer can't elide the
      // warmup loop entirely.
      expect(warmupLegacy, equals(warmupBuffer));

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
      // Pin that StringBuffer is not *materially* faster than interpolation.
      // Absolute micros swing a lot when this file shares the VM with
      // isolate stress tests under `dart test`; 30% matches the project
      // benchmark regression band in `doc/PERFORMANCE.md`.
      const noiseTolerance = 1.30;
      final maxAllowedLegacy =
          (bufferWatch.elapsedMicroseconds * noiseTolerance).round();
      expect(
        legacyWatch.elapsedMicroseconds,
        lessThanOrEqualTo(maxAllowedLegacy),
        reason: 'StringBuffer path should not be more than '
            '${((noiseTolerance - 1) * 100).round()}% faster than '
            'interpolation; if it consistently is, switch error '
            'messages to StringBuffer.',
      );
    });

    test('P2.1 columnar typed parse vs row-major path benchmark', () {
      const rows = 2000;
      const iterations = 30;
      final columnar = _columnarBuffer(rows: rows);

      final rowMajorWatch = Stopwatch()..start();
      var rowMajorCells = 0;
      for (var i = 0; i < iterations; i++) {
        final parsed = BinaryProtocolParser.parse(columnar);
        rowMajorCells += parsed.rows.length;
      }
      rowMajorWatch.stop();

      final typedWatch = Stopwatch()..start();
      var typedRows = 0;
      for (var i = 0; i < iterations; i++) {
        typedRows +=
            BinaryProtocolParser.parseColumnarToTyped(columnar).rowCount;
      }
      typedWatch.stop();

      print(
        'P2.1 row-major columnar parse: '
        '${rowMajorWatch.elapsedMilliseconds}ms, '
        'rows=$rowMajorCells',
      );
      print(
        'P2.1 typed columnar parse: ${typedWatch.elapsedMilliseconds}ms, '
        'rows=$typedRows',
      );

      expect(rowMajorCells, equals(rows * iterations));
      expect(typedRows, equals(rows * iterations));
    });

    test('P4.1 parser and framing synthetic benchmark', () {
      const rows = 2000;
      const iterations = 30;
      final rowMajor = _rowMajorBuffer(rows: rows);
      final columnar = _columnarBuffer(rows: rows);

      final rowMajorWatch = Stopwatch()..start();
      var rowMajorCells = 0;
      for (var i = 0; i < iterations; i++) {
        rowMajorCells += BinaryProtocolParser.parse(rowMajor).rows.length;
      }
      rowMajorWatch.stop();

      final columnarWatch = Stopwatch()..start();
      var columnarCells = 0;
      for (var i = 0; i < iterations; i++) {
        columnarCells += BinaryProtocolParser.parse(columnar).rows.length;
      }
      columnarWatch.stop();

      final framingWatch = Stopwatch()..start();
      var framed = 0;
      for (var i = 0; i < iterations; i++) {
        final accumulator = BinaryFrameAccumulator();
        for (var offset = 0; offset < columnar.length; offset += 13) {
          final end =
              offset + 13 < columnar.length ? offset + 13 : columnar.length;
          accumulator.add(Uint8List.sublistView(columnar, offset, end));
          framed += accumulator.drainFrames().length;
        }
      }
      framingWatch.stop();

      final multi = _multiResultFrames(rowMajor, columnar);
      final multiWatch = Stopwatch()..start();
      var decoded = 0;
      for (var i = 0; i < iterations; i++) {
        final decoder = MultiResultStreamDecoder();
        for (var offset = 0; offset < multi.length; offset += 17) {
          final end = offset + 17 < multi.length ? offset + 17 : multi.length;
          decoded +=
              decoder.feed(Uint8List.sublistView(multi, offset, end)).length;
        }
        decoder.assertExhausted();
      }
      multiWatch.stop();

      print(
        'P4.1 row-major parse: ${rowMajorWatch.elapsedMilliseconds}ms, '
        'rows=$rowMajorCells',
      );
      print(
        'P4.1 columnar parse: ${columnarWatch.elapsedMilliseconds}ms, '
        'rows=$columnarCells',
      );
      print(
        'P4.1 frame accumulator: ${framingWatch.elapsedMilliseconds}ms, '
        'frames=$framed',
      );
      print(
        'P4.1 multi-result decoder: ${multiWatch.elapsedMilliseconds}ms, '
        'items=$decoded',
      );

      expect(rowMajorCells, equals(rows * iterations));
      expect(columnarCells, equals(rows * iterations));
      expect(framed, equals(iterations));
      expect(decoded, equals(2 * iterations));
    });

    test('P4.1b multi-result decoder chunk sizes (stress vs realistic)', () {
      const rows = 2000;
      const iterations = 30;
      final rowMajor = _rowMajorBuffer(rows: rows);
      final columnar = _columnarBuffer(rows: rows);
      final multi = _multiResultFrames(rowMajor, columnar);

      int runDecoder(int chunkStep) {
        var decoded = 0;
        for (var i = 0; i < iterations; i++) {
          final decoder = MultiResultStreamDecoder();
          for (var offset = 0; offset < multi.length; offset += chunkStep) {
            final end = offset + chunkStep < multi.length
                ? offset + chunkStep
                : multi.length;
            decoded +=
                decoder.feed(Uint8List.sublistView(multi, offset, end)).length;
          }
          decoder.assertExhausted();
        }
        return decoded;
      }

      final stressWatch = Stopwatch()..start();
      final stressDecoded = runDecoder(17);
      stressWatch.stop();

      final realisticWatch = Stopwatch()..start();
      final realisticDecoded = runDecoder(1024);
      realisticWatch.stop();

      final fullWatch = Stopwatch()..start();
      final fullDecoded = runDecoder(multi.length);
      fullWatch.stop();

      print(
        'P4.1b multi-result decoder chunk=17: '
        '${stressWatch.elapsedMilliseconds}ms, items=$stressDecoded',
      );
      print(
        'P4.1b multi-result decoder chunk=1024: '
        '${realisticWatch.elapsedMilliseconds}ms, items=$realisticDecoded',
      );
      print(
        'P4.1b multi-result decoder chunk=full: '
        '${fullWatch.elapsedMilliseconds}ms, items=$fullDecoded',
      );

      expect(stressDecoded, equals(2 * iterations));
      expect(realisticDecoded, equals(2 * iterations));
      expect(fullDecoded, equals(2 * iterations));

      if (Platform.environment['PERF_STRICT'] == '1') {
        expect(
          realisticWatch.elapsedMicroseconds,
          lessThan(stressWatch.elapsedMicroseconds * 4),
          reason: '1024-byte chunks should not be orders slower than '
              '17-byte stress',
        );
      }
    });

    test('P4.2 ProtocolByteAccumulator free-list acquire/offer', () {
      ProtocolByteAccumulator.clearPoolForTest();
      const iterations = 5000;
      final watch = Stopwatch()..start();
      var checksum = 0;
      for (var i = 0; i < iterations; i++) {
        final acc = ProtocolByteAccumulator()
          ..add(Uint8List(64 * 1024))
          ..add(Uint8List.fromList([1]));
        checksum ^= acc.length;
        // Growth offers the abandoned default backing back to the pool.
      }
      watch.stop();
      print(
        'P4.2 accumulator growth+pool: ${watch.elapsedMilliseconds}ms '
        '(checksum=$checksum, '
        'pool=${ProtocolByteAccumulator.pooledBackingCount})',
      );
      expect(ProtocolByteAccumulator.pooledBackingCount, greaterThan(0));
      expect(ProtocolByteAccumulator.pooledBackingCount, lessThanOrEqualTo(4));
      ProtocolByteAccumulator.clearPoolForTest();
    });

    test('P4.3 MULT first columnar RS typed decode', () {
      const iterations = 2000;
      final inner = _columnarBuffer(rows: 64);
      final mult = _multV2Envelope(inner);
      const parser = OdbcResultParser();

      final watch = Stopwatch()..start();
      var rows = 0;
      for (var i = 0; i < iterations; i++) {
        final typed = parser.parseBufferToTypedColumnar(mult);
        rows += typed!.rowCount;
      }
      watch.stop();
      print(
        'P4.3 MULT columnar→typed: ${watch.elapsedMilliseconds}ms '
        'rows=$rows',
      );
      expect(rows, equals(64 * iterations));
    });

    test('P4.4 row-major int-heavy decode', () {
      const rows = 4000;
      const iterations = 80;
      final buffer = _rowMajorIntHeavyBuffer(rows: rows);

      final watch = Stopwatch()..start();
      var cells = 0;
      for (var i = 0; i < iterations; i++) {
        final parsed = BinaryProtocolParser.parse(buffer);
        cells += parsed.rowCount * parsed.columnCount;
        expect(parsed.rows.first[0], isA<int>());
        expect(parsed.rows.first[1], isA<int>());
      }
      watch.stop();
      print(
        'P4.4 row-major int-heavy: ${watch.elapsedMilliseconds}ms '
        'cells=$cells',
      );
      expect(cells, equals(rows * 2 * iterations));
    });
  });
}

Uint8List _rowMajorIntHeavyBuffer({required int rows}) {
  final payload = <int>[];
  const columns = [
    (name: 'id', type: 2),
    (name: 'big', type: 3),
  ];
  for (final column in columns) {
    payload
      ..addAll(column.type.toBytes(2))
      ..addAll(column.name.length.toBytes(2))
      ..addAll(column.name.codeUnits);
  }
  for (var i = 0; i < rows; i++) {
    payload
      ..add(0)
      ..addAll(4.toBytes(4))
      ..addAll((-i).toBytes(4))
      ..add(0)
      ..addAll(8.toBytes(4))
      ..addAll((i * 10000000000).toBytes(8));
  }
  return Uint8List.fromList(
    <int>[
      ...BinaryProtocolParser.magic.toBytes(4),
      ...BinaryProtocolParser.protocolVersionRowMajor.toBytes(2),
      ...columns.length.toBytes(2),
      ...rows.toBytes(4),
      ...payload.length.toBytes(4),
      ...payload,
    ],
  );
}

Uint8List _multV2Envelope(Uint8List inner) {
  final out = BytesBuilder()
    ..add(_u32List(multiResultMagic))
    ..add(_u16List(multiResultVersionV2))
    ..add(_u16List(0))
    ..add(_u32List(1))
    ..addByte(MultiResultParser.tagResultSet)
    ..add(_u32List(inner.length))
    ..add(inner);
  return out.toBytes();
}

List<int> _u32List(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

List<int> _u16List(int v) {
  final b = ByteData(2)..setUint16(0, v, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _rowMajorBuffer({required int rows}) {
  final payload = <int>[];
  const columns = [
    (name: 'id', type: 2),
    (name: 'name', type: 1),
    (name: 'count', type: 3),
  ];
  for (final column in columns) {
    payload
      ..addAll(column.type.toBytes(2))
      ..addAll(column.name.length.toBytes(2))
      ..addAll(column.name.codeUnits);
  }
  for (var i = 0; i < rows; i++) {
    final name = 'name_$i'.codeUnits;
    payload
      ..add(0)
      ..addAll(4.toBytes(4))
      ..addAll(i.toBytes(4))
      ..add(0)
      ..addAll(name.length.toBytes(4))
      ..addAll(name)
      ..add(0)
      ..addAll(8.toBytes(4))
      ..addAll((i * 10000000000).toBytes(8));
  }
  return Uint8List.fromList(
    <int>[
      ...BinaryProtocolParser.magic.toBytes(4),
      ...BinaryProtocolParser.protocolVersionRowMajor.toBytes(2),
      ...columns.length.toBytes(2),
      ...rows.toBytes(4),
      ...payload.length.toBytes(4),
      ...payload,
    ],
  );
}

Uint8List _columnarBuffer({required int rows}) {
  const columns = [
    (name: 'id', type: 2),
    (name: 'name', type: 1),
    (name: 'count', type: 3),
  ];
  final payload = <int>[];
  for (final column in columns) {
    final raw = <int>[];
    for (var i = 0; i < rows; i++) {
      raw.add(0);
      if (column.type == 2) {
        raw.addAll(i.toBytes(4));
      } else if (column.type == 3) {
        raw.addAll((i * 10000000000).toBytes(8));
      } else {
        final bytes = 'name_$i'.codeUnits;
        raw
          ..addAll(bytes.length.toBytes(4))
          ..addAll(bytes);
      }
    }
    payload
      ..addAll(column.type.toBytes(2))
      ..addAll(column.name.length.toBytes(2))
      ..addAll(column.name.codeUnits)
      ..add(0)
      ..addAll(raw.length.toBytes(4))
      ..addAll(raw);
  }
  return Uint8List.fromList(
    <int>[
      ...BinaryProtocolParser.magic.toBytes(4),
      ...BinaryProtocolParser.protocolVersionColumnarV2.toBytes(2),
      ...0.toBytes(2),
      ...columns.length.toBytes(2),
      ...rows.toBytes(4),
      0,
      ...payload.length.toBytes(4),
      ...payload,
    ],
  );
}

Uint8List _multiResultFrames(Uint8List first, Uint8List second) {
  final bytes = <int>[];
  for (final payload in [first, second]) {
    bytes
      ..add(multiStreamItemTagResultSet)
      ..addAll(payload.length.toBytes(4))
      ..addAll(payload);
  }
  return Uint8List.fromList(bytes);
}

extension _IntBytes on int {
  List<int> toBytes(int length) {
    final bytes = <int>[];
    for (var i = 0; i < length; i++) {
      bytes.add((this >> (i * 8)) & 0xFF);
    }
    return bytes;
  }
}
