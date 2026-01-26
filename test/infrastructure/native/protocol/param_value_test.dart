import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';

import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

void main() {
  group('ParamValue serialization', () {
    test('ParamValueNull produces tag 0 and len 0', () {
      final s = const ParamValueNull().serialize();
      expect(s.length, equals(5));
      expect(s[0], equals(0));
      expect(
          ByteData.sublistView(Uint8List.fromList(s))
              .getUint32(1, Endian.little),
          equals(0));
    });

    test('ParamValueString produces tag 1, len, utf8 bytes', () {
      final s = const ParamValueString('hi').serialize();
      expect(s[0], equals(1));
      final len = ByteData.sublistView(Uint8List.fromList(s))
          .getUint32(1, Endian.little);
      expect(len, equals(2));
      expect(s.sublist(5), equals([104, 105]));
    });

    test('ParamValueInt32 produces tag 2, len 4, i32 LE', () {
      final s = const ParamValueInt32(42).serialize();
      expect(s[0], equals(2));
      expect(
          ByteData.sublistView(Uint8List.fromList(s))
              .getUint32(1, Endian.little),
          equals(4));
      expect(
          ByteData.sublistView(Uint8List.fromList(s))
              .getInt32(5, Endian.little),
          equals(42));
    });

    test('ParamValueInt64 produces tag 3, len 8, i64 LE', () {
      final s = const ParamValueInt64(0x123456789abcdef0).serialize();
      expect(s[0], equals(3));
      expect(
          ByteData.sublistView(Uint8List.fromList(s))
              .getUint32(1, Endian.little),
          equals(8));
      expect(
          ByteData.sublistView(Uint8List.fromList(s))
              .getInt64(5, Endian.little),
          equals(0x123456789abcdef0));
    });

    test('ParamValueDecimal produces tag 4, len, utf8 bytes', () {
      final s = const ParamValueDecimal('3.14').serialize();
      expect(s[0], equals(4));
      final len = ByteData.sublistView(Uint8List.fromList(s))
          .getUint32(1, Endian.little);
      expect(len, equals(4));
      expect(s.sublist(5, 9), equals(utf8.encode('3.14')));
    });

    test('ParamValueBinary produces tag 5, len, payload', () {
      final s = const ParamValueBinary([1, 2, 3]).serialize();
      expect(s[0], equals(5));
      expect(
          ByteData.sublistView(Uint8List.fromList(s))
              .getUint32(1, Endian.little),
          equals(3));
      expect(s.sublist(5), equals([1, 2, 3]));
    });

    test('serializeParams concatenates multiple params', () {
      final params = [
        const ParamValueNull(),
        const ParamValueInt32(1),
        const ParamValueString('x'),
      ];
      final buf = serializeParams(params);
      expect(buf.isNotEmpty, isTrue);
      expect(buf[0], equals(0));
      final second = 5;
      expect(buf[second], equals(2));
    });
  });
}
