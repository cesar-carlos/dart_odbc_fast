library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/types/sql_data_type.dart';

export 'package:odbc_fast/domain/entities/param_value.dart';
export 'package:odbc_fast/domain/types/sql_data_type.dart';

part 'param_value_wire.dart';
part 'param_value_conversion.dart';
part 'param_value_validators.dart';

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
