import 'package:odbc_fast/infrastructure/native/protocol/odbc_type.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcType.fromDiscriminant', () {
    test('round-trips every variant', () {
      for (final t in OdbcType.values) {
        expect(OdbcType.fromDiscriminant(t.discriminant), t);
      }
    });

    test('unknown discriminant degrades to varchar', () {
      expect(OdbcType.fromDiscriminant(0), OdbcType.varchar);
      expect(OdbcType.fromDiscriminant(99), OdbcType.varchar);
      expect(OdbcType.fromDiscriminant(-1), OdbcType.varchar);
    });

    test('discriminants match Rust enum values', () {
      // Spot-check against Rust `OdbcType` repr.
      expect(OdbcType.varchar.discriminant, 1);
      expect(OdbcType.integer.discriminant, 2);
      expect(OdbcType.bigInt.discriminant, 3);
      expect(OdbcType.binary.discriminant, 7);
      expect(OdbcType.nVarchar.discriminant, 8);
      expect(OdbcType.json.discriminant, 16);
      expect(OdbcType.uuid.discriminant, 17);
      expect(OdbcType.interval.discriminant, 19);
    });
  });

  group('OdbcType wire-format predicates', () {
    test('binary is recognised as binary wire', () {
      expect(OdbcType.binary.isBinaryWire, isTrue);
      expect(OdbcType.binary.isIntegerWire, isFalse);
      expect(OdbcType.binary.isTextWire, isFalse);
    });

    test('integer and bigInt are integer wire', () {
      expect(OdbcType.integer.isIntegerWire, isTrue);
      expect(OdbcType.bigInt.isIntegerWire, isTrue);
      expect(OdbcType.integer.isTextWire, isFalse);
    });

    test('all other variants are text wire', () {
      const textVariants = <OdbcType>{
        OdbcType.varchar,
        OdbcType.decimal,
        OdbcType.date,
        OdbcType.timestamp,
        OdbcType.nVarchar,
        OdbcType.timestampWithTz,
        OdbcType.datetimeOffset,
        OdbcType.time,
        OdbcType.smallInt,
        OdbcType.boolean,
        OdbcType.float,
        OdbcType.doublePrecision,
        OdbcType.json,
        OdbcType.uuid,
        OdbcType.money,
        OdbcType.interval,
      };
      for (final t in textVariants) {
        expect(t.isTextWire, isTrue, reason: '${t.name} should be text wire');
        expect(t.isBinaryWire, isFalse);
        expect(t.isIntegerWire, isFalse);
      }
    });
  });
}
