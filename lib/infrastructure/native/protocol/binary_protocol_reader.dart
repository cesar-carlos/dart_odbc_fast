import 'dart:convert';
import 'dart:typed_data';

const Endian binaryProtocolLittleEndian = Endian.little;

/// Internal buffer reader for parsing binary protocol data.
class BinaryProtocolBufferReader {
  BinaryProtocolBufferReader(this._data)
      : _byteData = ByteData.sublistView(_data);

  final Uint8List _data;
  final ByteData _byteData;
  int _offset = 0;

  int readUint8() => _data[_offset++];

  int readUint16() {
    final value = _byteData.getUint16(_offset, binaryProtocolLittleEndian);
    _offset += 2;
    return value;
  }

  int readUint32() {
    final value = _byteData.getUint32(_offset, binaryProtocolLittleEndian);
    _offset += 4;
    return value;
  }

  String readString(int length) {
    final bytes = Uint8List.sublistView(_data, _offset, _offset + length);
    _offset += length;
    return utf8.decode(bytes, allowMalformed: true);
  }

  Uint8List readBytes(int length) {
    final bytes = Uint8List.sublistView(_data, _offset, _offset + length);
    _offset += length;
    return bytes;
  }
}
