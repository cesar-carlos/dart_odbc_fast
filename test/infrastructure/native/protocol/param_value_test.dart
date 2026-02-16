import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:test/test.dart';

/// Tests for Phase 1: Parameter conversion hardening.
///
/// Phase 1 changes:
/// - bool → ParamValueInt32(1|0) (canonical mapping)
/// - double → ParamValueDecimal(value.toString())
/// - DateTime → ParamValueString(value.toUtc().toIso8601String())
/// - Unsupported types → ArgumentError (no silent toString() fallback)
/// - Fast path for pre-typed `List<ParamValue>`
void main() {
  group('NULL handling', () {
    test('null value converts to ParamValueNull', () {
      final params = paramValuesFromObjects([null]);
      expect(params.length, equals(1));
      expect(params[0], isA<ParamValueNull>());
    });

    test('"null" string remains as string (not coerced to NULL)', () {
      final params = paramValuesFromObjects(['null']);
      expect(params.length, equals(1));
      expect(params[0], isA<ParamValueString>());
      final pv = params[0] as ParamValueString;
      expect(pv.value, equals('null'));
    });

    test('empty string remains as string', () {
      final params = paramValuesFromObjects(['']);
      expect(params.length, equals(1));
      expect(params[0], isA<ParamValueString>());
      final pv = params[0] as ParamValueString;
      expect(pv.value, equals(''));
    });

    test('multiple nulls and strings preserve semantics', () {
      final params = paramValuesFromObjects([
        null,
        'null',
        '',
        null,
      ]);
      expect(params[0], isA<ParamValueNull>());
      expect(params[1], isA<ParamValueString>());
      expect((params[1] as ParamValueString).value, equals('null'));
      expect(params[2], isA<ParamValueString>());
      expect((params[2] as ParamValueString).value, equals(''));
      expect(params[3], isA<ParamValueNull>());
    });
  });

  group('Canonical type mappings (Phase 1)', () {
    test('bool -> ParamValueInt32(1|0)', () {
      final params = paramValuesFromObjects([true, false]);
      expect(params[0], isA<ParamValueInt32>());
      expect((params[0] as ParamValueInt32).value, equals(1));
      expect(params[1], isA<ParamValueInt32>());
      expect((params[1] as ParamValueInt32).value, equals(0));
    });

    test('double -> ParamValueDecimal', () {
      final params = paramValuesFromObjects([3.14, 0.0, -42.5]);
      expect(params[0], isA<ParamValueDecimal>());
      expect((params[0] as ParamValueDecimal).value, equals('3.14'));
      expect(params[1], isA<ParamValueDecimal>());
      expect((params[1] as ParamValueDecimal).value, equals('0.0'));
      expect(params[2], isA<ParamValueDecimal>());
      expect((params[2] as ParamValueDecimal).value, equals('-42.5'));
    });

    test('DateTime -> ParamValueString with UTC ISO8601', () {
      final dt = DateTime.utc(2024, 1, 15, 10, 30, 45);
      final params = paramValuesFromObjects([dt]);
      expect(params[0], isA<ParamValueString>());
      final pv = params[0] as ParamValueString;
      expect(pv.value, equals('2024-01-15T10:30:45.000Z'));
    });

    test('local DateTime converts to UTC ISO8601', () {
      final dt = DateTime(2024, 1, 15, 10, 30, 45);
      final params = paramValuesFromObjects([dt]);
      expect(params[0], isA<ParamValueString>());
      final pv = params[0] as ParamValueString;
      // Should be converted to UTC
      expect(pv.value, contains('T'));
      expect(pv.value, contains('Z'));
    });
  });

  group('Unsupported type errors (Phase 1)', () {
    test('custom object throws ArgumentError', () {
      final custom = _CustomObject();
      expect(
        () => paramValuesFromObjects([custom]),
        throwsA(
          isA<ArgumentError>()
              .having(
                (e) => e.message,
                'message',
                contains('_CustomObject'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('Unsupported parameter type'),
              ),
        ),
      );
    });

    test('error message suggests ParamValue wrapper', () {
      final custom = _CustomObject();
      expect(
        () => paramValuesFromObjects([custom]),
        throwsA(
          isA<ArgumentError>()
              .having(
                (e) => e.message,
                'message',
                contains('ParamValue wrapper'),
              ),
        ),
      );
    });

    test('List<String> throws ArgumentError', () {
      expect(
        () => paramValuesFromObjects([['a', 'b']]),
        throwsA(
          isA<ArgumentError>()
              .having(
                (e) => e.message,
                'message',
                contains('Unsupported parameter type'),
              ),
        ),
      );
    });

    test('Map throws ArgumentError', () {
      expect(
        () => paramValuesFromObjects([{'key': 'value'}]),
        throwsA(
          isA<ArgumentError>()
              .having(
                (e) => e.message,
                'message',
                contains('Unsupported parameter type'),
              ),
        ),
      );
    });
  });

  group('Fast path for pre-typed List<ParamValue>', () {
    test('fast path: all ParamValue items', () {
      final input = [
        const ParamValueInt32(1),
        const ParamValueString('hello'),
        const ParamValueNull(),
      ];
      final params = paramValuesFromObjects(input);
      expect(params, equals(input));
      expect(identical(params, input), isFalse);
    });

    test('fast path: mix of ParamValue and null', () {
      final input = [
        const ParamValueInt32(1),
        null,
        const ParamValueString('hello'),
      ];
      final params = paramValuesFromObjects(input);
      expect(params[0], equals(input[0]));
      expect(params[1], isA<ParamValueNull>());
      expect(params[2], equals(input[2]));
    });

    test('normal path: mixed types require conversion', () {
      final input = [1, 'hello', null];
      final params = paramValuesFromObjects(input);
      expect(params[0], isA<ParamValueInt32>());
      expect(params[1], isA<ParamValueString>());
      expect(params[2], isA<ParamValueNull>());
    });
  });

  group('ParamValue serialization', () {
    test('ParamValueNull produces tag 0 and len 0', () {
      final s = const ParamValueNull().serialize();
      expect(s.length, equals(5));
      expect(s[0], equals(0));
      expect(
        ByteData.sublistView(Uint8List.fromList(s)).getUint32(1, Endian.little),
        equals(0),
      );
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
        ByteData.sublistView(Uint8List.fromList(s)).getUint32(1, Endian.little),
        equals(4),
      );
      expect(
        ByteData.sublistView(Uint8List.fromList(s)).getInt32(5, Endian.little),
        equals(42),
      );
    });

    test('ParamValueInt64 produces tag 3, len 8, i64 LE', () {
      // Test value requires large integer literal for i64 validation.
      // ignore: avoid_js_rounded_ints
      final s = const ParamValueInt64(0x123456789abcdef0).serialize();
      expect(s[0], equals(3));
      expect(
        ByteData.sublistView(Uint8List.fromList(s)).getUint32(1, Endian.little),
        equals(8),
      );
      expect(
        ByteData.sublistView(Uint8List.fromList(s)).getInt64(5, Endian.little),
        // Test value requires large integer literal for i64 validation.
        // ignore: avoid_js_rounded_ints
        equals(0x123456789abcdef0),
      );
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
        ByteData.sublistView(Uint8List.fromList(s)).getUint32(1, Endian.little),
        equals(3),
      );
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
      const second = 5;
      expect(buf[second], equals(2));
    });
  });
}

/// Helper class for testing unsupported type behavior.
class _CustomObject {
  @override
  String toString() => 'CustomObject';
}
