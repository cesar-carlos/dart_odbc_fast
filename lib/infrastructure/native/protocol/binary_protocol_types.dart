import 'package:odbc_fast/domain/entities/column_metadata.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/infrastructure/native/protocol/odbc_type.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

export 'package:odbc_fast/domain/entities/column_metadata.dart';

/// Typed-view extension over the domain [ColumnMetadata].
extension ColumnMetadataTypedView on ColumnMetadata {
  OdbcType get type => OdbcType.fromDiscriminant(odbcType);
}

/// Parsed result buffer containing rows and column metadata.
class ParsedRowBuffer {
  ParsedRowBuffer({
    required this.columns,
    required this.rows,
    required this.rowCount,
    required this.columnCount,
  });

  final List<ColumnMetadata> columns;
  final List<List<dynamic>> rows;
  final int rowCount;
  final int columnCount;

  List<String>? _columnNames;

  /// Column names cached once from [columns] (shared list; do not mutate).
  List<String> get columnNames => _columnNames ??= List<String>.generate(
        columns.length,
        (i) => columns[i].name,
        growable: false,
      );
}

/// A parsed ODBC binary message: row/column payload plus optional trailers.
class ParsedQueryMessage {
  const ParsedQueryMessage({
    required this.rowBuffer,
    this.outputParamValues = const <ParamValue>[],
    this.refCursorRowBuffers = const <ParsedRowBuffer>[],
  });

  final ParsedRowBuffer rowBuffer;
  final List<ParamValue> outputParamValues;
  final List<ParsedRowBuffer> refCursorRowBuffers;
}

/// Columnar parse result with typed columns and optional trailers.
class ParsedColumnarQueryMessage {
  const ParsedColumnarQueryMessage({
    required this.columnarResult,
    this.outputParamValues = const <ParamValue>[],
    this.refCursorRowBuffers = const <ParsedRowBuffer>[],
  });

  final TypedColumnarResult columnarResult;
  final List<ParamValue> outputParamValues;
  final List<ParsedRowBuffer> refCursorRowBuffers;
}
