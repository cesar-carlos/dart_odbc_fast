part of 'bulk_insert_builder.dart';

mixin _BulkInsertRowApi on _BulkInsertBuilderState {
  /// Sets the target table name for the bulk insert.
  ///
  /// The [name] is the table name where rows will be inserted.
  /// Returns this builder for method chaining.
  BulkInsertBuilder table(String name) {
    _table = name;
    return _self;
  }

  /// Adds a column definition to the bulk insert.
  ///
  /// The [name] is the column name.
  /// The [colType] specifies the data type.
  /// The [nullable] flag indicates if the column can contain NULL values.
  /// The [maxLen] specifies the maximum length for variable-length types.
  ///
  /// Returns this builder for method chaining.
  BulkInsertBuilder addColumn(
    String name,
    BulkColumnType colType, {
    bool nullable = false,
    int maxLen = 0,
  }) {
    _ensureRowOrientedApis();
    _columns.add(
      BulkColumnSpec(
        name: name,
        colType: colType,
        nullable: nullable,
        maxLen: maxLen,
      ),
    );
    return _self;
  }

  /// Adds a row of data to the bulk insert.
  ///
  /// The [values] list must contain values in the same order as columns
  /// were added, and must match the column count.
  ///
  /// The builder stores the row list reference directly for performance.
  /// Do not modify [values] after passing it to this method.
  ///
  /// Returns this builder for method chaining.
  /// Throws [StateError] if columns haven't been added yet.
  /// Throws [ArgumentError] if the row length doesn't match column count.
  BulkInsertBuilder addRow(List<dynamic> values) {
    _ensureRowOrientedApis();
    if (_columns.isEmpty) {
      throw StateError('Add columns before rows');
    }
    if (values.length != _columns.length) {
      throw ArgumentError(
        'Row length ${values.length} != column count ${_columns.length}',
      );
    }
    final rowNumber = _rows.length + 1;
    for (var c = 0; c < _columns.length; c++) {
      _validateValueForColumn(values[c], _columns[c], rowNumber);
    }
    _rows.add(values);
    return _self;
  }

  /// Gets the table name.
  String get tableName => _table;

  /// Gets the list of column names in the order they were added.
  List<String> get columnNames => _columns.map((c) => c.name).toList();

  /// Gets the number of rows in the builder (row- or column-oriented).
  int get rowCount => _effectiveRowCount;
}
