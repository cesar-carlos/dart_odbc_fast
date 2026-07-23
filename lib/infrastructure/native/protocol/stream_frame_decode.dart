import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/column_metadata.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser, ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/odbc_type.dart';

/// Decodes one complete batched-stream protocol frame into a [ParsedRowBuffer].
///
/// Columnar v2 frames are decoded via [BinaryProtocolParser.parse] (direct
/// columnar→row path). Callers that want to keep typed columns should use
/// [BinaryProtocolParser.parseColumnarToTyped] / `streamQueryColumnar*` instead
/// of this helper.
ParsedRowBuffer decodeBatchedStreamFrame(
  Uint8List frame, {
  bool lazyStrings = false,
}) {
  return BinaryProtocolParser.parse(frame, lazyStrings: lazyStrings);
}

/// Builds a [ParsedRowBuffer] view from an already-decoded columnar result.
ParsedRowBuffer parsedRowBufferFromTypedColumnar(TypedColumnarResult typed) {
  final qr = fromTypedColumnar(typed);
  return ParsedRowBuffer(
    columns: typed.columns
        .map(
          (col) => ColumnMetadata(
            name: col.name,
            odbcType: _odbcDiscriminantForKind(col.kind),
          ),
        )
        .toList(growable: false),
    rows: qr.rows,
    rowCount: typed.rowCount,
    columnCount: typed.columnCount,
  );
}

int _odbcDiscriminantForKind(TypedColumnKind kind) => switch (kind) {
      TypedColumnKind.int32 => OdbcType.integer.discriminant,
      TypedColumnKind.int64 => OdbcType.bigInt.discriminant,
      TypedColumnKind.float64 => OdbcType.doublePrecision.discriminant,
      TypedColumnKind.bool_ => OdbcType.boolean.discriminant,
      TypedColumnKind.string => OdbcType.varchar.discriminant,
      TypedColumnKind.bytes => OdbcType.binary.discriminant,
      TypedColumnKind.dateTime => OdbcType.timestamp.discriminant,
      TypedColumnKind.decimal => OdbcType.decimal.discriminant,
      TypedColumnKind.unknown => OdbcType.varchar.discriminant,
    };
