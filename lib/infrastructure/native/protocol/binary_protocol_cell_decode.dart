import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';
import 'package:odbc_fast/infrastructure/native/protocol/odbc_type.dart';
import 'package:odbc_fast/infrastructure/native/protocol/protocol_ascii_parse.dart';

/// Active lazy-string mode for the current parse call.
bool binaryProtocolLazyStringsActive = false;

void setBinaryProtocolLazyStrings({required bool active}) {
  binaryProtocolLazyStringsActive = active;
}

void setNullBitmapBit(Uint8List bitmap, int row) {
  final byteIndex = row >> 3;
  final bit = 1 << (row & 0x7);
  bitmap[byteIndex] |= bit;
}

/// Converts binary cell data to a Dart value based on the protocol
/// discriminant.
Object? decodeProtocolCell(Uint8List data, int odbcType) {
  final type = OdbcType.fromDiscriminant(odbcType);
  if (type == OdbcType.binary) {
    return data;
  }
  if (type == OdbcType.integer) {
    if (data.length >= 4) {
      return readInt32Le(data);
    }
    return decodeProtocolText(data);
  }
  if (type == OdbcType.bigInt) {
    if (data.length >= 8) {
      return readInt64Le(data);
    }
    return decodeProtocolText(data);
  }
  if (type == OdbcType.float || type == OdbcType.doublePrecision) {
    // Dual-support: prefer ASCII float text (incl. "Infinity"/"NaN"), then
    // 8-byte LE IEEE-754 from native cell_reader / block_fetch.
    final parsed = tryParseAsciiFloat64(data);
    if (parsed != null) {
      return parsed;
    }
    if (data.length == 8) {
      return ByteData.sublistView(data).getFloat64(0, Endian.little);
    }
    return decodeProtocolText(data);
  }
  if (type == OdbcType.boolean) {
    // Dual-support: single 0/1 byte or ASCII bool text.
    if (data.length == 1 && (data[0] == 0 || data[0] == 1)) {
      return data[0] == 1;
    }
    final parsed = tryParseAsciiBool(data);
    if (parsed != null) {
      return parsed;
    }
    return decodeProtocolText(data);
  }
  if (type == OdbcType.smallInt) {
    final parsed = tryParseAsciiInt(data);
    if (parsed != null) {
      return parsed;
    }
    return decodeProtocolText(data);
  }
  if (type == OdbcType.date ||
      type == OdbcType.timestamp ||
      type == OdbcType.timestampWithTz ||
      type == OdbcType.datetimeOffset ||
      type == OdbcType.time) {
    final parsed = tryParseAsciiDateTime(data);
    if (parsed != null) {
      return parsed;
    }
    return decodeProtocolText(data);
  }
  return decodeProtocolText(data);
}

/// Little-endian i32 without allocating a [ByteData] view.
int readInt32Le(Uint8List data, [int offset = 0]) {
  final v = data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);
  return v.toSigned(32);
}

/// Little-endian i64 without allocating a [ByteData] view.
int readInt64Le(Uint8List data, [int offset = 0]) {
  final lo = data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);
  final hi = data[offset + 4] |
      (data[offset + 5] << 8) |
      (data[offset + 6] << 16) |
      (data[offset + 7] << 24);
  return (hi.toSigned(32) << 32) | (lo & 0xFFFFFFFF);
}

Object decodeProtocolText(Uint8List data) {
  if (binaryProtocolLazyStringsActive) {
    // Shares [data]'s backing store; the parent frame must stay alive until
    // lazy cells are consumed or decoded.
    return LazyString(data);
  }
  if (isAsciiBytes(data)) {
    return String.fromCharCodes(data);
  }
  return utf8.decode(data, allowMalformed: true);
}
