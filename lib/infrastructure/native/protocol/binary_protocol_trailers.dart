import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_constants.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_row_major.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_types.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart'
    show ParamValue, deserializeParamValue;

int parseOut1TrailerIfPresent({
  required Uint8List data,
  required int start,
  required List<ParamValue> outputs,
}) {
  if (data.length < start + 8) {
    return start;
  }
  final m = ByteData.sublistView(
    data,
    start,
    start + 4,
  ).getUint32(0, Endian.little);
  if (m != BinaryProtocolConstants.outputFooterMagic) {
    return start;
  }
  var p = start + 4;
  final n = ByteData.sublistView(data, p, p + 4).getUint32(0, Endian.little);
  p += 4;
  for (var i = 0; i < n; i++) {
    final d = deserializeParamValue(data, offset: p);
    outputs.add(d.value);
    p += d.consumed;
  }
  return p;
}

int parseRc1TrailerIfPresent({
  required Uint8List data,
  required int start,
  required List<ParsedRowBuffer> out,
}) {
  if (data.length < start + 8) {
    return start;
  }
  final m = ByteData.sublistView(
    data,
    start,
    start + 4,
  ).getUint32(0, Endian.little);
  if (m != BinaryProtocolConstants.refCursorFooterMagic) {
    return start;
  }
  var p = start + 4;
  final nCursors =
      ByteData.sublistView(data, p, p + 4).getUint32(0, Endian.little);
  p += 4;
  for (var i = 0; i < nCursors; i++) {
    if (p + 4 > data.length) {
      throw const FormatException('RC1: truncated length prefix');
    }
    final bl = ByteData.sublistView(data, p, p + 4).getUint32(0, Endian.little);
    p += 4;
    if (p + bl > data.length) {
      throw const FormatException('RC1: truncated embedded message');
    }
    final inner = Uint8List.sublistView(data, p, p + bl);
    p += bl;
    out.add(parseRowMajorV1(inner));
  }
  return p;
}
