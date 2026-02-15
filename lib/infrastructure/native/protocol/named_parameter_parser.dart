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

  static final RegExp _namedParamPattern = RegExp(r'[@:](\w+)');

  /// Extracts named parameters and returns SQL with positional placeholders.
  ///
  /// `paramNames` is the ordered list of unique parameter names found.
  static ({String cleanedSql, List<String> paramNames}) extract(String sql) {
    final matches = _namedParamPattern.allMatches(sql);
    final seen = <String>{};
    final paramNames = <String>[];

    for (final match in matches) {
      final name = match.group(1)!;
      if (!seen.contains(name)) {
        seen.add(name);
        paramNames.add(name);
      }
    }

    final cleanedSql = sql.replaceAllMapped(_namedParamPattern, (_) => '?');

    return (cleanedSql: cleanedSql, paramNames: paramNames);
  }

  /// Converts [namedParams] to positional list following [paramNames] order.
  ///
  /// Throws [ParameterMissingException] when a required parameter is missing.
  static List<Object?> toPositionalParams({
    required Map<String, Object?> namedParams,
    required List<String> paramNames,
  }) {
    final missing = paramNames
        .where((String name) => !namedParams.containsKey(name))
        .toList();

    if (missing.isNotEmpty) {
      throw ParameterMissingException(
        'Missing required parameters: ${missing.join(", ")}',
      );
    }

    return paramNames.map((String name) => namedParams[name]).toList();
  }
}

/// Thrown when named parameters are provided incomplete.
class ParameterMissingException implements Exception {
  const ParameterMissingException(this.message);

  final String message;

  @override
  String toString() => message;
}
