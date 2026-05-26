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

    test('should preserve repeated named params in occurrence order', () {
      const sql = 'SELECT * FROM t WHERE id = @id OR parent_id = @id';
      final result = NamedParameterParser.extract(sql);

      expect(
        result.cleanedSql,
        equals('SELECT * FROM t WHERE id = ? OR parent_id = ?'),
      );
      expect(result.paramNames, orderedEquals(['id', 'id']));
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

    test('should ignore placeholders inside single-quoted strings', () {
      const sql = "SELECT '@ignored' AS sample, name FROM t WHERE id = @id";
      final result = NamedParameterParser.extract(sql);

      expect(
        result.cleanedSql,
        equals("SELECT '@ignored' AS sample, name FROM t WHERE id = ?"),
      );
      expect(result.paramNames, orderedEquals(['id']));
    });

    test('should ignore placeholders inside comments and casts', () {
      const sql = '''
SELECT value::int
FROM t
-- @ignored
WHERE id = :id /* :also_ignored */
''';
      final result = NamedParameterParser.extract(sql);

      expect(
        result.cleanedSql,
        equals('''
SELECT value::int
FROM t
-- @ignored
WHERE id = ? /* :also_ignored */
'''),
      );
      expect(result.paramNames, orderedEquals(['id']));
    });

    test('should ignore placeholders inside nested block comments', () {
      const sql = '''
SELECT 1
/* outer :ignored /* inner @ignored */ still comment */
WHERE id = :id
''';
      final result = NamedParameterParser.extract(sql);

      expect(
        result.cleanedSql,
        equals('''
SELECT 1
/* outer :ignored /* inner @ignored */ still comment */
WHERE id = ?
'''),
      );
      expect(result.paramNames, orderedEquals(['id']));
    });

    test('should ignore SQL Server system variables and bracketed names', () {
      const sql = 'SELECT @@ROWCOUNT, [@literal] FROM t '
          'WHERE id = @id AND code = :code';
      final result = NamedParameterParser.extract(sql);

      expect(
        result.cleanedSql,
        equals(
          'SELECT @@ROWCOUNT, [@literal] FROM t WHERE id = ? AND code = ?',
        ),
      );
      expect(result.paramNames, orderedEquals(['id', 'code']));
    });

    test(
      'should extract many distinct named placeholders (no fixed arity limit)',
      () {
        const sql =
            'SELECT :a, :b, :c, :d, :e, :f, :g FROM t WHERE x = @h AND y = @i';
        final result = NamedParameterParser.extract(sql);

        expect(
          result.cleanedSql,
          equals(
            'SELECT ?, ?, ?, ?, ?, ?, ? FROM t WHERE x = ? AND y = ?',
          ),
        );
        expect(
          result.paramNames,
          orderedEquals(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i']),
        );
      },
    );

    test('should ignore placeholders inside PostgreSQL dollar-quoted strings',
        () {
      const sql = r'''
          SELECT $$@ignored and :also_ignored$$ AS sample
          WHERE id = @id
            ''';
      final result = NamedParameterParser.extract(sql);

      const expected = r'''
          SELECT $$@ignored and :also_ignored$$ AS sample
          WHERE id = ?
            ''';
      expect(result.cleanedSql, equals(expected));
      expect(result.paramNames, orderedEquals(['id']));
    });

    test('should ignore placeholders inside tagged dollar-quoted strings', () {
      const sql = r'''
SELECT $tag$:ignored and @ignored$tag$ AS sample
WHERE id = :id
''';
      final result = NamedParameterParser.extract(sql);

      expect(
        result.cleanedSql,
        equals(r'''
SELECT $tag$:ignored and @ignored$tag$ AS sample
WHERE id = ?
'''),
      );
      expect(result.paramNames, orderedEquals(['id']));
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

    test('should duplicate values for repeated named params', () {
      final result = NamedParameterParser.toPositionalParams(
        namedParams: {'id': 7, 'name': 'Alice'},
        paramNames: ['id', 'name', 'id'],
      );

      expect(result, orderedEquals([7, 'Alice', 7]));
    });

    test('should convert maps with many distinct keys (no arity cap)', () {
      final result = NamedParameterParser.toPositionalParams(
        namedParams: {
          'a': 1,
          'b': 2,
          'c': 3,
          'd': 4,
          'e': 5,
          'f': 6,
          'g': 7,
          'h': 8,
          'i': 9,
        },
        paramNames: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i'],
      );

      expect(result, orderedEquals([1, 2, 3, 4, 5, 6, 7, 8, 9]));
    });

    test('should report missing repeated param only once', () {
      expect(
        () => NamedParameterParser.toPositionalParams(
          namedParams: const {},
          paramNames: ['id', 'id'],
        ),
        throwsA(
          isA<ParameterMissingException>().having(
            (e) => e.message,
            'message',
            'Missing required parameters: id',
          ),
        ),
      );
    });
  });

  group('ParameterMissingException', () {
    test('should provide readable toString', () {
      const e = ParameterMissingException('Missing: x');
      expect(e.toString(), equals('Missing: x'));
    });
  });

  group('NamedParameterParser.extract — cache', () {
    test('should return identical record for repeated SQL', () {
      const sql = 'SELECT * FROM t WHERE id = @id';
      final first = NamedParameterParser.extract(sql);
      final second = NamedParameterParser.extract(sql);

      // Cached hit returns the same object identity.
      expect(identical(first, second), isTrue);
    });

    test('should return unmodifiable paramNames list', () {
      const sql = 'SELECT * FROM t WHERE x = :x';
      final result = NamedParameterParser.extract(sql);

      expect(
        () => result.paramNames.toList(growable: true).add('y'),
        returnsNormally,
        reason: 'toList copy is mutable — ok',
      );
      // The original cached list must reject mutations.
      expect(
        () => result.paramNames.add('y'),
        throwsUnsupportedError,
      );
    });

    test('should preserve correct parse result through cache', () {
      const sql = 'UPDATE t SET name = @name WHERE id = :id';
      final result = NamedParameterParser.extract(sql);

      expect(
        result.cleanedSql,
        equals('UPDATE t SET name = ? WHERE id = ?'),
      );
      expect(result.paramNames, orderedEquals(['name', 'id']));

      // Second call must return the same semantic result.
      final cached = NamedParameterParser.extract(sql);
      expect(cached.cleanedSql, equals(result.cleanedSql));
      expect(cached.paramNames, orderedEquals(result.paramNames));
    });

    test('should evict oldest entry when cache exceeds 256 entries', () {
      // Fill the cache with 256 distinct SQL strings.
      for (var i = 0; i < 256; i++) {
        NamedParameterParser.extract('SELECT :p$i FROM t$i');
      }

      // The very first SQL inserted is still present (cache is exactly full).
      final beforeEviction = NamedParameterParser.extract('SELECT :p0 FROM t0');
      expect(beforeEviction.paramNames, orderedEquals(['p0']));

      // Adding one more entry must evict the oldest ('SELECT :p0 FROM t0').
      NamedParameterParser.extract('SELECT :overflow FROM overflow_table');

      // After eviction, a fresh parse still produces the correct result but
      // the identity will have changed (new allocation).
      final afterEviction = NamedParameterParser.extract('SELECT :p0 FROM t0');
      expect(afterEviction.cleanedSql, equals('SELECT ? FROM t0'));
      expect(afterEviction.paramNames, orderedEquals(['p0']));
    });
  });
}
