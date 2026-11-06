/// Parser and extractor for named parameters in SQL.
///
/// Supports syntaxes: @name, :name
/// Converts to positional parameters with deterministic order.
///
/// Example:
/// ```dart
/// final (cleanedSql, paramNames) = NamedParameterParser.extract(
///   'SELECT * FROM t WHERE id = @id AND name = :name',
/// );
/// // cleanedSql: 'SELECT * FROM t WHERE id = ? AND name = ?'
/// // paramNames: ['id', 'name']
/// ```
class NamedParameterParser {
  NamedParameterParser._();

  static const int _cacheMaxSize = 256;

  // Bounded insertion-order cache: when full, evict the oldest key
  // (keys.first). Keyed by raw SQL; values use unmodifiable param lists so
  // callers cannot corrupt cached state through the returned reference.
  static final Map<String, ({String cleanedSql, List<String> paramNames})>
      _cache = {};

  /// Extracts named parameters and returns SQL with positional placeholders.
  ///
  /// `paramNames` preserves placeholder occurrence order, including repeats.
  ///
  /// Results are memoized by SQL text (up to 256 entries; oldest entry is
  /// evicted when the limit is reached). The returned `paramNames` list is
  /// unmodifiable.
  static ({String cleanedSql, List<String> paramNames}) extract(String sql) {
    final cached = _cache[sql];
    if (cached != null) return cached;
    return _extractUncached(sql);
  }

  static ({String cleanedSql, List<String> paramNames}) _extractUncached(
    String sql,
  ) {
    final paramNames = <String>[];
    final cleanedSql = StringBuffer();
    var index = 0;
    var unchangedStart = 0;

    while (index < sql.length) {
      final codeUnit = sql.codeUnitAt(index);

      if (codeUnit == 0x27 ||
          codeUnit == 0x22 ||
          codeUnit == 0x5B ||
          codeUnit == 0x60) {
        final end =
            _consumeQuotedSegment(sql, start: index, delimiter: sql[index]);
        index = end;
        continue;
      }

      final dollarQuotedEnd = codeUnit == 0x24
          ? _consumeDollarQuotedSegment(sql, start: index)
          : null;
      if (dollarQuotedEnd != null) {
        index = dollarQuotedEnd;
        continue;
      }

      if (codeUnit == 0x2D && _peek(sql, index + 1) == '-') {
        final end = _consumeLineComment(sql, start: index);
        index = end;
        continue;
      }

      if (codeUnit == 0x2F && _peek(sql, index + 1) == '*') {
        final end = _consumeBlockComment(sql, start: index);
        index = end;
        continue;
      }

      final placeholderName = codeUnit == 0x40 || codeUnit == 0x3A
          ? _tryReadPlaceholder(sql, index)
          : null;
      if (placeholderName != null) {
        paramNames.add(placeholderName.name);
        cleanedSql
          ..write(sql.substring(unchangedStart, index))
          ..write('?');
        index = placeholderName.end;
        unchangedStart = index;
        continue;
      }

      index++;
    }

    if (paramNames.isNotEmpty) {
      cleanedSql.write(sql.substring(unchangedStart));
    }
    final result = (
      cleanedSql: paramNames.isEmpty ? sql : cleanedSql.toString(),
      paramNames: List<String>.unmodifiable(paramNames),
    );
    if (_cache.length >= _cacheMaxSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[sql] = result;
    return result;
  }

  /// Converts [namedParams] to positional list following [paramNames] order.
  ///
  /// Throws [ParameterMissingException] when a required parameter is missing.
  static List<Object?> toPositionalParams({
    required Map<String, Object?> namedParams,
    required List<String> paramNames,
  }) {
    final missing = <String>[];
    final missingSet = <String>{};
    for (final name in paramNames) {
      if (!namedParams.containsKey(name) && missingSet.add(name)) {
        missing.add(name);
      }
    }

    if (missing.isNotEmpty) {
      throw ParameterMissingException(
        'Missing required parameters: ${missing.join(", ")}',
      );
    }

    return List<Object?>.generate(
      paramNames.length,
      (i) => namedParams[paramNames[i]],
      growable: false,
    );
  }
}

/// Thrown when named parameters are provided incomplete.
class ParameterMissingException implements Exception {
  const ParameterMissingException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef _PlaceholderMatch = ({String name, int end});

String? _peek(String sql, int index) {
  if (index < 0 || index >= sql.length) {
    return null;
  }
  return sql[index];
}

bool _isIdentifierStartCodeUnit(int codeUnit) =>
    (codeUnit >= 65 && codeUnit <= 90) ||
    (codeUnit >= 97 && codeUnit <= 122) ||
    codeUnit == 95;

bool _isIdentifierPartCodeUnit(int codeUnit) =>
    _isIdentifierStartCodeUnit(codeUnit) || (codeUnit >= 48 && codeUnit <= 57);

_PlaceholderMatch? _tryReadPlaceholder(String sql, int start) {
  final prefix = sql.codeUnitAt(start);
  if (prefix != 0x40 && prefix != 0x3A) {
    return null;
  }

  final previous = start > 0 ? sql.codeUnitAt(start - 1) : null;
  if (previous == 0x40 || previous == 0x3A) {
    return null;
  }

  final nameStart = start + 1;
  if (nameStart >= sql.length) {
    return null;
  }

  final firstCodeUnit = sql.codeUnitAt(nameStart);
  if (!_isIdentifierStartCodeUnit(firstCodeUnit)) {
    return null;
  }

  var end = nameStart + 1;
  while (end < sql.length && _isIdentifierPartCodeUnit(sql.codeUnitAt(end))) {
    end++;
  }

  return (name: sql.substring(nameStart, end), end: end);
}

int _consumeQuotedSegment(
  String sql, {
  required int start,
  required String delimiter,
}) {
  final closingDelimiter = switch (delimiter) {
    '[' => ']',
    _ => delimiter,
  };
  var index = start + 1;

  while (index < sql.length) {
    if (sql[index] == closingDelimiter) {
      if (_peek(sql, index + 1) == closingDelimiter) {
        index += 2;
        continue;
      }

      return index + 1;
    }
    index++;
  }

  return sql.length;
}

int _consumeLineComment(String sql, {required int start}) {
  var index = start + 2;
  while (index < sql.length) {
    if (sql[index] == '\n') {
      return index;
    }
    index++;
  }
  return sql.length;
}

int _consumeBlockComment(String sql, {required int start}) {
  var index = start + 2;
  var depth = 1;
  while (index < sql.length - 1) {
    if (sql[index] == '/' && sql[index + 1] == '*') {
      depth++;
      index += 2;
      continue;
    }
    if (sql[index] == '*' && sql[index + 1] == '/') {
      depth--;
      index += 2;
      if (depth == 0) {
        return index;
      }
      continue;
    }
    index++;
  }
  return sql.length;
}

int? _consumeDollarQuotedSegment(String sql, {required int start}) {
  if (_peek(sql, start) != r'$') {
    return null;
  }

  final delimiterEnd = _readDollarQuoteDelimiterEnd(sql, start);
  if (delimiterEnd == null) {
    return null;
  }

  final delimiter = sql.substring(start, delimiterEnd);
  final closingIndex = sql.indexOf(delimiter, delimiterEnd);
  if (closingIndex == -1) {
    return sql.length;
  }

  return closingIndex + delimiter.length;
}

int? _readDollarQuoteDelimiterEnd(String sql, int start) {
  if (_peek(sql, start) != r'$') {
    return null;
  }

  var index = start + 1;
  if (index < sql.length && sql[index] == r'$') {
    return index + 1;
  }

  if (index >= sql.length ||
      !_isIdentifierStartCodeUnit(sql.codeUnitAt(index))) {
    return null;
  }

  index++;
  while (
      index < sql.length && _isIdentifierPartCodeUnit(sql.codeUnitAt(index))) {
    index++;
  }

  if (index >= sql.length || sql[index] != r'$') {
    return null;
  }

  return index + 1;
}
