import 'dart:convert';
import 'dart:typed_data';

/// Returns true when every byte is ASCII (≤ 0x7F).
bool isAsciiBytes(Uint8List data) {
  for (var i = 0; i < data.length; i++) {
    if (data[i] > 0x7F) {
      return false;
    }
  }
  return true;
}

/// Parses UTF-8 float text without allocating a [String] on the ASCII path.
///
/// Falls back to `utf8.decode` + [double.tryParse] for non-ASCII or formats
/// the fast path does not cover. Returns null when parsing fails.
double? tryParseAsciiFloat64(Uint8List data) {
  if (data.isEmpty) {
    return null;
  }
  if (!isAsciiBytes(data)) {
    final text = utf8.decode(data, allowMalformed: true);
    return double.tryParse(text);
  }
  // Trim ASCII whitespace.
  var start = 0;
  var end = data.length;
  while (start < end && _isAsciiSpace(data[start])) {
    start++;
  }
  while (end > start && _isAsciiSpace(data[end - 1])) {
    end--;
  }
  if (start >= end) {
    return null;
  }
  final special = _tryParseAsciiFloatSpecial(data, start, end);
  if (special != null) {
    return special;
  }
  // Delegate to double.tryParse on a temporary Latin-1/ASCII string without
  // UTF-8 scanning — fromCharCodes is cheaper than utf8.decode for ASCII.
  return double.tryParse(
    String.fromCharCodes(data, start, end),
  );
}

double? _tryParseAsciiFloatSpecial(Uint8List data, int start, int end) {
  final len = end - start;
  if (len == 3 || len == 4) {
    final s = String.fromCharCodes(data, start, end).toLowerCase();
    if (s == 'nan') {
      return double.nan;
    }
    if (s == 'inf' || s == '+inf') {
      return double.infinity;
    }
    if (s == '-inf') {
      return double.negativeInfinity;
    }
  }
  return null;
}

bool _isAsciiSpace(int b) => b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d;

/// Parses wire bool text (`0`/`1`/`true`/`false`) from bytes when possible.
bool? tryParseAsciiBool(Uint8List data) {
  if (data.isEmpty) {
    return null;
  }
  if (!isAsciiBytes(data)) {
    return null;
  }
  var start = 0;
  var end = data.length;
  while (start < end && _isAsciiSpace(data[start])) {
    start++;
  }
  while (end > start && _isAsciiSpace(data[end - 1])) {
    end--;
  }
  final len = end - start;
  if (len == 1) {
    final c = data[start];
    if (c == 0x30) {
      return false; // '0'
    }
    if (c == 0x31) {
      return true; // '1'
    }
  }
  if (len == 4) {
    // true
    if (data[start] == 0x74 || data[start] == 0x54) {
      final a = data[start + 1] | 0x20;
      final b = data[start + 2] | 0x20;
      final c = data[start + 3] | 0x20;
      if (a == 0x72 && b == 0x75 && c == 0x65) {
        return true;
      }
    }
  }
  if (len == 5) {
    // false
    if (data[start] == 0x66 || data[start] == 0x46) {
      final a = data[start + 1] | 0x20;
      final b = data[start + 2] | 0x20;
      final c = data[start + 3] | 0x20;
      final d = data[start + 4] | 0x20;
      if (a == 0x61 && b == 0x6c && c == 0x73 && d == 0x65) {
        return false;
      }
    }
  }
  return null;
}

/// Parses a short ASCII integer (SMALLINT / textual int) without a String
/// when possible. Returns null on failure.
int? tryParseAsciiInt(Uint8List data) {
  if (data.isEmpty || !isAsciiBytes(data)) {
    return null;
  }
  var start = 0;
  var end = data.length;
  while (start < end && _isAsciiSpace(data[start])) {
    start++;
  }
  while (end > start && _isAsciiSpace(data[end - 1])) {
    end--;
  }
  if (start >= end) {
    return null;
  }
  var i = start;
  var negative = false;
  if (data[i] == 0x2d) {
    // '-'
    negative = true;
    i++;
    if (i >= end) {
      return null;
    }
  } else if (data[i] == 0x2b) {
    // '+'
    i++;
    if (i >= end) {
      return null;
    }
  }
  var value = 0;
  var anyDigit = false;
  for (; i < end; i++) {
    final c = data[i];
    if (c < 0x30 || c > 0x39) {
      return null;
    }
    anyDigit = true;
    value = value * 10 + (c - 0x30);
  }
  if (!anyDigit) {
    return null;
  }
  return negative ? -value : value;
}

/// Fast-path parse for common SQL / ISO datetime ASCII forms.
///
/// Accepts `YYYY-MM-DD`, `YYYY-MM-DD[ T]HH:MM:SS[.fraction]`, and optional
/// trailing `Z`. Returns null when the pattern does not match (caller falls
/// back to [DateTime.tryParse]).
DateTime? tryParseAsciiDateTime(Uint8List data) {
  if (data.isEmpty || !isAsciiBytes(data)) {
    return null;
  }
  var start = 0;
  var end = data.length;
  while (start < end && _isAsciiSpace(data[start])) {
    start++;
  }
  while (end > start && _isAsciiSpace(data[end - 1])) {
    end--;
  }
  final len = end - start;
  if (len < 10) {
    return null;
  }
  // Normalize space separator to 'T' via fromCharCodes for tryParse when
  // the shape looks like a datetime; for pure date use direct fields.
  if (!_looksLikeAsciiDatePrefix(data, start)) {
    return null;
  }
  if (len == 10) {
    final y = _readAsciiDigits(data, start, 4);
    final mo = _readAsciiDigits(data, start + 5, 2);
    final d = _readAsciiDigits(data, start + 8, 2);
    if (y == null || mo == null || d == null) {
      return null;
    }
    if (data[start + 4] != 0x2d || data[start + 7] != 0x2d) {
      return null;
    }
    return DateTime(y, mo, d);
  }
  // Build the string without allocating a List<int> intermediate buffer.
  // When the separator at position 10 is a space, split around it; otherwise
  // convert the slice directly. DateTime.tryParse accepts ISO-8601 with 'T'.
  if (data[start + 10] == 0x20) {
    return DateTime.tryParse(
      '${String.fromCharCodes(data, start, start + 10)}'
      'T'
      '${String.fromCharCodes(data, start + 11, start + len)}',
    );
  }
  return DateTime.tryParse(String.fromCharCodes(data, start, start + len));
}

bool _looksLikeAsciiDatePrefix(Uint8List data, int start) {
  for (var i = 0; i < 4; i++) {
    final c = data[start + i];
    if (c < 0x30 || c > 0x39) {
      return false;
    }
  }
  return data[start + 4] == 0x2d;
}

int? _readAsciiDigits(Uint8List data, int offset, int count) {
  var v = 0;
  for (var i = 0; i < count; i++) {
    final c = data[offset + i];
    if (c < 0x30 || c > 0x39) {
      return null;
    }
    v = v * 10 + (c - 0x30);
  }
  return v;
}
