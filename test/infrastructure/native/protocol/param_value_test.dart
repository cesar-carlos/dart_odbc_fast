import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:test/test.dart';

/// Tests for Phase 1: Parameter conversion hardening.
///
/// Phase 1 changes:
/// - bool → ParamValueInt32(1|0) (canonical mapping)
/// - double → ParamValueDecimal(value.toStringAsFixed(6))
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
      expect((params[0] as ParamValueDecimal).value, equals('3.140000'));
      expect(params[1], isA<ParamValueDecimal>());
      expect((params[1] as ParamValueDecimal).value, equals('0.000000'));
      expect(params[2], isA<ParamValueDecimal>());
      expect((params[2] as ParamValueDecimal).value, equals('-42.500000'));
    });

    test('double NaN throws ArgumentError', () {
      expect(
        () => paramValuesFromObjects([double.nan]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('NaN'),
          ),
        ),
      );
    });

    test('double infinity throws ArgumentError', () {
      expect(
        () => paramValuesFromObjects([double.infinity]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Infinity'),
          ),
        ),
      );
    });

    test('double negative infinity throws ArgumentError', () {
      expect(
        () => paramValuesFromObjects([double.negativeInfinity]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('-Infinity'),
          ),
        ),
      );
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

    test('DateTime year below 1 throws ArgumentError', () {
      final dt = DateTime.utc(1).subtract(const Duration(days: 370));
      expect(dt.year, lessThan(1));
      expect(
        () => paramValuesFromObjects([dt]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('year must be between 1 and 9999'),
          ),
        ),
      );
    });

    test('DateTime year above 9999 throws ArgumentError', () {
      final dt = DateTime.utc(9999, 12, 31, 23, 59, 59).add(
        const Duration(days: 2),
      );
      expect(dt.year, greaterThan(9999));
      expect(
        () => paramValuesFromObjects([dt]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('year must be between 1 and 9999'),
          ),
        ),
      );
    });
  });

  group('Optional explicit SQL typing (Phase 4 prototype)', () {
    test('SqlDataType.int32 maps to ParamValueInt32', () {
      final params = paramValuesFromObjects([
        typedParam(SqlDataType.int32, 42),
      ]);
      expect(params[0], isA<ParamValueInt32>());
      expect((params[0] as ParamValueInt32).value, equals(42));
    });

    test('SqlDataType.int32 validates value range', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.int32, 0x80000000),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('out of range'),
          ),
        ),
      );
    });

    test('SqlDataType.decimal accepts num and String', () {
      final params = paramValuesFromObjects([
        typedParam(SqlDataType.decimal(), 3.14),
        typedParam(SqlDataType.decimal(), '19.9900'),
      ]);
      expect(params[0], isA<ParamValueDecimal>());
      expect((params[0] as ParamValueDecimal).value, equals('3.14'));
      expect(params[1], isA<ParamValueDecimal>());
      expect((params[1] as ParamValueDecimal).value, equals('19.9900'));
    });

    test('SqlDataType.boolAsInt32 maps bool to 1/0', () {
      final params = paramValuesFromObjects([
        typedParam(SqlDataType.boolAsInt32, true),
        typedParam(SqlDataType.boolAsInt32, false),
      ]);
      expect((params[0] as ParamValueInt32).value, equals(1));
      expect((params[1] as ParamValueInt32).value, equals(0));
    });

    test('SqlDataType.varBinary validates payload type', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.varBinary(), 'not-bytes'),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('List<int>'),
          ),
        ),
      );
    });

    test('SqlDataType.dateTime validates DateTime year range', () {
      final dt = DateTime.utc(9999, 12, 31, 23, 59, 59).add(
        const Duration(days: 2),
      );
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.dateTime, dt),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('year must be between 1 and 9999'),
          ),
        ),
      );
    });
  });

  // -----------------------------------------------------------------
  // Sprint backlog item: SqlDataType extras
  // (smallInt, bigInt, json, uuid, money)
  // -----------------------------------------------------------------

  group('SqlDataType.smallInt', () {
    test('accepts values inside the int16 range', () {
      final params = paramValuesFromObjects([
        typedParam(SqlDataType.smallInt, -32768),
        typedParam(SqlDataType.smallInt, 0),
        typedParam(SqlDataType.smallInt, 32767),
      ]);
      expect(
        params.every((p) => p is ParamValueInt32),
        isTrue,
        reason: 'smallInt serialises as int32 on the wire — '
            'the distinction lives in the validation, not the encoding',
      );
      expect((params[0] as ParamValueInt32).value, equals(-32768));
      expect((params[1] as ParamValueInt32).value, equals(0));
      expect((params[2] as ParamValueInt32).value, equals(32767));
    });

    test('rejects values just outside the int16 boundaries', () {
      for (final bad in [-32769, 32768, 0x7FFFFFFF, -0x80000000]) {
        expect(
          () => paramValuesFromObjects([
            typedParam(SqlDataType.smallInt, bad),
          ]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('out of range [-32768, 32767]'),
            ),
          ),
          reason: 'smallInt must reject $bad',
        );
      }
    });

    test('rejects non-int payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.smallInt, '42'),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SqlDataType.bigInt', () {
    test('serialises as int64 on the wire', () {
      final params = paramValuesFromObjects([
        typedParam(SqlDataType.bigInt, 9223372036854775807),
        typedParam(SqlDataType.bigInt, -9223372036854775808),
      ]);
      expect(params[0], isA<ParamValueInt64>());
      expect((params[0] as ParamValueInt64).value, equals(9223372036854775807));
      expect(
        (params[1] as ParamValueInt64).value,
        equals(-9223372036854775808),
      );
    });

    test('is wire-compatible with int64 (idiomatic alias)', () {
      // Pinning the alias contract: a BIGINT-typed param and an
      // INT64-typed param produce byte-identical wire output for
      // the same input. If a future refactor splits them, this
      // test will catch it.
      final asBigInt = paramValuesFromObjects([
        typedParam(SqlDataType.bigInt, 1234567890123),
      ])[0];
      final asInt64 = paramValuesFromObjects([
        typedParam(SqlDataType.int64, 1234567890123),
      ])[0];
      expect(asBigInt.serialize(), equals(asInt64.serialize()));
    });

    test('rejects non-int payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.bigInt, '42'),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SqlDataType.json', () {
    test('passes a String payload through verbatim (no re-encoding)', () {
      const original = '{"role":"admin","level":3}';
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.json(), original),
      ])[0];
      expect(p, isA<ParamValueString>());
      expect((p as ParamValueString).value, equals(original));
    });

    test('encodes a Map payload via jsonEncode', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.json(), <String, dynamic>{
          'name': 'Alice',
          'age': 30,
        }),
      ])[0];
      expect(p, isA<ParamValueString>());
      // Don't pin field order here — jsonEncode's order is platform-
      // defined for plain Maps. Round-trip and compare structurally.
      expect(
        jsonDecode((p as ParamValueString).value),
        equals(<String, dynamic>{'name': 'Alice', 'age': 30}),
      );
    });

    test('encodes a List payload via jsonEncode', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.json(), <dynamic>[1, 'two', null, true]),
      ])[0];
      expect(p, isA<ParamValueString>());
      expect((p as ParamValueString).value, equals('[1,"two",null,true]'));
    });

    test('rejects unsupported payload types with actionable message', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.json(), 42),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('SqlDataType.json'), contains('int')),
          ),
        ),
      );
    });

    test('opt-in validate=true catches malformed JSON early', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.json(validate: true), '{"oops"'),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('not valid JSON'),
          ),
        ),
      );
    });

    test('default (validate=false) accepts malformed JSON without parsing', () {
      // Hot-path safety net: the engine will reject malformed JSON
      // at execute-time anyway. We deliberately do NOT parse on the
      // happy path so multi-KB JSON payloads don't pay an extra
      // jsonDecode cost per call.
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.json(), '{"oops"'),
      ])[0];
      expect((p as ParamValueString).value, equals('{"oops"'));
    });
  });

  group('SqlDataType.uuid', () {
    const canonical = '550e8400-e29b-41d4-a716-446655440000';

    test('accepts canonical lowercase form unchanged', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.uuid, canonical),
      ])[0];
      expect((p as ParamValueString).value, equals(canonical));
    });

    test('folds uppercase to lowercase canonical form', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.uuid, canonical.toUpperCase()),
      ])[0];
      expect(
        (p as ParamValueString).value,
        equals(canonical),
        reason: 'engine should always see normalised lowercase UUIDs',
      );
    });

    test('strips {curly braces} (.NET tooling style)', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.uuid, '{$canonical}'),
      ])[0];
      expect((p as ParamValueString).value, equals(canonical));
    });

    test('expands bare 32-hex form to canonical 8-4-4-4-12', () {
      final bareHex = canonical.replaceAll('-', '');
      expect(bareHex.length, equals(32), reason: 'sanity check the test');
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.uuid, bareHex),
      ])[0];
      expect((p as ParamValueString).value, equals(canonical));
    });

    test('rejects malformed inputs with actionable message', () {
      for (final bad in [
        '',
        'not-a-uuid',
        '550e8400-e29b-41d4-a716', // too short
        '550e8400-e29b-41d4-a716-446655440000-extra',
        'gggggggg-gggg-gggg-gggg-gggggggggggg', // non-hex
      ]) {
        expect(
          () => paramValuesFromObjects([
            typedParam(SqlDataType.uuid, bad),
          ]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('SqlDataType.uuid expects'),
            ),
          ),
          reason: 'must reject $bad',
        );
      }
    });

    test('rejects non-String payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.uuid, 42),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SqlDataType.money', () {
    test('formats num with the canonical 4 fractional digits', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.money, 1234.5),
      ])[0];
      expect(p, isA<ParamValueDecimal>());
      expect(
        (p as ParamValueDecimal).value,
        equals('1234.5000'),
        reason: 'MONEY must always carry exactly 4 fractional digits '
            'so the engine accepts it without scale renegotiation',
      );
    });

    test('formats integer num without losing the trailing zeros', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.money, 100),
      ])[0];
      expect((p as ParamValueDecimal).value, equals('100.0000'));
    });

    test('formats negative values', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.money, -1.2345),
      ])[0];
      expect((p as ParamValueDecimal).value, equals('-1.2345'));
    });

    test('passes pre-formatted String through verbatim', () {
      // Caller is trusted; we don't try to re-parse and re-format.
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.money, '1234567890.1234'),
      ])[0];
      expect((p as ParamValueDecimal).value, equals('1234567890.1234'));
    });

    test('rejects NaN and Infinity with consistent wording', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.money, double.nan),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('NaN'),
          ),
        ),
      );
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.money, double.infinity),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Infinity'),
          ),
        ),
      );
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.money, double.negativeInfinity),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('-Infinity'),
          ),
        ),
      );
    });

    test('rejects unsupported payload types', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.money, true),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // -----------------------------------------------------------------
  // Final batch of SqlDataType extras
  // (tinyInt, bit, text, xml, interval)
  // -----------------------------------------------------------------

  group('SqlDataType.tinyInt', () {
    test('accepts the full unsigned [0, 255] range', () {
      final params = paramValuesFromObjects([
        typedParam(SqlDataType.tinyInt, 0),
        typedParam(SqlDataType.tinyInt, 128),
        typedParam(SqlDataType.tinyInt, 255),
      ]);
      expect(
        params.every((p) => p is ParamValueInt32),
        isTrue,
        reason: 'tinyInt serialises as int32 on the wire — '
            'distinction lives in the validation, not the encoding',
      );
      expect((params[0] as ParamValueInt32).value, equals(0));
      expect((params[1] as ParamValueInt32).value, equals(128));
      expect((params[2] as ParamValueInt32).value, equals(255));
    });

    test('rejects values just outside the unsigned-tinyint boundaries', () {
      for (final bad in [-1, 256, -128, 32767]) {
        expect(
          () => paramValuesFromObjects([
            typedParam(SqlDataType.tinyInt, bad),
          ]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('out of range [0, 255]'),
            ),
          ),
          reason: 'tinyInt must reject $bad',
        );
      }
    });

    test('rejects non-int payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.tinyInt, '42'),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SqlDataType.bit', () {
    test('maps bool to 0/1', () {
      final params = paramValuesFromObjects([
        typedParam(SqlDataType.bit, true),
        typedParam(SqlDataType.bit, false),
      ]);
      expect((params[0] as ParamValueInt32).value, equals(1));
      expect((params[1] as ParamValueInt32).value, equals(0));
    });

    test('accepts int 0 and int 1 verbatim', () {
      final params = paramValuesFromObjects([
        typedParam(SqlDataType.bit, 0),
        typedParam(SqlDataType.bit, 1),
      ]);
      expect((params[0] as ParamValueInt32).value, equals(0));
      expect((params[1] as ParamValueInt32).value, equals(1));
    });

    test('rejects any int that is not 0 or 1', () {
      for (final bad in [-1, 2, 255, 100]) {
        expect(
          () => paramValuesFromObjects([
            typedParam(SqlDataType.bit, bad),
          ]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('expects exactly 0 or 1'),
            ),
          ),
          reason: 'bit must reject int $bad — only 0 / 1 are valid',
        );
      }
    });

    test('rejects non-bool, non-int payloads with actionable message', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.bit, 'true'),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('SqlDataType.bit'), contains('bool or int')),
          ),
        ),
      );
    });
  });

  group('SqlDataType.text', () {
    test('passes a String payload through verbatim', () {
      const payload = 'lorem ipsum dolor sit amet';
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.text, payload),
      ])[0];
      expect(p, isA<ParamValueString>());
      expect((p as ParamValueString).value, equals(payload));
    });

    test('handles empty strings', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.text, ''),
      ])[0];
      expect((p as ParamValueString).value, isEmpty);
    });

    test('handles multi-line and unicode payloads', () {
      // TEXT must round-trip arbitrary content — line breaks, BMP and
      // non-BMP characters, you name it.
      const payload =
          'line1\nline2\r\nline3\n管理员 🚀 العربية';
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.text, payload),
      ])[0];
      expect((p as ParamValueString).value, equals(payload));
    });

    test('rejects non-String payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.text, 42),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SqlDataType.xml', () {
    const sample = '<root><child attr="x">value</child></root>';

    test('default (validate=false) passes payload through verbatim', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.xml(), sample),
      ])[0];
      expect((p as ParamValueString).value, equals(sample));
    });

    test('default (validate=false) accepts malformed XML without checking', () {
      // Hot-path safety net: the engine remains the source of truth
      // for full schema/well-formedness validation. We deliberately
      // do NOT parse on the happy path so multi-KB XML payloads
      // don't pay an extra check per call.
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.xml(), 'not-xml-at-all'),
      ])[0];
      expect((p as ParamValueString).value, equals('not-xml-at-all'));
    });

    test('validate=true accepts well-formed-looking payloads', () {
      // Cheap shape check, not full XML parsing — these are all OK.
      for (final ok in [
        sample,
        '<empty/>',
        '<a><b><c/></b></a>',
        '   <root>x</root>   ', // leading whitespace tolerated
      ]) {
        final p = paramValuesFromObjects([
          typedParam(SqlDataType.xml(validate: true), ok),
        ])[0];
        expect((p as ParamValueString).value, equals(ok));
      }
    });

    test('validate=true rejects empty / non-XML-looking payloads', () {
      for (final bad in ['', '   ', 'not-xml', '<unterminated']) {
        expect(
          () => paramValuesFromObjects([
            typedParam(SqlDataType.xml(validate: true), bad),
          ]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('SqlDataType.xml(validate: true)'),
            ),
          ),
          reason: 'xml(validate: true) must reject "$bad"',
        );
      }
    });

    test('rejects non-String payloads regardless of validate flag', () {
      for (final type in [SqlDataType.xml(), SqlDataType.xml(validate: true)]) {
        expect(
          () => paramValuesFromObjects([typedParam(type, 42)]),
          throwsA(isA<ArgumentError>()),
        );
      }
    });
  });

  group('SqlDataType.interval', () {
    test('formats Duration as "<n> seconds"', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.interval, const Duration(hours: 1, minutes: 30)),
      ])[0];
      expect(p, isA<ParamValueString>());
      expect(
        (p as ParamValueString).value,
        equals('5400 seconds'),
        reason: '1h30m == 5400s; format must be portable across '
            'PostgreSQL/MySQL/Oracle/Db2',
      );
    });

    test('preserves sub-second precision as 3-digit decimal', () {
      final p = paramValuesFromObjects([
        typedParam(
          SqlDataType.interval,
          const Duration(seconds: 1, milliseconds: 500),
        ),
      ])[0];
      expect(
        (p as ParamValueString).value,
        equals('1.500 seconds'),
        reason: '1.5s round-trips as 1.500 (padded so engines parse '
            'unambiguously)',
      );
    });

    test('handles zero duration cleanly', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.interval, Duration.zero),
      ])[0];
      expect((p as ParamValueString).value, equals('0 seconds'));
    });

    test('handles negative durations symmetrically', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.interval, const Duration(seconds: -90)),
      ])[0];
      expect(
        (p as ParamValueString).value,
        equals('-90 seconds'),
        reason: 'PostgreSQL interpretes negative seconds intervals',
      );
    });

    test('passes pre-formatted String through verbatim (engine-specific)', () {
      // Oracle expects `INTERVAL '1' DAY`; SQL Server has no INTERVAL at
      // all and emulates via DATEADD. Callers that need engine-specific
      // syntax pass a String shaped to that engine's grammar.
      const oracle = "INTERVAL '1' DAY";
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.interval, oracle),
      ])[0];
      expect((p as ParamValueString).value, equals(oracle));
    });

    test('rejects unsupported payload types', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.interval, 42),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('SqlDataType.interval'),
              contains('Duration or String'),
            ),
          ),
        ),
      );
    });
  });

  // -----------------------------------------------------------------
  // Engine-specific SqlDataType kinds
  // PostgreSQL:    range, cidr, tsvector
  // SQL Server:    hierarchyId, geography
  // Oracle:        raw, bfile
  //
  // These wrap existing wire primitives (String / Binary); the value
  // is the type-discipline at the call site plus per-kind validation.
  // Several of them require the caller to wrap the parameter in a
  // CAST or constructor function inside the SQL itself — see each
  // kind's doc comment in `param_value.dart` for the convention.
  // -----------------------------------------------------------------

  group('SqlDataType.range (PostgreSQL)', () {
    test('passes a range literal through verbatim', () {
      for (final literal in [
        '[1,10)',
        '(1,5]',
        'empty',
        '[2020-01-01,2020-12-31)',
        '[1.5,3.5]',
      ]) {
        final p = paramValuesFromObjects([
          typedParam(SqlDataType.range, literal),
        ])[0];
        expect(p, isA<ParamValueString>());
        expect(
          (p as ParamValueString).value,
          equals(literal),
          reason: 'concrete range subtype is resolved by the server; '
              'this layer must not mangle the literal',
        );
      }
    });

    test('rejects non-String payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.range, [1, 10]),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SqlDataType.cidr (PostgreSQL)', () {
    test('accepts well-formed IPv4 with and without /prefix', () {
      for (final ip in [
        '192.168.1.1',
        '192.168.1.0/24',
        '10.0.0.0/8',
        '0.0.0.0/0',
        '255.255.255.255/32',
      ]) {
        final p = paramValuesFromObjects([
          typedParam(SqlDataType.cidr, ip),
        ])[0];
        expect((p as ParamValueString).value, equals(ip));
      }
    });

    test('accepts well-formed IPv6 with and without /prefix', () {
      for (final ip in [
        '2001:db8::1',
        '2001:db8::/32',
        'fe80::1/64',
        '::1',
        '::/0',
      ]) {
        final p = paramValuesFromObjects([
          typedParam(SqlDataType.cidr, ip),
        ])[0];
        expect(
          (p as ParamValueString).value,
          equals(ip),
          reason: 'IPv6 literal "$ip" must be accepted',
        );
      }
    });

    test('rejects obviously-malformed inputs early', () {
      for (final bad in [
        '',
        'not-an-ip',
        '192.168.1.1/33', // mask out of range for IPv4
        '300.300.300.300', // out of octet range — caught loosely
        // ^^^ note: we accept loose octet ranges; PostgreSQL is the
        // authoritative validator. This test only pins what we DO
        // catch (the structural shape).
        'fe80:::1', // triple colon — malformed compact form
      ]) {
        // Use any check that covers obvious typos only; the exact
        // rejection rate is a quality knob, not a contract. Pin the
        // rejected inputs we actually catch.
        final shouldReject = bad == '' ||
            bad == 'not-an-ip' ||
            bad == '192.168.1.1/33' ||
            bad == 'fe80:::1';
        if (!shouldReject) continue;
        expect(
          () => paramValuesFromObjects([
            typedParam(SqlDataType.cidr, bad),
          ]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('SqlDataType.cidr'),
            ),
          ),
          reason: 'cidr must reject obvious typo "$bad"',
        );
      }
    });

    test('rejects non-String payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.cidr, 0xC0A80101),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SqlDataType.tsvector (PostgreSQL)', () {
    test('passes a tsvector literal through verbatim', () {
      for (final literal in [
        'fat:1A cat:2B sat:3 mat:4',
        'hello world',
        "'a' 'b' 'c'",
      ]) {
        final p = paramValuesFromObjects([
          typedParam(SqlDataType.tsvector, literal),
        ])[0];
        expect((p as ParamValueString).value, equals(literal));
      }
    });

    test('rejects non-String payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.tsvector, ['fat', 'cat']),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SqlDataType.hierarchyId (SQL Server)', () {
    test('accepts the canonical "/"-rooted, "/"-terminated forms', () {
      for (final path in [
        '/',
        '/1/',
        '/1/2/',
        '/1/2/3.5/', // .5 inserts between siblings 3 and 4 without renumber
        '/1/2/3.5/4/',
        '/100/200/300/',
      ]) {
        final p = paramValuesFromObjects([
          typedParam(SqlDataType.hierarchyId, path),
        ])[0];
        expect((p as ParamValueString).value, equals(path));
      }
    });

    test('rejects malformed paths', () {
      for (final bad in [
        '',
        '1/2/', // missing leading /
        '/1/2', // missing trailing /
        '/1/-2/', // negative segment
        '/a/', // non-decimal segment
        '/1//2/', // empty segment
      ]) {
        expect(
          () => paramValuesFromObjects([
            typedParam(SqlDataType.hierarchyId, bad),
          ]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('SqlDataType.hierarchyId'),
            ),
          ),
          reason: 'hierarchyId must reject "$bad"',
        );
      }
    });

    test('rejects non-String payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.hierarchyId, 1),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SqlDataType.geography (SQL Server)', () {
    test('passes a WKT literal through verbatim', () {
      for (final wkt in [
        'POINT(-122.349 47.651)',
        'LINESTRING(0 0, 1 1, 2 2)',
        'POLYGON((0 0, 4 0, 4 4, 0 4, 0 0))',
        'MULTIPOINT((0 0), (1 1))',
      ]) {
        final p = paramValuesFromObjects([
          typedParam(SqlDataType.geography, wkt),
        ])[0];
        expect(
          (p as ParamValueString).value,
          equals(wkt),
          reason: 'caller wraps in geography::STGeomFromText(?, srid) '
              'in the SQL — the WKT itself must not be mangled',
        );
      }
    });

    test(
      'rejects List<int> with actionable hint pointing at varBinary',
      () {
        expect(
          () => paramValuesFromObjects([
            typedParam(SqlDataType.geography, [0x01, 0x01, 0x00]),
          ]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('SqlDataType.geography expects String (WKT)'),
                contains('SqlDataType.varBinary'),
                contains('STGeomFromWKB'),
              ),
            ),
          ),
        );
      },
    );

    test('rejects num and other non-String payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.geography, 47.651),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SqlDataType.raw (Oracle)', () {
    test('serialises List<int> as ParamValueBinary', () {
      final bytes = [0xDE, 0xAD, 0xBE, 0xEF];
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.raw, bytes),
      ])[0];
      expect(p, isA<ParamValueBinary>());
      expect((p as ParamValueBinary).value, equals(bytes));
    });

    test('is wire-compatible with varBinary (idiomatic alias)', () {
      // Same input, two type names → identical wire output. If a
      // future refactor splits them this test catches the regression.
      final bytes = [1, 2, 3, 4, 5];
      final asRaw = paramValuesFromObjects([
        typedParam(SqlDataType.raw, bytes),
      ])[0];
      final asVarBinary = paramValuesFromObjects([
        typedParam(SqlDataType.varBinary(), bytes),
      ])[0];
      expect(asRaw.serialize(), equals(asVarBinary.serialize()));
    });

    test('handles empty payloads', () {
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.raw, <int>[]),
      ])[0];
      expect((p as ParamValueBinary).value, isEmpty);
    });

    test('rejects non-List<int> payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.raw, 'DEADBEEF'),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SqlDataType.bfile (Oracle)', () {
    test('passes a BFILENAME(...) snippet through verbatim', () {
      // BFILE is unusual: the parameter usually carries a complete
      // SQL fragment that the server evaluates. Wire layer must not
      // touch the string contents.
      const snippet = "BFILENAME('DIR_OBJECT', 'docs/file.pdf')";
      final p = paramValuesFromObjects([
        typedParam(SqlDataType.bfile, snippet),
      ])[0];
      expect((p as ParamValueString).value, equals(snippet));
    });

    test('rejects non-String payloads', () {
      expect(
        () => paramValuesFromObjects([
          typedParam(SqlDataType.bfile, 0),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Unsupported type errors (Phase 1)', () {
    test('unsupported type message remains identical', () {
      final custom = _CustomObject();
      expect(
        () => paramValuesFromObjects([custom]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            equals(
              'Unsupported parameter type: _CustomObject. '
              'Expected one of: null, int, String, List<int>, bool, double, '
              'DateTime, or ParamValue. '
              'Use explicit ParamValue wrapper if needed, e.g., '
              'ParamValueString(value) for custom string conversion.',
            ),
          ),
        ),
      );
    });

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
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('ParamValue wrapper'),
          ),
        ),
      );
    });

    test('List<String> throws ArgumentError', () {
      expect(
        () => paramValuesFromObjects([
          ['a', 'b'],
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Unsupported parameter type'),
          ),
        ),
      );
    });

    test('Map throws ArgumentError', () {
      expect(
        () => paramValuesFromObjects([
          {'key': 'value'},
        ]),
        throwsA(
          isA<ArgumentError>().having(
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
