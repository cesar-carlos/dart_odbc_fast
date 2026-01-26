import 'dart:convert';
import 'dart:typed_data';

const int _tagNull = 0;
const int _tagString = 1;
const int _tagInteger = 2;
const int _tagBigInt = 3;
const int _tagDecimal = 4;
const int _tagBinary = 5;

List<int> _u32Le(int v) {
  final b = ByteData(4);
  b.setUint32(0, v, Endian.little);
  return b.buffer.asUint8List(0, 4).toList();
}

List<int> _i32Le(int v) {
  final b = ByteData(4);
  b.setInt32(0, v, Endian.little);
  return b.buffer.asUint8List(0, 4).toList();
}

List<int> _i64Le(int v) {
  final b = ByteData(8);
  b.setInt64(0, v, Endian.little);
  return b.buffer.asUint8List(0, 8).toList();
}

sealed class ParamValue {
  const ParamValue();

  List<int> serialize();
}

class ParamValueNull extends ParamValue {
  const ParamValueNull();

  @override
  List<int> serialize() => [_tagNull, ..._u32Le(0)];
}

class ParamValueString extends ParamValue {
  const ParamValueString(this.value);
  final String value;

  @override
  List<int> serialize() {
    final b = utf8.encode(value);
    return [_tagString, ..._u32Le(b.length), ...b];
  }
}

class ParamValueInt32 extends ParamValue {
  const ParamValueInt32(this.value);
  final int value;

  @override
  List<int> serialize() => [_tagInteger, ..._u32Le(4), ..._i32Le(value)];
}

class ParamValueInt64 extends ParamValue {
  const ParamValueInt64(this.value);
  final int value;

  @override
  List<int> serialize() => [_tagBigInt, ..._u32Le(8), ..._i64Le(value)];
}

class ParamValueDecimal extends ParamValue {
  const ParamValueDecimal(this.value);
  final String value;

  @override
  List<int> serialize() {
    final b = utf8.encode(value);
    return [_tagDecimal, ..._u32Le(b.length), ...b];
  }
}

class ParamValueBinary extends ParamValue {
  const ParamValueBinary(this.value);
  final List<int> value;

  @override
  List<int> serialize() => [_tagBinary, ..._u32Le(value.length), ...value];
}

Uint8List serializeParams(List<ParamValue> params) {
  final out = <int>[];
  for (final p in params) {
    out.addAll(p.serialize());
  }
  return Uint8List.fromList(out);
}
