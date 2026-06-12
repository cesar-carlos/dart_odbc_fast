part of 'bulk_insert_builder.dart';

mixin _BulkInsertWireEncode on _BulkInsertBuilderState {
  /// Builds the binary data buffer for bulk insert.
  ///
  /// Version [BulkPayloadVersion.v2] is the default and preserves
  /// variable-width binary values, including embedded NUL bytes. Use
  /// [BulkPayloadVersion.legacy] only when talking to native engines that do
  /// not understand the versioned `BLK2` payload.
  ///
  /// Uses a two-pass strategy: phase 1 pre-encodes variable-width payloads and
  /// computes the exact total byte count; phase 2 writes directly into a
  /// single pre-sized [Uint8List].
  ///
  /// Validates that table name, columns, and at least one row are present.
  /// Returns a [Uint8List] containing the serialized bulk insert data.
  ///
  /// Throws [StateError] if table name is empty, no columns are defined,
  /// no rows have been added, or a non-nullable column contains null.
  Uint8List build({BulkPayloadVersion version = BulkPayloadVersion.v2}) {
    if (_table.isEmpty) {
      throw StateError('Table name required');
    }
    if (_columns.isEmpty) {
      throw StateError('At least one column required');
    }
    if (_effectiveRowCount == 0) {
      throw StateError('At least one row required');
    }

    // Keep a final nullability check because addRow stores row references.
    // Caller code can still mutate rows after insertion.
    if (!_usesColumnar) {
      for (var c = 0; c < _columns.length; c++) {
        final spec = _columns[c];
        if (!spec.nullable) {
          for (var r = 0; r < _rows.length; r++) {
            final value = _rows[r][c];
            if (value == null) {
              _throwNullabilityError(spec.name, r + 1);
            }
          }
        }
      }
    }

    final cache = _prepareEncodeCache(version);
    final out = Uint8List(cache.totalBytes);
    final w = _WriteCursor(out);

    if (version == BulkPayloadVersion.v2) {
      w
        ..writeBytes(_bulkPayloadV2Magic)
        ..writeU16Le(_bulkPayloadV2Version)
        ..writeU16Le(_bulkPayloadV2Flags);
    }

    w
      ..writeU32Le(cache.tableBytes.length)
      ..writeBytes(cache.tableBytes)
      ..writeU32Le(_columns.length);

    for (var i = 0; i < _columns.length; i++) {
      final spec = _columns[i];
      final nameBytes = cache.columnNameBytes[i];
      w
        ..writeU32Le(nameBytes.length)
        ..writeBytes(nameBytes)
        ..writeByte(spec.tag)
        ..writeByte(spec.nullable ? 1 : 0)
        ..writeU32Le(spec.maxLen);
    }

    final rowCount = _effectiveRowCount;
    w.writeU32Le(rowCount);

    for (var c = 0; c < _columns.length; c++) {
      _writeColumn(
        w,
        version,
        _columns[c],
        c,
        rowCount,
        cache.v2VariableCells[c],
        _usesColumnar ? _columnarData[c] : null,
      );
    }

    assert(
      w.offset == cache.totalBytes,
      'bulk payload write cursor ${w.offset} != ${cache.totalBytes}',
    );
    return out;
  }

  _BulkEncodeCache _prepareEncodeCache(BulkPayloadVersion version) {
    final tableBytes = Uint8List.fromList(utf8.encode(_table));
    final columnNameBytes = _columns
        .map((spec) => Uint8List.fromList(utf8.encode(spec.name)))
        .toList(growable: false);

    var total = version == BulkPayloadVersion.v2 ? 8 : 0;
    total += 4 + tableBytes.length + 4;
    for (var i = 0; i < _columns.length; i++) {
      total += 4 + columnNameBytes[i].length + 1 + 1 + 4;
    }
    total += 4;

    final rowCount = _effectiveRowCount;
    final v2VariableCells = <List<Uint8List>?>[];
    for (var c = 0; c < _columns.length; c++) {
      total += _columnPayloadByteSize(
        version,
        _columns[c],
        c,
        rowCount,
        v2VariableCells,
      );
    }

    return _BulkEncodeCache(
      totalBytes: total,
      tableBytes: tableBytes,
      columnNameBytes: columnNameBytes,
      v2VariableCells: v2VariableCells,
    );
  }

  int _columnPayloadByteSize(
    BulkPayloadVersion version,
    BulkColumnSpec spec,
    int colIndex,
    int rowCount,
    List<List<Uint8List>?> cacheOut,
  ) {
    var size = 0;
    if (spec.nullable) {
      size += _nullBitmapSize(rowCount);
    }

    switch (spec.colType) {
      case BulkColumnType.i32:
        cacheOut.add(null);
        return size + 4 * rowCount;
      case BulkColumnType.i64:
        cacheOut.add(null);
        return size + 8 * rowCount;
      case BulkColumnType.timestamp:
        cacheOut.add(null);
        return size + 16 * rowCount;
      case BulkColumnType.text:
      case BulkColumnType.decimal:
        if (version == BulkPayloadVersion.v2) {
          final cells = <Uint8List>[];
          for (var r = 0; r < rowCount; r++) {
            final v = _cellValue(colIndex, r);
            final raw = _isCellNull(colIndex, r)
                ? Uint8List(0)
                : Uint8List.fromList(utf8.encode(v is String ? v : '$v'));
            cells.add(raw);
            size += 4 + raw.length;
          }
          cacheOut.add(cells);
          return size;
        }
        cacheOut.add(null);
        final maxLen = spec.maxLen > 0 ? spec.maxLen : 1;
        return size + maxLen * rowCount;
      case BulkColumnType.binary:
        if (version == BulkPayloadVersion.v2) {
          final cells = <Uint8List>[];
          for (var r = 0; r < rowCount; r++) {
            if (_isCellNull(colIndex, r)) {
              cells.add(Uint8List(0));
              size += 4;
              continue;
            }
            final v = _cellValue(colIndex, r);
            final raw = v is Uint8List ? v : Uint8List.fromList(v as List<int>);
            cells.add(raw);
            size += 4 + raw.length;
          }
          cacheOut.add(cells);
          return size;
        }
        cacheOut.add(null);
        final maxLen = spec.maxLen > 0 ? spec.maxLen : 1;
        return size + maxLen * rowCount;
    }
  }

  void _writeColumn(
    _WriteCursor w,
    BulkPayloadVersion version,
    BulkColumnSpec spec,
    int colIndex,
    int rowCount,
    List<Uint8List>? v2Cells,
    _ColumnarColumnData? columnar,
  ) {
    if (version == BulkPayloadVersion.v2 &&
        (spec.colType == BulkColumnType.text ||
            spec.colType == BulkColumnType.decimal ||
            spec.colType == BulkColumnType.binary)) {
      _writeColumnV2Variable(w, spec, colIndex, rowCount, v2Cells!);
      return;
    }
    _writeColumnLegacy(w, spec, colIndex, rowCount, columnar);
  }

  void _writeColumnLegacy(
    _WriteCursor w,
    BulkColumnSpec spec,
    int colIndex,
    int rowCount,
    _ColumnarColumnData? columnar,
  ) {
    final maxLen = spec.maxLen > 0 ? spec.maxLen : 1;
    List<int>? nullBitmap;
    if (spec.nullable) {
      nullBitmap = List.filled(_nullBitmapSize(rowCount), 0);
    }

    switch (spec.colType) {
      case BulkColumnType.i32:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
          }
          w.writeBytes(nullBitmap);
        }
        if (columnar is _ColumnarInt32Data && nullBitmap == null) {
          w.writeInt32List(columnar.values);
          return;
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _cellValue(colIndex, r);
          final i = _isCellNull(colIndex, r)
              ? 0
              : (v is int ? v : int.tryParse('$v') ?? 0);
          w.writeI32Le(i);
        }
      case BulkColumnType.i64:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
          }
          w.writeBytes(nullBitmap);
        }
        if (columnar is _ColumnarInt64Data && nullBitmap == null) {
          w.writeInt64List(columnar.values);
          return;
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _cellValue(colIndex, r);
          final i = _isCellNull(colIndex, r)
              ? 0
              : (v is int ? v : int.tryParse('$v') ?? 0);
          w.writeI64Le(i);
        }
      case BulkColumnType.text:
      case BulkColumnType.decimal:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
          }
          w.writeBytes(nullBitmap);
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _cellValue(colIndex, r);
          final List<int> raw;
          if (_isCellNull(colIndex, r)) {
            raw = const <int>[];
          } else if (v is String) {
            raw = utf8.encode(v);
          } else {
            raw = utf8.encode('$v');
          }
          final len = raw.length.clamp(0, maxLen);
          w.writeBytesRange(raw, 0, len);
          for (var i = len; i < maxLen; i++) {
            w.writeByte(0);
          }
        }
      case BulkColumnType.binary:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
          }
          w.writeBytes(nullBitmap);
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _cellValue(colIndex, r);
          final List<int> raw;
          if (_isCellNull(colIndex, r)) {
            raw = const <int>[];
          } else if (v is Uint8List) {
            raw = v;
          } else if (v is List<int>) {
            raw = v;
          } else {
            raw = const <int>[];
          }
          final len = raw.length.clamp(0, maxLen);
          w.writeBytesRange(raw, 0, len);
          for (var i = len; i < maxLen; i++) {
            w.writeByte(0);
          }
        }
      case BulkColumnType.timestamp:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
          }
          w.writeBytes(nullBitmap);
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _cellValue(colIndex, r);
          BulkTimestamp t;
          if (_isCellNull(colIndex, r)) {
            t = const BulkTimestamp(
              year: 0,
              month: 0,
              day: 0,
              hour: 0,
              minute: 0,
              second: 0,
            );
          } else if (v is DateTime) {
            t = BulkTimestamp.fromDateTime(v);
          } else if (v is BulkTimestamp) {
            t = v;
          } else {
            t = const BulkTimestamp(
              year: 0,
              month: 0,
              day: 0,
              hour: 0,
              minute: 0,
              second: 0,
            );
          }
          w
            ..writeI16Le(t.year)
            ..writeU16Le(t.month)
            ..writeU16Le(t.day)
            ..writeU16Le(t.hour)
            ..writeU16Le(t.minute)
            ..writeU16Le(t.second)
            ..writeU32Le(t.fraction);
        }
    }
  }

  void _writeColumnV2Variable(
    _WriteCursor w,
    BulkColumnSpec spec,
    int colIndex,
    int rowCount,
    List<Uint8List> cells,
  ) {
    List<int>? nullBitmap;
    if (spec.nullable) {
      nullBitmap = List.filled(_nullBitmapSize(rowCount), 0);
      for (var r = 0; r < rowCount; r++) {
        if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
      }
      w.writeBytes(nullBitmap);
    }

    for (var r = 0; r < rowCount; r++) {
      final raw = cells[r];
      w
        ..writeU32Le(raw.length)
        ..writeBytes(raw);
    }
  }
}
