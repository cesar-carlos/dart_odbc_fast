import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart';
import 'package:test/test.dart';

void main() {
  group('NamedParameterParser.extract', () {
    test('should return SQL with ? placeholders and param names in order', () {
      const sql = 'SELECT * FROM t WHERE id = @id AND name = :name';
      final result = NamedParameterParser.extract(sql);

      expect(
        result.cleanedSql,
        equals('SELECT * FROM t WHERE id = ? AND name = ?'),
      );
      expect(result.paramNames, orderedEquals(['id', 'name']));
    });

    test('should dedupe multiple occurrences of same named param', () {
      const sql = 'SELECT * FROM t WHERE id = @id OR parent_id = @id';
      final result = NamedParameterParser.extract(sql);

      expect(
        result.cleanedSql,
        equals('SELECT * FROM t WHERE id = ? OR parent_id = ?'),
      );
      expect(result.paramNames, orderedEquals(['id']));
    });

    test('should handle @ prefix only', () {
      const sql = 'INSERT INTO t VALUES (@a)';
      final result = NamedParameterParser.extract(sql);

      expect(result.cleanedSql, equals('INSERT INTO t VALUES (?)'));
      expect(result.paramNames, orderedEquals(['a']));
    });

    test('should handle : prefix only', () {
      const sql = 'INSERT INTO t VALUES (:b)';
      final result = NamedParameterParser.extract(sql);

      expect(result.cleanedSql, equals('INSERT INTO t VALUES (?)'));
      expect(result.paramNames, orderedEquals(['b']));
    });

    test('should return empty paramNames when no named params', () {
      const sql = 'SELECT 1';
      final result = NamedParameterParser.extract(sql);

      expect(result.cleanedSql, equals('SELECT 1'));
      expect(result.paramNames, isEmpty);
    });
  });

  group('NamedParameterParser.toPositionalParams', () {
    test('should convert Map to List in param order', () {
      final result = NamedParameterParser.toPositionalParams(
        namedParams: {'id': 1, 'name': 'Alice'},
        paramNames: ['id', 'name'],
      );

      expect(result, orderedEquals([1, 'Alice']));
    });

    test('should throw ParameterMissingException when param missing', () {
      expect(
        () => NamedParameterParser.toPositionalParams(
          namedParams: {'id': 1},
          paramNames: ['id', 'name'],
        ),
        throwsA(isA<ParameterMissingException>()),
      );
    });

    test('should include message with missing param names', () {
      try {
        NamedParameterParser.toPositionalParams(
          namedParams: {},
          paramNames: ['a', 'b'],
        );
        fail('Should have thrown');
      } on ParameterMissingException catch (e) {
        expect(e.message, contains('a'));
        expect(e.message, contains('b'));
      }
    });

    test('should allow extra params in map', () {
      final result = NamedParameterParser.toPositionalParams(
        namedParams: {'a': 1, 'b': 2, 'extra': 99},
        paramNames: ['a', 'b'],
      );

      expect(result, orderedEquals([1, 2]));
    });

    test('should handle null values', () {
      final result = NamedParameterParser.toPositionalParams(
        namedParams: {'a': null, 'b': 'ok'},
        paramNames: ['a', 'b'],
      );

      expect(result, orderedEquals([null, 'ok']));
    });
  });

  group('ParameterMissingException', () {
    test('should provide readable toString', () {
      const e = ParameterMissingException('Missing: x');
      expect(e.toString(), equals('Missing: x'));
    });
  });
}
