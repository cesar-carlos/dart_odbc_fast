import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

void main() {
  test('should_preserve_first_occurrence_and_snapshot_names', () {
    final names = ['Name', 'Name', 'NAME', 'age'];
    final rows = <List<dynamic>>[
      ['first', 'second', 'third', 3],
      [null],
    ];
    final result = QueryResult(columns: names, rows: rows, rowCount: 2);
    final reader = result.reader();
    names[0] = 'changed';
    expect(reader.columnIndex('Name'), 0);
    expect(reader.columnIndex('name', ignoreCase: true), 0);
    expect(reader.cellAs<String>(0, 'Name'), 'first');
    expect(reader.scalar<int>('age'), 3);
    expect(reader.cellAs<int>(0, 'Name'), isNull);
    expect(reader.columnValues<String>('Name'), ['first', null]);
    expect(reader.columnValues<String>('Name', includeNulls: false), ['first']);
    expect(reader.cell(-1, 'Name'), isNull);
    expect(reader.cell(1, 'age'), isNull);
    expect(reader.hasColumn('unknown'), isFalse);
    rows[0][0] = 'live row';
    expect(reader.firstValue<String>('Name'), 'live row');
    expect(reader.rowAsMap(0)['Name'], 'second');
    expect(() => reader.columns.add('new'), throwsUnsupportedError);
  });
}
