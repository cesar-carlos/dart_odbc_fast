class QueryResult {
  final List<String> columns;
  final List<List<dynamic>> rows;
  final int rowCount;

  const QueryResult({
    required this.columns,
    required this.rows,
    required this.rowCount,
  });

  bool get isEmpty => rowCount == 0;
  bool get isNotEmpty => rowCount > 0;
}
