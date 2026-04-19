/// Logical type of a column on the wire (mirror of the Rust `OdbcType`
/// enum at `native/odbc_engine/src/protocol/types.rs`).
///
/// **The numeric value is the protocol discriminant**, not the ODBC SQL type
/// code. The Rust encoder writes `col.odbc_type as u16` and the Dart parser
/// reads the same `u16`. Round-trip-stable across versions.
///
/// | Discriminant | Variant            | Wire format                   |
/// |--------------|--------------------|-------------------------------|
/// | 1            | varchar            | UTF-8 string                  |
/// | 2            | integer            | 4-byte little-endian i32      |
/// | 3            | bigInt             | 8-byte little-endian i64      |
/// | 4            | decimal            | UTF-8 textual representation  |
/// | 5            | date               | UTF-8 `YYYY-MM-DD`            |
/// | 6            | timestamp          | UTF-8 `YYYY-MM-DD HH:MM:SS.f` |
/// | 7            | binary             | raw bytes                     |
/// | 8            | nVarchar (v3.0)    | UTF-8 string                  |
/// | 9            | timestampWithTz    | UTF-8 `YYYY-MM-DD HH:MM:SS+TZ`|
/// | 10           | datetimeOffset     | UTF-8 ISO-8601 with offset    |
/// | 11           | time               | UTF-8 `HH:MM:SS[.f]`          |
/// | 12           | smallInt           | UTF-8 textual integer         |
/// | 13           | boolean            | UTF-8 `0`/`1` or `true`/`false` |
/// | 14           | float              | UTF-8 textual float           |
/// | 15           | doublePrecision    | UTF-8 textual double          |
/// | 16           | json               | UTF-8 JSON text               |
/// | 17           | uuid               | UTF-8 string `xxxxxxxx-...`   |
/// | 18           | money              | UTF-8 textual decimal         |
/// | 19           | interval           | UTF-8 textual interval        |
///
/// Unknown discriminants degrade to [varchar] for forward compatibility.
enum OdbcType {
  varchar(1),
  integer(2),
  bigInt(3),
  decimal(4),
  date(5),
  timestamp(6),
  binary(7),
  nVarchar(8),
  timestampWithTz(9),
  datetimeOffset(10),
  time(11),
  smallInt(12),
  boolean(13),
  float(14),
  doublePrecision(15),
  json(16),
  uuid(17),
  money(18),
  interval(19);

  const OdbcType(this.discriminant);

  /// Numeric discriminant on the wire (matches Rust enum repr).
  final int discriminant;

  /// Resolve a Dart [OdbcType] from a wire discriminant.
  /// Unknown codes degrade to [OdbcType.varchar] (matches Rust behaviour).
  static OdbcType fromDiscriminant(int code) {
    switch (code) {
      case 1:
        return OdbcType.varchar;
      case 2:
        return OdbcType.integer;
      case 3:
        return OdbcType.bigInt;
      case 4:
        return OdbcType.decimal;
      case 5:
        return OdbcType.date;
      case 6:
        return OdbcType.timestamp;
      case 7:
        return OdbcType.binary;
      case 8:
        return OdbcType.nVarchar;
      case 9:
        return OdbcType.timestampWithTz;
      case 10:
        return OdbcType.datetimeOffset;
      case 11:
        return OdbcType.time;
      case 12:
        return OdbcType.smallInt;
      case 13:
        return OdbcType.boolean;
      case 14:
        return OdbcType.float;
      case 15:
        return OdbcType.doublePrecision;
      case 16:
        return OdbcType.json;
      case 17:
        return OdbcType.uuid;
      case 18:
        return OdbcType.money;
      case 19:
        return OdbcType.interval;
      default:
        return OdbcType.varchar;
    }
  }

  /// True when the column is delivered as raw binary on the wire.
  bool get isBinaryWire => this == OdbcType.binary;

  /// True when the column is delivered as a fixed-width LE integer.
  bool get isIntegerWire => this == OdbcType.integer || this == OdbcType.bigInt;

  /// True when the column is delivered as UTF-8 text on the wire (default
  /// for everything that is neither binary nor a fixed-width integer).
  bool get isTextWire => !isBinaryWire && !isIntegerWire;
}
