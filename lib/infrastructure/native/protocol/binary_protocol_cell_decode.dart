import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_reader.dart';
import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';
import 'package:odbc_fast/infrastructure/native/protocol/odbc_type.dart';

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
      return ByteData.sublistView(data).getInt32(0, binaryProtocolLittleEndian);
    }
    return decodeProtocolText(data);
  }
  if (type == OdbcType.bigInt) {
    if (data.length >= 8) {
      return ByteData.sublistView(data).getInt64(0, binaryProtocolLittleEndian);
    }
    return decodeProtocolText(data);
  }
  return decodeProtocolText(data);
}

Object decodeProtocolText(Uint8List data) {
  if (binaryProtocolLazyStringsActive) {
    // Shares [data]'s backing store; the parent frame must stay alive until
    // lazy cells are consumed or decoded.
    return LazyString(data);
  }
  if (_isAsciiBytes(data)) {
    return String.fromCharCodes(data);
  }
  return utf8.decode(data, allowMalformed: true);
}

bool _isAsciiBytes(Uint8List data) {
  for (var i = 0; i < data.length; i++) {
    if (data[i] > 0x7F) {
      return false;
    }
  }
  return true;
}
