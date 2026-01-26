class QueryResult {

  const QueryResult({
    required this.columns,
    required this.rows,
    required this.rowCount,
  });
  final List<String> columns;
  final List<List<dynamic>> rows;
  final int rowCount;

  bool get isEmpty => rowCount == 0;
  bool get isNotEmpty => rowCount > 0;
}
