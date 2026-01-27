/// Metadata for a primary key column.
class PrimaryKeyInfo {
  const PrimaryKeyInfo({
    required this.tableName,
    required this.columnName,
    required this.position,
    required this.constraintName,
  });

  final String tableName;
  final String columnName;
  final int position;
  final String constraintName;
}

/// Metadata for a foreign key reference.
class ForeignKeyInfo {
  const ForeignKeyInfo({
    required this.constraintName,
    required this.fromTable,
    required this.fromColumn,
    required this.toTable,
    required this.toColumn,
    this.onUpdate = '',
    this.onDelete = '',
  });

  final String constraintName;
  final String fromTable;
  final String fromColumn;
  final String toTable;
  final String toColumn;
  final String onUpdate;
  final String onDelete;
}

/// Metadata for an index column.
class IndexInfo {
  const IndexInfo({
    required this.indexName,
    required this.tableName,
    required this.columnName,
    this.isUnique = false,
    this.isPrimaryKey = false,
    this.ordinalPosition,
  });

  final String indexName;
  final String tableName;
  final String columnName;
  final bool isUnique;
  final bool isPrimaryKey;
  final int? ordinalPosition;
}
