import 'package:meta/meta.dart';

/// Metadata for a single column in a query result.
///
/// Pure domain entity — carries only the column **name** and the
/// **protocol type discriminant** (mirror of the Rust `OdbcType` enum
/// at `native/odbc_engine/src/protocol/types.rs`). The numeric value
/// is the wire protocol discriminant, **not** the ODBC `SQL_*` type
/// code.
///
/// The richer typed view (`OdbcType` enum) lives in the
/// infrastructure layer and is exposed as an extension on
/// [ColumnMetadata] so the domain stays free of FFI / protocol
/// dependencies. Consumers who need the typed view import the
/// extension explicitly:
///
/// ```dart
/// import 'package:odbc_fast/odbc_fast.dart';
///
/// for (final col in qr.columnsMetadata ?? const <ColumnMetadata>[]) {
///   print('${col.name} -> discriminant=${col.odbcType}');
/// }
/// ```
///
/// Discriminant table (truncated):
///
/// | Discriminant | Wire type           |
/// |--------------|---------------------|
/// | 1            | varchar (UTF-8)     |
/// | 2            | integer (i32 LE)    |
/// | 3            | bigInt (i64 LE)     |
/// | 4            | decimal (UTF-8)     |
/// | 5            | date (UTF-8)        |
/// | 6            | timestamp (UTF-8)   |
/// | 7            | binary (raw)        |
///
/// See the `OdbcType` enum for the full mapping.
@immutable
class ColumnMetadata {
  /// Creates a new [ColumnMetadata] instance.
  ///
  /// The [name] is the column name as returned from the database.
  /// The [odbcType] is the protocol discriminant (1..19); see
  /// `OdbcType` for the canonical mapping.
  const ColumnMetadata({required this.name, required this.odbcType});

  /// Column name.
  final String name;

  /// Protocol type discriminant (matches `OdbcType.discriminant`).
  /// Unknown discriminants degrade to varchar (1) for forward
  /// compatibility — see the typed view extension.
  final int odbcType;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ColumnMetadata &&
          other.name == name &&
          other.odbcType == odbcType);

  @override
  int get hashCode => Object.hash(name, odbcType);

  @override
  String toString() => 'ColumnMetadata(name: $name, odbcType: $odbcType)';
}
