part of 'bulk_insert_builder.dart';

enum BulkPayloadVersion {
  /// Legacy fixed-width wire format without a magic header.
  legacy,

  /// Versioned wire format that stores variable-width cell lengths.
  v2,
}

/// Column data types for bulk insert operations.
enum BulkColumnType {
  /// 32-bit integer.
  i32(_tagI32),

  /// 64-bit integer.
  i64(_tagI64),

  /// Text/string data.
  text(_tagText),

  /// Decimal/numeric data.
  decimal(_tagDecimal),

  /// Binary data.
  binary(_tagBinary),

  /// Timestamp/datetime data.
  timestamp(_tagTimestamp);

  /// Creates a [BulkColumnType] with the given tag.
  const BulkColumnType(this.tag);

  /// The numeric tag used in the binary protocol.
  final int tag;
}

/// Specification for a column in a bulk insert operation.
class BulkColumnSpec {
  /// Creates a new [BulkColumnSpec] instance.
  ///
  /// The [name] is the column name.
  /// The [colType] specifies the data type.
  /// The [nullable] flag indicates if the column can contain NULL values.
  /// The [maxLen] specifies the maximum length for variable-length types.
  BulkColumnSpec({
    required this.name,
    required this.colType,
    this.nullable = false,
    this.maxLen = 0,
  });

  /// The column name.
  final String name;

  /// The column data type.
  final BulkColumnType colType;

  /// Whether the column can contain NULL values.
  final bool nullable;

  /// Maximum length for variable-length types (0 = unlimited).
  final int maxLen;
}

/// Represents a timestamp value for bulk insert operations.
class BulkTimestamp {
  /// Creates a new [BulkTimestamp] instance.
  const BulkTimestamp({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    this.fraction = 0,
  });

  /// The year (e.g., 2024).
  final int year;

  /// The month (1-12).
  final int month;

  /// The day of month (1-31).
  final int day;

  /// The hour (0-23).
  final int hour;

  /// The minute (0-59).
  final int minute;

  /// The second (0-59).
  final int second;

  /// Fractional seconds in nanoseconds.
  final int fraction;

  /// Creates a [BulkTimestamp] from a [DateTime] instance.
  // Reason: fromDateTime is the established bulk wire helper;
  // AUDIT-DART-2026-06, remove when BulkTimestamp gains a constructor alias.
  // ignore: prefer_constructors_over_static_methods
  static BulkTimestamp fromDateTime(DateTime dt) {
    return BulkTimestamp(
      year: dt.year,
      month: dt.month,
      day: dt.day,
      hour: dt.hour,
      minute: dt.minute,
      second: dt.second,
      fraction: dt.millisecond * 1000000 + dt.microsecond,
    );
  }
}
