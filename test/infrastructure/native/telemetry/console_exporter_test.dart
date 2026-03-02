/// Unit tests for [ConsoleExporter].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:odbc_fast/infrastructure/native/telemetry/console.dart';
import 'package:test/test.dart';

void main() {
  group('ConsoleExporter', () {
    late List<String> capturedLines;
    late io.IOSink captureSink;

    setUp(() {
      capturedLines = [];
      captureSink = _createCaptureSink(capturedLines);
    });

    test('exportTrace returns Success and writes trace to output', () async {
      final exporter = ConsoleExporter(output: captureSink);
      final trace = Trace(
        traceId: 't1',
        name: 'test.op',
        startTime: DateTime.now(),
      );

      final result = await exporter.exportTrace(trace);
      await captureSink.flush();

      expect(result.isSuccess(), true);
      expect(capturedLines.length, 1);
      expect(capturedLines[0], contains('[TRACE]'));
      expect(capturedLines[0], contains('t1'));
      expect(capturedLines[0], contains('test.op'));
    });

    test('exportSpan returns Success and writes span to output', () async {
      final exporter = ConsoleExporter(output: captureSink);
      final span = Span(
        spanId: 's1',
        name: 'test.span',
        startTime: DateTime.now(),
      );

      final result = await exporter.exportSpan(span);
      await captureSink.flush();

      expect(result.isSuccess(), true);
      expect(capturedLines.length, 1);
      expect(capturedLines[0], contains('[SPAN]'));
      expect(capturedLines[0], contains('s1'));
    });

    test('exportMetric returns Success and writes metric to output', () async {
      final exporter = ConsoleExporter(output: captureSink);
      final metric = Metric(
        name: 'latency',
        value: 42,
        unit: 'ms',
        timestamp: DateTime.now(),
      );

      final result = await exporter.exportMetric(metric);
      await captureSink.flush();

      expect(result.isSuccess(), true);
      expect(capturedLines.length, 1);
      expect(capturedLines[0], contains('[METRIC]'));
      expect(capturedLines[0], contains('latency'));
    });

    test('exportEvent returns Success and writes event to output', () async {
      final exporter = ConsoleExporter(output: captureSink);
      final event = TelemetryEvent(
        name: 'error',
        timestamp: DateTime.now(),
        severity: TelemetrySeverity.error,
        message: 'Something failed',
      );

      final result = await exporter.exportEvent(event);
      await captureSink.flush();

      expect(result.isSuccess(), true);
      expect(capturedLines.length, 1);
      expect(capturedLines[0], contains('[EVENT]'));
      expect(capturedLines[0], contains('error'));
    });
  });
}

io.IOSink _createCaptureSink(List<String> lines) {
  final controller = StreamController<List<int>>();
  controller.stream.transform(utf8.decoder).listen((chunk) {
    for (final line in chunk.split('\n')) {
      if (line.isNotEmpty) {
        lines.add(line);
      }
    }
  });
  return io.IOSink(controller.sink);
}
