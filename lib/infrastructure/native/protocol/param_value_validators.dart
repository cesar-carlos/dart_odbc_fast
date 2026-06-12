part of 'param_value.dart';

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
