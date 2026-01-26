import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';

List<int> _buildStructuredErrorBuffer({
  required String sqlState,
  required int nativeCode,
  required String message,
}) {
  final msgBytes = utf8.encode(message);
  final buf = ByteData(13 + msgBytes.length);
  for (var i = 0; i < 5 && i < sqlState.length; i++) {
    buf.setUint8(i, sqlState.codeUnitAt(i));
  }
  buf.setInt32(5, nativeCode, Endian.little);
  buf.setUint32(9, msgBytes.length, Endian.little);
  for (var i = 0; i < msgBytes.length; i++) {
    buf.setUint8(13 + i, msgBytes[i]);
  }
  return buf.buffer.asUint8List().toList();
}

void main() {
  group('StructuredError.deserialize', () {
    test('decodes UTF-8 message with accents correctly', () {
      final buf = _buildStructuredErrorBuffer(
        sqlState: '08S01',
        nativeCode: -1,
        message: 'Conexão perdida: erro de comunicação',
      );
      final e = StructuredError.deserialize(buf);
      expect(e, isNotNull);
      expect(e!.message, equals('Conexão perdida: erro de comunicação'));
      expect(e.nativeCode, equals(-1));
      expect(e.sqlStateString, equals('08S01'));
    });

    test('decodes UTF-8 message with emoji correctly', () {
      final buf = _buildStructuredErrorBuffer(
        sqlState: 'HY000',
        nativeCode: 0,
        message: 'Error \u{1F4A5} debug',
      );
      final e = StructuredError.deserialize(buf);
      expect(e, isNotNull);
      expect(e!.message, equals('Error \u{1F4A5} debug'));
    });

    test('returns null when buffer has fewer than 13 bytes', () {
      expect(StructuredError.deserialize([]), isNull);
      expect(StructuredError.deserialize([0, 1, 2]), isNull);
      expect(
        StructuredError.deserialize(List.filled(12, 0)),
        isNull,
      );
    });

    test('returns null when message region is truncated', () {
      final buf = ByteData(13);
      buf.setUint8(0, 0x30);
      buf.setUint8(1, 0x38);
      buf.setUint8(2, 0x53);
      buf.setUint8(3, 0x30);
      buf.setUint8(4, 0x31);
      buf.setInt32(5, 0, Endian.little);
      buf.setUint32(9, 100, Endian.little);
      expect(
        StructuredError.deserialize(buf.buffer.asUint8List().toList()),
        isNull,
      );
    });

    test('deserializes valid minimal message', () {
      final buf = _buildStructuredErrorBuffer(
        sqlState: '08001',
        nativeCode: 123,
        message: '',
      );
      final e = StructuredError.deserialize(buf);
      expect(e, isNotNull);
      expect(e!.message, equals(''));
      expect(e.nativeCode, equals(123));
    });
  });
}
