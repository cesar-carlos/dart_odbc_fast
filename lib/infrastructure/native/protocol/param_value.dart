import 'dart:convert';
import 'dart:typed_data';

const int _tagNull = 0;
const int _tagString = 1;
const int _tagInteger = 2;
const int _tagBigInt = 3;
const int _tagDecimal = 4;
const int _tagBinary = 5;
const Endian _littleEndian = Endian.little;
const int _defaultDecimalScale = 6;
const int _minDateTimeYear = 1;
const int _maxDateTimeYear = 9999;

const int _smallIntMin = -32768;
const int _smallIntMax = 32767;

/// `TINYINT` range chosen to match SQL Server / Sybase ASE / Sybase ASA
/// (unsigned 0..255). PostgreSQL has no `TINYINT`, MySQL/MariaDB
/// default to *signed* `[-128, 127]` but accept the unsigned range via
/// `TINYINT UNSIGNED`; we pick the broadest interoperable contract so
/// callers don't get an unexpected truncation on SQL Server.
const int _tinyIntMin = 0;
const int _tinyIntMax = 255;

/// SQL Server / Sybase / DB2 MONEY type carries 4 fractional digits
/// (the canonical `monetary` precision). Other engines (PostgreSQL
/// `money`, MySQL `DECIMAL(15,4)`) follow the same convention. We
/// pin the fractional precision at 4 so a `num` round-trips through
/// the engine without scale renegotiation.
const int _moneyFractionalDigits = 4;

/// Canonical UUID matcher: 8-4-4-4-12 hex digits, case-insensitive.
/// We validate against this *after* normalising the value (stripping
/// braces and folding to lowercase), so callers can pass `{...}`,
/// uppercase, or the bare 32-hex form indistinguishably.
final RegExp _uuidCanonicalPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final RegExp _uuidBareHexPattern = RegExp(r'^[0-9a-f]{32}$');

/// IPv4 octet matcher (`0..255`); used by the structural CIDR
/// validator instead of a single mega-regex because the address-vs-
/// prefix split is much easier to reason about as plain code.
final RegExp _ipv4OctetPattern = RegExp(r'^(25[0-5]|2[0-4]\d|[01]?\d{1,2})$');

/// IPv6 group matcher (1-4 hex digits). The full-address validation
/// is done structurally — see [_isValidIpv6Address].
final RegExp _ipv6GroupPattern = RegExp(r'^[0-9a-fA-F]{1,4}$');

/// `hierarchyid` path matcher: starts with `/`, followed by zero or
/// more `/`-separated segments, each of which is a positive integer
/// optionally with a `.fraction` component (SQL Server uses
/// `1.5`-style segments to insert nodes between siblings without
/// renumbering). Always ends with a trailing `/`.
final RegExp _hierarchyIdPattern = RegExp(r'^/(\d+(\.\d+)?/)*$');

List<int> _u32Le(int v) {
  final buffer = Uint8List(4);
  ByteData.view(buffer.buffer).setUint32(0, v, _littleEndian);
  return buffer;
}

List<int> _i32Le(int v) {
  final buffer = Uint8List(4);
  ByteData.view(buffer.buffer).setInt32(0, v, _littleEndian);
  return buffer;
}

List<int> _i64Le(int v) {
  final buffer = Uint8List(8);
  ByteData.view(buffer.buffer).setInt64(0, v, _littleEndian);
  return buffer;
}

String _toValidatedUtcIso8601(DateTime value) {
  if (value.year < _minDateTimeYear || value.year > _maxDateTimeYear) {
    throw ArgumentError(
      'DateTime year must be between $_minDateTimeYear and '
      '$_maxDateTimeYear, got ${value.year}.',
    );
  }
  return value.toUtc().toIso8601String();
}

String _unsupportedParameterTypeMessage(Object value) {
  final buffer = StringBuffer()
    ..write('Unsupported parameter type: ')
    ..write(value.runtimeType)
    ..write('. ')
    ..write(
      'Expected one of: null, int, String, List<int>, bool, double, '
      'DateTime, or ParamValue. ',
    )
    ..write('Use explicit ParamValue wrapper if needed, e.g., ')
    ..write('ParamValueString(value) for custom string conversion.');
  return buffer.toString();
}

/// Explicit SQL data types for optional typed parameter API.
///
/// This is an experimental, non-breaking layer on top of [ParamValue].
/// Existing untyped conversions continue to work as before.
class SqlDataType {
  const SqlDataType._(this.kind, {this.length, this.precision, this.scale});

  factory SqlDataType.decimal({int? precision, int? scale}) =>
      SqlDataType._('decimal', precision: precision, scale: scale);

  factory SqlDataType.varChar({int? length}) =>
      SqlDataType._('varchar', length: length);

  factory SqlDataType.nVarChar({int? length}) =>
      SqlDataType._('nvarchar', length: length);

  factory SqlDataType.varBinary({int? length}) =>
      SqlDataType._('varbinary', length: length);

  /// SQL `JSON` / `JSONB` payload. Accepts a `String` (assumed to be
  /// already-serialised JSON), a `Map<String, dynamic>`, or a `List`;
  /// the latter two are encoded with `dart:convert::jsonEncode`.
  /// Serialised as a UTF-8 string on the wire (engines without a
  /// native `JSON` type accept this transparently as `NVARCHAR`).
  ///
  /// Pass `validate: true` to round-trip the input through `jsonDecode`
  /// before sending — useful in dev/test, off by default to avoid
  /// paying the parse cost on the hot path.
  factory SqlDataType.json({bool validate = false}) =>
      SqlDataType._(validate ? 'json_validated' : 'json');

  /// SQL `XML` — XML payload. Accepts a `String`. Serialised as a
  /// UTF-8 string on the wire (engines without a native `XML` type
  /// accept this transparently as `NVARCHAR`).
  ///
  /// Pass `validate: true` to run a *cheap structural sanity check*
  /// (must start with `<` and contain a matching `>` after trimming)
  /// before sending — useful for catching obvious mistakes early
  /// without paying the cost of a real XML parser. The default is
  /// `false` so multi-KB payloads don't pay the check on the hot
  /// path.
  factory SqlDataType.xml({bool validate = false}) =>
      SqlDataType._(validate ? 'xml_validated' : 'xml');

  /// Semantic SQL kind used for validation and conversion.
  final String kind;

  /// Optional length for textual/binary kinds.
  final int? length;

  /// Optional precision for decimal kinds.
  final int? precision;

  /// Optional scale for decimal kinds.
  final int? scale;

  static const SqlDataType int32 = SqlDataType._('int32');
  static const SqlDataType int64 = SqlDataType._('int64');
  static const SqlDataType dateTime = SqlDataType._('datetime');
  static const SqlDataType date = SqlDataType._('date');
  static const SqlDataType time = SqlDataType._('time');
  static const SqlDataType boolAsInt32 = SqlDataType._('bool_as_int32');

  /// SQL `SMALLINT` (16-bit signed). Validates the input against
  /// `[-32768, 32767]` and serialises as a 32-bit integer on the wire
  /// (the engine has no separate 16-bit slot in our binary protocol;
  /// the validation is what makes this type distinct from
  /// [SqlDataType.int32]).
  static const SqlDataType smallInt = SqlDataType._('smallint');

  /// SQL `BIGINT` (64-bit signed). Idiomatic alias for
  /// [SqlDataType.int64] — same wire representation, same validation,
  /// just the SQL-flavoured spelling so call sites read more naturally
  /// when paired with a `BIGINT` column.
  static const SqlDataType bigInt = SqlDataType._('bigint');

  /// SQL `UUID` / `UNIQUEIDENTIFIER`. Accepts the canonical
  /// `8-4-4-4-12` form, the bare 32-hex form, or either wrapped in
  /// `{...}`. Folds to lowercase canonical before sending so the
  /// engine sees a normalised value regardless of how the caller
  /// formatted it. Rejects anything that isn't a well-formed UUID
  /// with an actionable [ArgumentError].
  static const SqlDataType uuid = SqlDataType._('uuid');

  /// SQL `MONEY` / `SMALLMONEY` / `DECIMAL(15, 4)` — fixed monetary
  /// scale of 4 fractional digits. Accepts `num` (formatted with
  /// `toStringAsFixed(4)`) or `String` (passed through verbatim).
  /// `NaN` / `Infinity` are rejected. Use [SqlDataType.decimal] for
  /// arbitrary scale.
  static const SqlDataType money = SqlDataType._('money');

  /// SQL `TINYINT` (unsigned 8-bit on SQL Server / Sybase; the
  /// broadest interoperable contract). Validates the input against
  /// `[0, 255]` and serialises as a 32-bit integer on the wire (the
  /// engine has no separate 8-bit slot in our binary protocol; the
  /// validation is what makes this type distinct from
  /// [SqlDataType.int32]).
  ///
  /// MySQL/MariaDB callers using **signed** `TINYINT` (`[-128, 127]`)
  /// should use [SqlDataType.smallInt] instead — its `[-32768, 32767]`
  /// range comfortably covers the signed-tinyint domain without
  /// imposing an artificial restriction.
  static const SqlDataType tinyInt = SqlDataType._('tinyint');

  /// SQL `BIT` (boolean). Accepts `bool` (mapped to 1/0) or `int`
  /// (must be exactly 0 or 1). Serialises as a 32-bit integer on the
  /// wire — the canonical representation across SQL Server,
  /// PostgreSQL `BIT`, MySQL `BIT(1)`, Db2, Oracle (via
  /// `NUMBER(1)`).
  ///
  /// Idiomatic for columns whose *type name* is `BIT`. For columns
  /// labelled `BOOL` / `BOOLEAN` see [SqlDataType.boolAsInt32], which
  /// is identical on the wire but rejects `int` inputs to enforce
  /// type discipline.
  static const SqlDataType bit = SqlDataType._('bit');

  /// SQL `TEXT` / `NTEXT` / `CLOB` — long-form character data with
  /// no caller-supplied length cap. Accepts `String` only.
  /// Serialised as a UTF-8 string on the wire, identical to
  /// [SqlDataType.varChar] / [SqlDataType.nVarChar]; the distinction
  /// is purely semantic so call sites paired with a `TEXT` column
  /// read naturally.
  static const SqlDataType text = SqlDataType._('text');

  // -----------------------------------------------------------------
  // Engine-specific kinds. Each is wire-compatible with an existing
  // `ParamValue*` primitive (typically String or Binary) — the value
  // of routing through `SqlDataType` is the explicit semantic name in
  // the call site plus the per-kind input validation.
  //
  // **Important caveat shared by SQL Server `hierarchyid` and
  // `geography`, and by Oracle `BFILE`**: these types are usually NOT
  // bindable as a plain `?` placeholder of their native SQL type.
  // The driver expects a textual representation that must be wrapped
  // in a CAST or constructor function inside the SQL itself, e.g.:
  //
  //   INSERT INTO t(node) VALUES (CAST(? AS hierarchyid))
  //   INSERT INTO t(area) VALUES (geography::STGeomFromText(?, 4326))
  //   INSERT INTO t(doc)  VALUES (BFILENAME(?, ?))
  //
  // We document the convention here once and let each kind's doc
  // comment refer to it. The wire-level work this layer does is
  // exactly the same as `varChar` / `varBinary`; the value lives in
  // the **type-discipline at the call site**.
  // -----------------------------------------------------------------

  /// PostgreSQL **range** literal (`int4range`, `int8range`, `numrange`,
  /// `tsrange`, `tstzrange`, `daterange`, `int4multirange`, ...).
  /// Accepts a `String` literal in PostgreSQL's standard form, e.g.
  /// `'[1,10)'`, `'(1,5]'`, `'[2020-01-01,2020-12-31)'`. Wraps in
  /// [ParamValueString]; the server resolves the concrete range type
  /// from the column definition.
  ///
  /// We do **not** validate the bracket / value grammar — PostgreSQL
  /// accepts a wide variety of formats per concrete subtype and the
  /// server is the authoritative validator at execute-time.
  static const SqlDataType range = SqlDataType._('range');

  /// PostgreSQL **CIDR** / **INET** address literal (`192.168.1.0/24`,
  /// `2001:db8::/32`). Accepts a `String`. Validates against a
  /// pragmatic IPv4/IPv6 regex — accepts most well-formed inputs
  /// without pulling in a full RFC-grade parser. The server remains
  /// the authoritative validator at execute-time.
  ///
  /// Wraps in [ParamValueString]. PostgreSQL accepts the same string
  /// form for both `cidr` and `inet` columns.
  static const SqlDataType cidr = SqlDataType._('cidr');

  /// PostgreSQL **tsvector** (full-text search lexeme list). Accepts a
  /// `String` in `tsvector`'s native form: `'fat:1A cat:2B sat:3'` or
  /// the simpler space-separated lexeme list. Wraps in
  /// [ParamValueString]. Sintax is too permissive to validate
  /// usefully here; PostgreSQL's `to_tsvector` / cast is the real
  /// validator.
  static const SqlDataType tsvector = SqlDataType._('tsvector');

  /// SQL Server **hierarchyid** path (`'/'`, `'/1/'`, `'/1/2/3.5/'`).
  /// Accepts a `String`; validates that it starts with `/`, contains
  /// only `/`-separated decimal segments (each optionally with a
  /// `.fraction` for between-siblings inserts), and ends with `/`.
  ///
  /// **Caller is responsible for the CAST**: SQL Server's `hierarchyid`
  /// is not directly bindable from a parameter; the typical idiom is
  ///
  /// ```sql
  /// INSERT INTO t(node) VALUES (CAST(? AS hierarchyid))
  /// ```
  ///
  /// Wraps in [ParamValueString].
  static const SqlDataType hierarchyId = SqlDataType._('hierarchyid');

  /// SQL Server **geography** / **geometry** WKT literal
  /// (`'POINT(-122.349 47.651)'`, `'POLYGON((...))'`). Accepts a
  /// `String` in the OGC Well-Known Text form. Wraps in
  /// [ParamValueString].
  ///
  /// **Caller is responsible for the constructor function**: SQL
  /// Server's spatial types require an explicit constructor in the
  /// SQL, typically:
  ///
  /// ```sql
  /// INSERT INTO t(area) VALUES (geography::STGeomFromText(?, 4326))
  /// ```
  ///
  /// (The `4326` is the SRID — WGS-84 by convention; choose the SRID
  /// appropriate to your data.) For binary WKB payloads use
  /// [SqlDataType.varBinary] together with `geography::STGeomFromWKB`.
  static const SqlDataType geography = SqlDataType._('geography');

  /// Oracle **RAW** binary data. Accepts `List<int>` (or `Uint8List`).
  /// Wraps in [ParamValueBinary] — wire-compatible with
  /// [SqlDataType.varBinary]; the distinction is purely semantic so
  /// call sites paired with an Oracle `RAW(N)` column read naturally.
  ///
  /// Oracle's legacy `RAW` is capped at 2000 bytes; modern
  /// `RAW(32767)` requires `MAX_STRING_SIZE = EXTENDED`. This layer
  /// does not enforce either limit — the server rejects oversize
  /// values at execute-time with a descriptive error.
  static const SqlDataType raw = SqlDataType._('raw');

  /// Oracle **BFILE** locator. Accepts a `String` containing a
  /// fully-formed `BFILENAME(...)` invocation, e.g.
  /// `"BFILENAME('DIR_OBJECT', 'docs/file.pdf')"`. Wraps in
  /// [ParamValueString].
  ///
  /// **`BFILE` is a pointer to an external file**, not the file
  /// content. In practice it is set via SQL like:
  ///
  /// ```sql
  /// INSERT INTO t(doc) VALUES (BFILENAME(?, ?))
  /// -- params: ['DIR_OBJECT', 'docs/file.pdf']
  /// ```
  ///
  /// In that case use two separate `varChar` parameters. This kind
  /// is provided for the less common case of binding a complete
  /// `BFILENAME(...)` text snippet that the server then evaluates.
  static const SqlDataType bfile = SqlDataType._('bfile');

  /// SQL `INTERVAL` (PostgreSQL `INTERVAL`, Oracle `INTERVAL DAY/YEAR`,
  /// Db2 `<n> SECONDS`). Accepts a [Duration] (formatted as
  /// `'<n> seconds'`, the broadest portable spelling — PostgreSQL,
  /// MySQL `INTERVAL`, Oracle `NUMTODSINTERVAL` accept it directly)
  /// or a `String` (passed through verbatim, for engines whose
  /// preferred syntax doesn't match the seconds form).
  ///
  /// Sub-second precision is preserved by emitting the fractional
  /// part as a decimal — e.g. `Duration(milliseconds: 1500)` becomes
  /// `'1.500 seconds'`. SQL Server has no `INTERVAL` type; its
  /// callers should compute differences with `DATEADD` / `DATEDIFF`
  /// instead.
  static const SqlDataType interval = SqlDataType._('interval');
}

/// Explicitly typed parameter value.
///
/// Use this wrapper when caller wants to opt into explicit SQL typing while
/// preserving compatibility with the existing `List<dynamic>` API.
class SqlTypedValue {
  const SqlTypedValue({
    required this.type,
    required this.value,
  });

  final SqlDataType type;
  final Object? value;
}

/// Convenience helper to create [SqlTypedValue] instances.
SqlTypedValue typedParam(SqlDataType type, Object? value) {
  return SqlTypedValue(type: type, value: value);
}

/// Base class for parameter values in prepared statements.
///
/// All parameter values must extend this sealed class and implement
/// [serialize] to convert the value to binary format.
sealed class ParamValue {
  /// Creates a new [ParamValue] instance.
  const ParamValue();

  /// Serializes this parameter value to binary format.
  ///
  /// Returns a list of bytes representing the parameter value.
  List<int> serialize();
}

/// Represents a NULL parameter value.
class ParamValueNull extends ParamValue {
  /// Creates a new [ParamValueNull] instance.
  const ParamValueNull();

  @override
  List<int> serialize() => [_tagNull, ..._u32Le(0)];
}

/// Represents a string parameter value.
class ParamValueString extends ParamValue {
  /// Creates a new [ParamValueString] instance.
  ///
  /// The [value] is the string to use as the parameter value.
  const ParamValueString(this.value);

  /// The string value.
  final String value;

  @override
  List<int> serialize() {
    final b = utf8.encode(value);
    return [_tagString, ..._u32Le(b.length), ...b];
  }
}

/// Represents a 32-bit integer parameter value.
class ParamValueInt32 extends ParamValue {
  /// Creates a new [ParamValueInt32] instance.
  ///
  /// The [value] is the 32-bit integer to use as the parameter value.
  const ParamValueInt32(this.value);

  /// The integer value.
  final int value;

  @override
  List<int> serialize() => [_tagInteger, ..._u32Le(4), ..._i32Le(value)];
}

/// Represents a 64-bit integer parameter value.
class ParamValueInt64 extends ParamValue {
  /// Creates a new [ParamValueInt64] instance.
  ///
  /// The [value] is the 64-bit integer to use as the parameter value.
  const ParamValueInt64(this.value);

  /// The integer value.
  final int value;

  @override
  List<int> serialize() => [_tagBigInt, ..._u32Le(8), ..._i64Le(value)];
}

/// Represents a decimal/numeric parameter value as a string.
class ParamValueDecimal extends ParamValue {
  /// Creates a new [ParamValueDecimal] instance.
  ///
  /// The [value] is the decimal value as a string (e.g., '123.45').
  const ParamValueDecimal(this.value);

  /// The decimal value as a string.
  final String value;

  @override
  List<int> serialize() {
    final b = utf8.encode(value);
    return [_tagDecimal, ..._u32Le(b.length), ...b];
  }
}

/// Represents a binary parameter value.
class ParamValueBinary extends ParamValue {
  /// Creates a new [ParamValueBinary] instance.
  ///
  /// The [value] is the binary data as a list of bytes.
  const ParamValueBinary(this.value);

  /// The binary data.
  final List<int> value;

  @override
  List<int> serialize() => [_tagBinary, ..._u32Le(value.length), ...value];
}

/// Serializes a list of parameter values to binary format.
///
/// The [params] list should contain [ParamValue] instances in the order
/// they appear in the prepared statement.
///
/// Returns a [Uint8List] containing the serialized parameters.
Uint8List serializeParams(List<ParamValue> params) {
  final out = <int>[];
  for (final p in params) {
    out.addAll(p.serialize());
  }
  return Uint8List.fromList(out);
}

/// Converts a single object to a `ParamValue` instance.
///
/// Supported implicit input types:
/// - `null` → `ParamValueNull`
/// - `ParamValue` → returned as-is
/// - `int` → `ParamValueInt32` or `ParamValueInt64` (based on range)
/// - `String` → `ParamValueString`
/// - `List<int>` or `Uint8List` → `ParamValueBinary`
/// - `bool` → `ParamValueInt32(1|0)` (canonical mapping)
/// - `double` → `ParamValueDecimal(value.toStringAsFixed(6))`
///   (canonical mapping; `NaN/Infinity` rejected)
/// - `DateTime` → `ParamValueString(value.toUtc().toIso8601String())`
///   (canonical mapping; year must be in `[1, 9999]`)
///
/// Throws [ArgumentError] for unsupported types with actionable message.
///
/// Example:
/// ```dart
/// final pv = toParamValue(42); // ParamValueInt32(42)
/// final pvNull = toParamValue(null); // ParamValueNull
/// final pvBool = toParamValue(true); // ParamValueInt32(1)
/// ```
ParamValue toParamValue(Object? value) {
  if (value == null) return const ParamValueNull();
  if (value is ParamValue) return value;
  if (value is SqlTypedValue) return _toTypedParamValue(value);

  // Fast path for int - most common case
  if (value is int) {
    if (value >= -0x80000000 && value <= 0x7FFFFFFF) {
      return ParamValueInt32(value);
    }
    return ParamValueInt64(value);
  }

  // String - common case
  if (value is String) return ParamValueString(value);

  // Binary data
  if (value is List<int>) return ParamValueBinary(value);

  // Canonical mappings - explicit conversions with clear semantics
  if (value is bool) {
    return ParamValueInt32(value ? 1 : 0);
  }
  if (value is double) {
    if (value.isNaN) {
      throw ArgumentError(
        'Double value is NaN. Cannot convert to decimal. '
        'Use explicit ParamValue with desired representation.',
      );
    }
    if (value.isInfinite) {
      final label = value.isNegative ? '-Infinity' : 'Infinity';
      throw ArgumentError(
        'Double value is $label. Cannot convert to decimal. '
        'Use explicit ParamValue with desired representation.',
      );
    }
    return ParamValueDecimal(value.toStringAsFixed(_defaultDecimalScale));
  }
  if (value is DateTime) {
    return ParamValueString(_toValidatedUtcIso8601(value));
  }

  // Unsupported type - explicit error instead of silent toString() fallback
  throw ArgumentError(_unsupportedParameterTypeMessage(value));
}

ParamValue _toTypedParamValue(SqlTypedValue typedValue) {
  final type = typedValue.type;
  final value = typedValue.value;

  if (value == null) {
    return const ParamValueNull();
  }

  switch (type.kind) {
    case 'int32':
      if (value is! int) {
        throw ArgumentError(
          'SqlDataType.int32 expects int, got ${value.runtimeType}',
        );
      }
      if (value < -0x80000000 || value > 0x7FFFFFFF) {
        throw ArgumentError(
          'SqlDataType.int32 value out of range: $value',
        );
      }
      return ParamValueInt32(value);
    case 'int64':
      if (value is! int) {
        throw ArgumentError(
          'SqlDataType.int64 expects int, got ${value.runtimeType}',
        );
      }
      return ParamValueInt64(value);
    case 'decimal':
      if (value is num) {
        return ParamValueDecimal(value.toString());
      }
      if (value is String) {
        return ParamValueDecimal(value);
      }
      throw ArgumentError(
        'SqlDataType.decimal expects num or String, got ${value.runtimeType}',
      );
    case 'varchar':
    case 'nvarchar':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.${type.kind} expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'varbinary':
      if (value is! List<int>) {
        throw ArgumentError(
          'SqlDataType.varBinary expects List<int>, got ${value.runtimeType}',
        );
      }
      return ParamValueBinary(value);
    case 'datetime':
      if (value is DateTime) {
        return ParamValueString(_toValidatedUtcIso8601(value));
      }
      if (value is String) {
        return ParamValueString(value);
      }
      throw ArgumentError(
        'SqlDataType.dateTime expects DateTime or String, '
        'got ${value.runtimeType}',
      );
    case 'date':
    case 'time':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.${type.kind} expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'bool_as_int32':
      if (value is! bool) {
        throw ArgumentError(
          'SqlDataType.boolAsInt32 expects bool, got ${value.runtimeType}',
        );
      }
      return ParamValueInt32(value ? 1 : 0);
    case 'smallint':
      if (value is! int) {
        throw ArgumentError(
          'SqlDataType.smallInt expects int, got ${value.runtimeType}',
        );
      }
      if (value < _smallIntMin || value > _smallIntMax) {
        throw ArgumentError(
          'SqlDataType.smallInt value out of range '
          '[$_smallIntMin, $_smallIntMax]: $value',
        );
      }
      return ParamValueInt32(value);
    case 'bigint':
      // Idiomatic alias for int64 — same wire representation. We
      // intentionally accept any int (Dart ints are 64-bit on every
      // supported platform) instead of duplicating int64's range
      // check, which is a no-op there.
      if (value is! int) {
        throw ArgumentError(
          'SqlDataType.bigInt expects int, got ${value.runtimeType}',
        );
      }
      return ParamValueInt64(value);
    case 'json':
      return ParamValueString(_toJsonString(value, validate: false));
    case 'json_validated':
      return ParamValueString(_toJsonString(value, validate: true));
    case 'uuid':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.uuid expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(_normaliseUuid(value));
    case 'money':
      return ParamValueDecimal(_toMoneyString(value));
    case 'tinyint':
      if (value is! int) {
        throw ArgumentError(
          'SqlDataType.tinyInt expects int, got ${value.runtimeType}',
        );
      }
      if (value < _tinyIntMin || value > _tinyIntMax) {
        throw ArgumentError(
          'SqlDataType.tinyInt value out of range '
          '[$_tinyIntMin, $_tinyIntMax]: $value',
        );
      }
      return ParamValueInt32(value);
    case 'bit':
      if (value is bool) {
        return ParamValueInt32(value ? 1 : 0);
      }
      if (value is int) {
        if (value != 0 && value != 1) {
          throw ArgumentError(
            'SqlDataType.bit expects exactly 0 or 1 when given an int; '
            'got $value',
          );
        }
        return ParamValueInt32(value);
      }
      throw ArgumentError(
        'SqlDataType.bit expects bool or int (0 or 1), '
        'got ${value.runtimeType}',
      );
    case 'text':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.text expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'xml':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.xml expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'xml_validated':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.xml expects String, got ${value.runtimeType}',
        );
      }
      _validateXmlShape(value);
      return ParamValueString(value);
    case 'interval':
      return ParamValueString(_toIntervalString(value));
    case 'range':
    case 'tsvector':
    case 'bfile':
      // Three engine-specific kinds with no per-input validation:
      // the server is the authoritative validator at execute-time.
      // Sharing one branch keeps the switch tight.
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.${type.kind} expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'cidr':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.cidr expects String, got ${value.runtimeType}',
        );
      }
      _validateCidrLiteral(value);
      return ParamValueString(value);
    case 'hierarchyid':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.hierarchyId expects String, got ${value.runtimeType}',
        );
      }
      _validateHierarchyIdLiteral(value);
      return ParamValueString(value);
    case 'geography':
      // We only accept WKT here (String). Binary WKB callers should
      // use SqlDataType.varBinary together with `geography::STGeomFromWKB`.
      // Rejecting `List<int>` explicitly avoids silent ambiguity.
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.geography expects String (WKT); for binary WKB use '
          'SqlDataType.varBinary with geography::STGeomFromWKB. '
          'Got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'raw':
      if (value is! List<int>) {
        throw ArgumentError(
          'SqlDataType.raw expects List<int>, got ${value.runtimeType}',
        );
      }
      return ParamValueBinary(value);
  }

  throw ArgumentError('Unsupported SqlDataType kind: ${type.kind}');
}

/// Pragmatic CIDR / INET validator for `SqlDataType.cidr`.
///
/// Accepts:
/// - bare IPv4 (`192.168.1.1`) or IPv4 with `/0..32` prefix
/// - bare IPv6 in canonical or compressed `::` form, or IPv6 with
///   `/0..128` prefix
///
/// Implemented structurally rather than via a single regex because
/// IPv6's compressed form (`::`) makes a regex either overly permissive
/// (accepts `fe80:::1`) or overly strict (rejects `2001:db8::1`).
/// PostgreSQL remains the authoritative validator at execute-time;
/// this check just rules out the obvious typos that would otherwise
/// round-trip before failing.
void _validateCidrLiteral(String s) {
  final trimmed = s.trim();
  if (trimmed.isEmpty) {
    _throwCidrError(s);
  }

  // Split off the optional /prefix.
  final slashIdx = trimmed.indexOf('/');
  final addrPart = slashIdx < 0 ? trimmed : trimmed.substring(0, slashIdx);
  final prefixPart = slashIdx < 0 ? null : trimmed.substring(slashIdx + 1);

  final isIpv4 = _isValidIpv4Address(addrPart);
  final isIpv6 = !isIpv4 && _isValidIpv6Address(addrPart);
  if (!isIpv4 && !isIpv6) {
    _throwCidrError(s);
  }

  if (prefixPart != null) {
    final mask = int.tryParse(prefixPart);
    final maxMask = isIpv4 ? 32 : 128;
    if (mask == null || mask < 0 || mask > maxMask) {
      _throwCidrError(s);
    }
  }
}

Never _throwCidrError(String s) {
  throw ArgumentError(
    'SqlDataType.cidr expects an IPv4/IPv6 address, optionally with a '
    '/prefix mask (e.g. "192.168.1.0/24" or "2001:db8::/32"); '
    'got "$s"',
  );
}

bool _isValidIpv4Address(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return false;
  for (final p in parts) {
    if (!_ipv4OctetPattern.hasMatch(p)) return false;
  }
  return true;
}

/// Validate an IPv6 address allowing the compressed `::` form.
///
/// Rules enforced:
/// - At most one `::` (the compression marker).
/// - With `::`: at most 8 groups total in the expansion.
/// - Without `::`: exactly 8 groups.
/// - Each group is 1..4 hex digits.
/// - Edge case: `::` alone (the unspecified address) and trailing/
///   leading `::` (e.g. `::1`, `2001:db8::`) are valid.
bool _isValidIpv6Address(String s) {
  if (s.isEmpty) return false;
  // `:::` (three colons in a row) is never valid — bail before split.
  if (s.contains(':::')) return false;

  // Compressed form? Split exactly once to keep the leading/trailing
  // empty halves intact (`split` collapses adjacent separators when
  // given a regex; with a literal pattern it preserves them).
  final compressedParts = s.split('::');
  if (compressedParts.length > 2) return false;

  if (compressedParts.length == 2) {
    final left = compressedParts[0].isEmpty
        ? <String>[]
        : compressedParts[0].split(':');
    final right = compressedParts[1].isEmpty
        ? <String>[]
        : compressedParts[1].split(':');
    if (left.length + right.length > 7) return false;
    for (final g in [...left, ...right]) {
      if (!_ipv6GroupPattern.hasMatch(g)) return false;
    }
    return true;
  }

  // No `::` — must be exactly 8 groups.
  final groups = s.split(':');
  if (groups.length != 8) return false;
  for (final g in groups) {
    if (!_ipv6GroupPattern.hasMatch(g)) return false;
  }
  return true;
}

/// `hierarchyid` literal validator: must start with `/`, contain only
/// `/`-separated decimal segments (each optionally with a `.fraction`),
/// and end with `/`. SQL Server uses `1.5`-style segments to insert
/// nodes between siblings without renumbering, so the fraction is part
/// of the grammar — not a typo.
void _validateHierarchyIdLiteral(String s) {
  if (!_hierarchyIdPattern.hasMatch(s)) {
    throw ArgumentError(
      'SqlDataType.hierarchyId expects a "/"-rooted, "/"-terminated '
      'path of decimal segments (each optionally with a ".fraction"), '
      'e.g. "/", "/1/", "/1/2/3.5/"; got "$s"',
    );
  }
}

/// Cheap structural sanity check for `SqlDataType.xml(validate: true)`.
/// Not a real XML parser — just rules out obvious mistakes (empty
/// payload, missing root element brackets) without paying the cost of
/// instantiating an actual parser. The engine remains the source of
/// truth for full schema/well-formedness validation at execute-time.
void _validateXmlShape(String raw) {
  final s = raw.trim();
  if (s.isEmpty) {
    throw ArgumentError(
      'SqlDataType.xml(validate: true): payload is empty after trimming',
    );
  }
  if (!s.startsWith('<')) {
    throw ArgumentError(
      'SqlDataType.xml(validate: true): payload must start with "<"; '
      'got first char "${s[0]}"',
    );
  }
  if (!s.contains('>')) {
    throw ArgumentError(
      'SqlDataType.xml(validate: true): payload must contain a closing ">"',
    );
  }
}

/// Format an `INTERVAL`-typed value. `Duration` becomes
/// `'<n> seconds'` (with millisecond precision preserved as a
/// decimal); `String` is passed through verbatim. Anything else is
/// rejected with an actionable error.
///
/// The seconds form is the broadest portable spelling: PostgreSQL,
/// MySQL `INTERVAL`, Oracle `NUMTODSINTERVAL(n, 'SECOND')`, and Db2
/// `<n> SECONDS` all accept it directly. Engines whose preferred
/// syntax differs (Oracle `INTERVAL '1' DAY`, etc.) should pass a
/// `String` shaped to that engine's grammar.
String _toIntervalString(Object? value) {
  if (value is Duration) {
    final wholeSeconds = value.inSeconds;
    final remainderMillis = value.inMilliseconds.remainder(1000).abs();
    if (remainderMillis == 0) {
      return '$wholeSeconds seconds';
    }
    // Pad the fractional component to 3 digits so '1.5s' becomes
    // '1.500 seconds' — engines parse this unambiguously and the
    // padding round-trips back to the same Duration.
    final pad = remainderMillis.toString().padLeft(3, '0');
    return '$wholeSeconds.$pad seconds';
  }
  if (value is String) {
    return value;
  }
  throw ArgumentError(
    'SqlDataType.interval expects Duration or String, '
    'got ${value.runtimeType}',
  );
}

/// Encode a value as a JSON string suitable for the engine's `JSON` /
/// `NVARCHAR` slot. `String` is passed through verbatim (the caller is
/// trusted to have produced valid JSON); `Map` / `List` are encoded
/// via `dart:convert::jsonEncode`. Everything else is rejected with
/// an actionable error.
///
/// When `validate` is true the resulting string is round-tripped
/// through `jsonDecode` to catch syntactic mistakes the engine would
/// otherwise reject at execute time. We keep the parse opt-in because
/// `JSON` parameters can be many KB; paying for a parse on every call
/// is unnecessary in production where the JSON is already trusted.
String _toJsonString(Object? value, {required bool validate}) {
  String encoded;
  if (value == null) {
    // Caller passed an explicit `typedParam(SqlDataType.json(), null)`
    // — but `_toTypedParamValue` already short-circuits null at the
    // top, so this path is defensive only. Keep it tight to satisfy
    // the type checker without producing dead branches.
    throw ArgumentError(
      'SqlDataType.json received null after the null short-circuit; '
      'this is a bug — please report.',
    );
  } else if (value is String) {
    encoded = value;
  } else if (value is Map<String, dynamic> || value is List<dynamic>) {
    encoded = jsonEncode(value);
  } else {
    throw ArgumentError(
      'SqlDataType.json expects String, Map<String, dynamic>, or '
      'List<dynamic>; got ${value.runtimeType}',
    );
  }

  if (validate) {
    try {
      jsonDecode(encoded);
    } on FormatException catch (e) {
      throw ArgumentError(
        'SqlDataType.json(validate: true): payload is not valid JSON: '
        '${e.message}',
      );
    }
  }
  return encoded;
}

/// Validate and canonicalise a UUID string. Accepts the canonical
/// `8-4-4-4-12` form, the bare 32-hex form, and either wrapped in
/// `{...}`. Folds to lowercase. Returns the canonical form so the
/// engine sees a normalised value regardless of how the caller
/// formatted it.
String _normaliseUuid(String raw) {
  // Strip optional curly braces (common from .NET-flavoured tools)
  // before doing any matching so `{abc...}` and `abc...` are treated
  // the same.
  var s = raw.trim();
  if (s.startsWith('{') && s.endsWith('}')) {
    s = s.substring(1, s.length - 1);
  }
  s = s.toLowerCase();

  if (_uuidCanonicalPattern.hasMatch(s)) {
    return s;
  }
  if (_uuidBareHexPattern.hasMatch(s)) {
    // Insert hyphens at the canonical positions: 8-4-4-4-12.
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-'
        '${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }
  // Build the message in two steps so the canonical pattern stays
  // visually intact even though it contains a dash that could be
  // mistaken for a sentence break.
  const canonicalForm = '"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"';
  throw ArgumentError(
    'SqlDataType.uuid expects a 36-char canonical $canonicalForm '
    'or 32-char bare-hex UUID (optionally wrapped in {...}); '
    'got "$raw"',
  );
}

/// Format a `MONEY`-typed value with the canonical 4 fractional
/// digits. Accepts `num` (formatted with `toStringAsFixed(4)`) or a
/// `String` (passed through verbatim — the caller is trusted to have
/// produced a value the engine accepts). `NaN` / `Infinity` are
/// rejected with the same wording as the implicit `double → decimal`
/// path so error messages stay consistent.
String _toMoneyString(Object? value) {
  if (value is num) {
    final asDouble = value.toDouble();
    if (asDouble.isNaN) {
      throw ArgumentError(
        'SqlDataType.money received NaN; cannot format as monetary value.',
      );
    }
    if (asDouble.isInfinite) {
      final label = asDouble.isNegative ? '-Infinity' : 'Infinity';
      throw ArgumentError(
        'SqlDataType.money received $label; cannot format as monetary value.',
      );
    }
    return asDouble.toStringAsFixed(_moneyFractionalDigits);
  }
  if (value is String) {
    return value;
  }
  throw ArgumentError(
    'SqlDataType.money expects num or String, got ${value.runtimeType}',
  );
}

/// Converts a list of objects to `ParamValue` instances.
///
/// Fast path: if all items are already `ParamValue` or `null`,
/// converts and returns efficiently.
///
/// Supported implicit input types:
/// - `null` → `ParamValueNull`
/// - `ParamValue` → returned as-is (fast path)
/// - `int` → `ParamValueInt32` or `ParamValueInt64` (based on range)
/// - `String` → `ParamValueString`
/// - `List<int>` → `ParamValueBinary`
/// - `bool` → `ParamValueInt32(1|0)` (canonical mapping)
/// - `double` → `ParamValueDecimal(value.toStringAsFixed(6))`
///   (canonical mapping; `NaN/Infinity` rejected)
/// - `DateTime` → `ParamValueString(value.toUtc().toIso8601String())`
///   (canonical mapping; year must be in `[1, 9999]`)
///
/// Throws [ArgumentError] for unsupported types with actionable message.
///
/// Example:
/// ```dart
/// final params = paramValuesFromObjects([1, 'hello', null]);
/// // Returns: [ParamValueInt32(1), ParamValueString('hello'), ParamValueNull()]
/// ```
List<ParamValue> paramValuesFromObjects(List<Object?> params) {
  // Fast path: check if all items are already ParamValue or null
  if (params.isNotEmpty) {
    var allParamValueOrNull = true;
    for (final item in params) {
      if (item != null && item is! ParamValue) {
        allParamValueOrNull = false;
        break;
      }
    }
    if (allParamValueOrNull) {
      // Fast path: convert nulls to ParamValueNull, skip other items
      final result =
          List<ParamValue>.filled(params.length, const ParamValueNull());
      for (var i = 0; i < params.length; i++) {
        final item = params[i];
        if (item is ParamValue) {
          result[i] = item;
        }
      }
      return result;
    }
  }

  // Pre-size output list for better performance
  final result = List<ParamValue>.filled(params.length, const ParamValueNull());

  for (var i = 0; i < params.length; i++) {
    result[i] = toParamValue(params[i]);
  }

  return result;
}
