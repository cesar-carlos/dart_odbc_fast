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

  /// Extracts named parameters and returns SQL with positional placeholders.
  ///
  /// `paramNames` preserves placeholder occurrence order, including repeats.
  static ({String cleanedSql, List<String> paramNames}) extract(String sql) {
    final paramNames = <String>[];
    final cleanedSql = StringBuffer();
    var index = 0;

    while (index < sql.length) {
      final char = sql[index];

      if (char == "'" || char == '"' || char == '[' || char == '`') {
        final end = _consumeQuotedSegment(sql, start: index, delimiter: char);
        cleanedSql.write(sql.substring(index, end));
        index = end;
        continue;
      }

      final dollarQuotedEnd = _consumeDollarQuotedSegment(sql, start: index);
      if (dollarQuotedEnd != null) {
        cleanedSql.write(sql.substring(index, dollarQuotedEnd));
        index = dollarQuotedEnd;
        continue;
      }

      if (char == '-' && _peek(sql, index + 1) == '-') {
        final end = _consumeLineComment(sql, start: index);
        cleanedSql.write(sql.substring(index, end));
        index = end;
        continue;
      }

      if (char == '/' && _peek(sql, index + 1) == '*') {
        final end = _consumeBlockComment(sql, start: index);
        cleanedSql.write(sql.substring(index, end));
        index = end;
        continue;
      }

      final placeholderName = _tryReadPlaceholder(sql, index);
      if (placeholderName != null) {
        paramNames.add(placeholderName.name);
        cleanedSql.write('?');
        index = placeholderName.end;
        continue;
      }

      cleanedSql.write(char);
      index++;
    }

    return (cleanedSql: cleanedSql.toString(), paramNames: paramNames);
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

    return paramNames.map((name) => namedParams[name]).toList();
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
      if ((delimiter == "'" || delimiter == '"') &&
          _peek(sql, index + 1) == closingDelimiter) {
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
