import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcMetrics.fromBytes', () {
    test('parses 40-byte buffer correctly', () {
      final b = ByteData(40);
      b.setUint64(0, 100, Endian.little);
      b.setUint64(8, 5, Endian.little);
      b.setUint64(16, 3600, Endian.little);
      b.setUint64(24, 50000, Endian.little);
      b.setUint64(32, 500, Endian.little);
      final m = OdbcMetrics.fromBytes(b.buffer.asUint8List(0, 40));
      expect(m.queryCount, equals(100));
      expect(m.errorCount, equals(5));
      expect(m.uptimeSecs, equals(3600));
      expect(m.totalLatencyMillis, equals(50000));
      expect(m.avgLatencyMillis, equals(500));
    });

    test('handles zeroed buffer', () {
      final b = Uint8List(40);
      final m = OdbcMetrics.fromBytes(b);
      expect(m.queryCount, equals(0));
      expect(m.errorCount, equals(0));
      expect(m.uptimeSecs, equals(0));
      expect(m.totalLatencyMillis, equals(0));
      expect(m.avgLatencyMillis, equals(0));
    });
  });
}
