import 'dart:typed_data';

import 'package:meta/meta.dart';

/// X/Open XA global transaction identifier.
///
/// An [Xid] uniquely identifies a distributed transaction branch on a
/// Resource Manager (RM). It carries three components:
///
/// - [formatId] — application-defined 32-bit format id (commonly `0`
///   or `0x1B`, the IBM/JTA convention).
/// - [gtrid] — global transaction id (1..64 bytes).
/// - [bqual] — branch qualifier (0..64 bytes).
///
/// All three together must be unique within the recovery set of every
/// participating RM. The defaults are aligned with the X/Open XA
/// specification — bytes can be any binary content; the FFI layer
/// hex-encodes them at the SQL boundary so the engine sees an
/// ASCII-clean identifier regardless.
///
/// Sprint 4.3 — see `engine::xa_transaction::Xid` (Rust) for the
/// canonical implementation and the engine matrix.
@immutable
class Xid {
  /// Construct a new [Xid], validating the [gtrid] / [bqual] lengths.
  ///
  /// Throws [ArgumentError] when [gtrid] is empty or longer than
  /// 64 bytes, or when [bqual] is longer than 64 bytes.
  Xid({
    required Uint8List gtrid,
    required this.formatId,
    Uint8List? bqual,
  })  : gtrid = Uint8List.fromList(gtrid),
        bqual = Uint8List.fromList(bqual ?? Uint8List(0)) {
    if (this.gtrid.isEmpty) {
      throw ArgumentError('Xid.gtrid must be non-empty (1..=64 bytes)');
    }
    if (this.gtrid.length > 64) {
      throw ArgumentError(
        'Xid.gtrid is ${this.gtrid.length} bytes; X/Open limit is 64',
      );
    }
    if (this.bqual.length > 64) {
      throw ArgumentError(
        'Xid.bqual is ${this.bqual.length} bytes; X/Open limit is 64',
      );
    }
  }

  /// Convenience constructor: build an [Xid] from string-encoded
  /// [gtrid] / [bqual]. The strings are UTF-8 encoded before going on
  /// the wire. Useful for human-readable identifiers like
  /// `'order-1234-pending'`.
  factory Xid.fromStrings({
    required String gtrid,
    int formatId = 0,
    String bqual = '',
  }) {
    return Xid(
      gtrid: Uint8List.fromList(gtrid.codeUnits),
      formatId: formatId,
      bqual: Uint8List.fromList(bqual.codeUnits),
    );
  }

  final int formatId;
  final Uint8List gtrid;
  final Uint8List bqual;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Xid) return false;
    if (formatId != other.formatId) return false;
    if (gtrid.length != other.gtrid.length) return false;
    if (bqual.length != other.bqual.length) return false;
    for (var i = 0; i < gtrid.length; i++) {
      if (gtrid[i] != other.gtrid[i]) return false;
    }
    for (var i = 0; i < bqual.length; i++) {
      if (bqual[i] != other.bqual[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        formatId,
        Object.hashAll(gtrid),
        Object.hashAll(bqual),
      );

  @override
  String toString() {
    final g = _hex(gtrid);
    final b = bqual.isEmpty ? '' : _hex(bqual);
    return 'Xid(formatId: $formatId, gtrid: 0x$g, bqual: 0x$b)';
  }

  static String _hex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
