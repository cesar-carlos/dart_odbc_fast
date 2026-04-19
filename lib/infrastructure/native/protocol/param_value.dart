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
  }

  throw ArgumentError('Unsupported SqlDataType kind: ${type.kind}');
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
