import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/types/sql_data_type.dart';

export 'package:odbc_fast/domain/entities/param_value.dart';
export 'package:odbc_fast/domain/types/sql_data_type.dart';

const int _tagNull = 0;
const int _tagString = 1;
const int _tagInteger = 2;
const int _tagBigInt = 3;
const int _tagDecimal = 4;
const int _tagBinary = 5;
const int _tagRefCursorOut = 6;
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
  return 'Unsupported parameter type: ${value.runtimeType}. '
      'Expected one of: null, int, String, List<int>, bool, double, '
      'DateTime, or ParamValue. '
      'Use explicit ParamValue wrapper if needed, e.g., '
      'ParamValueString(value) for custom string conversion.';
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

/// Serializes a list of parameter values to binary format.
///
/// The [params] list should contain [ParamValue] instances in the order
/// they appear in the prepared statement.
///
/// Returns a [Uint8List] containing the serialized parameters.
///
/// Uses a two-pass strategy: phase 1 pre-encodes text payloads and computes
/// the exact total byte count; phase 2 writes directly into a single
/// pre-sized [Uint8List] — avoiding all intermediate list allocations and
/// the final [Uint8List.fromList] copy that the old approach required.
Uint8List serializeParams(List<ParamValue> params) {
  if (params.isEmpty) return Uint8List(0);

  // Phase 1: pre-encode text payloads and compute total byte size.
  var totalBytes = 0;
  final encodedText = List<List<int>?>.filled(params.length, null);
  for (var i = 0; i < params.length; i++) {
    switch (params[i]) {
      case ParamValueNull():
        totalBytes += 5;
      case ParamValueString(:final value):
        final b = utf8.encode(value);
        encodedText[i] = b;
        totalBytes += 5 + b.length;
      case ParamValueInt32():
        totalBytes += 9;
      case ParamValueInt64():
        totalBytes += 13;
      case ParamValueDecimal(:final value):
        final b = utf8.encode(value);
        encodedText[i] = b;
        totalBytes += 5 + b.length;
      case ParamValueBinary(:final value):
        totalBytes += 5 + value.length;
      case ParamValueRefCursorOut():
        totalBytes += 5;
    }
  }

  // Phase 2: write all params into the pre-sized buffer.
  final out = Uint8List(totalBytes);
  final bd = ByteData.sublistView(out);
  var off = 0;
  for (var i = 0; i < params.length; i++) {
    switch (params[i]) {
      case ParamValueNull():
        out[off] = _tagNull;
        bd.setUint32(off + 1, 0, _littleEndian);
        off += 5;
      case ParamValueString():
        final b = encodedText[i]!;
        out[off] = _tagString;
        bd.setUint32(off + 1, b.length, _littleEndian);
        out.setRange(off + 5, off + 5 + b.length, b);
        off += 5 + b.length;
      case ParamValueInt32(:final value):
        out[off] = _tagInteger;
        bd.setUint32(off + 1, 4, _littleEndian);
        bd.setInt32(off + 5, value, _littleEndian);
        off += 9;
      case ParamValueInt64(:final value):
        out[off] = _tagBigInt;
        bd.setUint32(off + 1, 8, _littleEndian);
        bd.setInt64(off + 5, value, _littleEndian);
        off += 13;
      case ParamValueDecimal():
        final b = encodedText[i]!;
        out[off] = _tagDecimal;
        bd.setUint32(off + 1, b.length, _littleEndian);
        out.setRange(off + 5, off + 5 + b.length, b);
        off += 5 + b.length;
      case ParamValueBinary(:final value):
        final vLen = value.length;
        out[off] = _tagBinary;
        bd.setUint32(off + 1, vLen, _littleEndian);
        out.setRange(off + 5, off + 5 + vLen, value);
        off += 5 + vLen;
      case ParamValueRefCursorOut():
        out[off] = _tagRefCursorOut;
        bd.setUint32(off + 1, 0, _littleEndian);
        off += 5;
    }
  }

  return out;
}

/// Deserialises a single [ParamValue] from [data] starting at [offset] (mirrors
/// `ParamValue::deserialize` in the Rust engine). Returns the value and the
/// number of bytes consumed.
({ParamValue value, int consumed}) deserializeParamValue(
  Uint8List data, {
  int offset = 0,
}) {
  if (data.length < offset + 5) {
    throw const FormatException('ParamValue buffer too short');
  }
  final tag = data[offset];
  final len = data.buffer.asByteData().getUint32(offset + 1, _littleEndian);
  final consumed = 5 + len;
  if (data.length < offset + consumed) {
    throw const FormatException('ParamValue buffer truncated');
  }
  final start = offset + 5;
  // sublistView avoids copying the payload; the view stays valid as long as
  // the original protocol buffer is alive (held by the enclosing QueryResult).
  final payload = Uint8List.sublistView(data, start, start + len);

  final ParamValue v;
  switch (tag) {
    case _tagNull:
      v = const ParamValueNull();
    case _tagString:
      v = ParamValueString(utf8.decode(payload, allowMalformed: true));
    case _tagInteger:
      if (len != 4) {
        throw const FormatException('ParamValue::Integer expected 4 bytes');
      }
      v = ParamValueInt32(
        ByteData.sublistView(data, start, start + 4).getInt32(0, _littleEndian),
      );
    case _tagBigInt:
      if (len != 8) {
        throw const FormatException('ParamValue::BigInt expected 8 bytes');
      }
      v = ParamValueInt64(
        ByteData.sublistView(data, start, start + 8).getInt64(0, _littleEndian),
      );
    case _tagDecimal:
      v = ParamValueDecimal(utf8.decode(payload, allowMalformed: true));
    case _tagBinary:
      v = ParamValueBinary(payload);
    case _tagRefCursorOut:
      if (len != 0) {
        throw const FormatException(
          'ParamValue::RefCursorOut expected 0 length',
        );
      }
      v = const ParamValueRefCursorOut();
    default:
      throw FormatException('Unknown ParamValue tag: $tag');
  }
  return (value: v, consumed: consumed);
}

/// Deserialises every [ParamValue] in a **legacy** buffer (concatenated
/// encodings, no DRT1 header).
List<ParamValue> deserializeParamValues(Uint8List data) {
  final out = <ParamValue>[];
  var o = 0;
  while (o < data.length) {
    final r = deserializeParamValue(data, offset: o);
    out.add(r.value);
    o += r.consumed;
  }
  return out;
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
    case 'geometry':
      // We only accept WKT here (String). Binary WKB callers should
      // use SqlDataType.varBinary together with `*::STGeomFromWKB`.
      // Rejecting `List<int>` explicitly avoids silent ambiguity.
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.${type.kind} expects String (WKT); for binary WKB use '
          'SqlDataType.varBinary with STGeomFromWKB. '
          'Got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'interval_year_to_month':
      return ParamValueString(_toIntervalYearToMonthString(value));
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
    final left =
        compressedParts[0].isEmpty ? <String>[] : compressedParts[0].split(':');
    final right =
        compressedParts[1].isEmpty ? <String>[] : compressedParts[1].split(':');
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
/// payload, missing root element brackets, unbalanced tags) without
/// paying the cost of instantiating an actual parser. The engine
/// remains the source of truth for full schema/well-formedness
/// validation at execute-time.
///
/// Also caps the payload at [_xmlValidateMaxBytes] (4 MB, mirroring the
/// JSON validator) so a hostile or buggy caller can't pin a thread on
/// counting tags in a multi-gigabyte string.
void _validateXmlShape(String raw) {
  if (raw.length > _xmlValidateMaxBytes) {
    throw ArgumentError(
      'SqlDataType.xml(validate: true): payload is ${raw.length} '
      'bytes which exceeds the validation limit of $_xmlValidateMaxBytes; '
      'either pass a smaller payload or omit validate:true.',
    );
  }
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
  // Cheap balance check: count opening vs closing angle brackets.
  // Skips inside CDATA/comment sections is intentional — this is a
  // structural sanity check, not a conformance test.
  var openCount = 0;
  var closeCount = 0;
  for (var i = 0; i < s.length; i++) {
    final code = s.codeUnitAt(i);
    if (code == 0x3C) openCount++; // '<'
    if (code == 0x3E) closeCount++; // '>'
  }
  if (openCount != closeCount) {
    throw ArgumentError(
      'SqlDataType.xml(validate: true): unbalanced angle brackets '
      '(< count=$openCount, > count=$closeCount)',
    );
  }
}

/// Cap for `SqlDataType.xml(validate: true)` — same 4 MB ceiling as JSON.
/// Validation is opt-in; callers that need to send larger XML payloads
/// should disable validation and rely on the engine.
const int _xmlValidateMaxBytes = 4 * 1024 * 1024;

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

/// Formats `INTERVAL 'Y-M' YEAR TO MONTH` for ISO-style engines.
String _toIntervalYearToMonthString(Object? value) {
  if (value is String) {
    return value;
  }
  int years;
  int months;
  if (value is List<int>) {
    if (value.length != 2) {
      throw ArgumentError(
        'SqlDataType.intervalYearToMonth expects a two-element '
        'List<int> [years, months], got length ${value.length}',
      );
    }
    years = value[0];
    months = value[1];
  } else if (value is Map) {
    final y = value['years'];
    final m = value['months'];
    if (y is! int || m is! int) {
      throw ArgumentError(
        'SqlDataType.intervalYearToMonth expects Map keys "years" and '
        '"months" with int values, got ${value.runtimeType}',
      );
    }
    years = y;
    months = m;
  } else {
    throw ArgumentError(
      'SqlDataType.intervalYearToMonth expects String, List<int> of '
      'length 2, or Map with int years/months; got ${value.runtimeType}',
    );
  }
  if (months < 0 || months > 11) {
    throw ArgumentError(
      'SqlDataType.intervalYearToMonth: months must be in 0..11, got $months',
    );
  }
  return "INTERVAL '$years-$months' YEAR TO MONTH";
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
    // DoS guard: refuse to validate-parse extremely large payloads. Any JSON
    // bigger than this is almost certainly a bug or hostile input; the engine
    // will reject it anyway. Skipping validate gives the engine the chance to
    // surface the real driver-level error instead of stalling on jsonDecode.
    if (encoded.length > _jsonValidateMaxBytes) {
      throw ArgumentError(
        'SqlDataType.json(validate: true): payload is ${encoded.length} '
        'bytes which exceeds the validation limit of $_jsonValidateMaxBytes; '
        'either pass a smaller payload or omit validate:true.',
      );
    }
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

/// Cap for `SqlDataType.json(validate: true)` — 4 MB. JSON parameters above
/// this are very unusual; the cap prevents pathological deeply-nested or
/// gigantic input from forcing a multi-second parse on the calling thread.
const int _jsonValidateMaxBytes = 4 * 1024 * 1024;

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
