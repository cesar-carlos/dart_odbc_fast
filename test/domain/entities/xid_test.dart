/// Unit tests for the Dart-side `Xid` value class — Sprint 4.3.
///
/// The Rust-side `Xid::new` validation is the source of truth for
/// the protocol contract; these tests verify that the Dart wrapper
/// enforces the same length limits before the FFI boundary so callers
/// see actionable Dart errors instead of opaque FFI return codes.
library;

import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:test/test.dart';

void main() {
  group('Xid validation', () {
    test('accepts valid components', () {
      final xid = Xid(
        formatId: 0x1B,
        gtrid: Uint8List.fromList([1, 2, 3]),
        bqual: Uint8List.fromList([4, 5]),
      );
      expect(xid.formatId, equals(0x1B));
      expect(xid.gtrid, equals([1, 2, 3]));
      expect(xid.bqual, equals([4, 5]));
    });

    test('accepts empty bqual (single-branch transactions)', () {
      final xid = Xid(formatId: 0, gtrid: Uint8List.fromList([42]));
      expect(xid.bqual, isEmpty);
    });

    test('rejects empty gtrid', () {
      expect(
        () => Xid(formatId: 0, gtrid: Uint8List(0)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('gtrid must be non-empty'),
          ),
        ),
      );
    });

    test('rejects oversize gtrid (>64 bytes)', () {
      expect(
        () => Xid(formatId: 0, gtrid: Uint8List(65)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('gtrid is 65 bytes'),
          ),
        ),
      );
    });

    test('rejects oversize bqual (>64 bytes)', () {
      expect(
        () => Xid(
          formatId: 0,
          gtrid: Uint8List.fromList([1]),
          bqual: Uint8List(65),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('bqual is 65 bytes'),
          ),
        ),
      );
    });

    test('accepts the X/Open maximum sizes (64 + 64)', () {
      final xid = Xid(
        formatId: 0,
        gtrid: Uint8List(64),
        bqual: Uint8List(64),
      );
      expect(xid.gtrid, hasLength(64));
      expect(xid.bqual, hasLength(64));
    });

    test('defensive-copies the input buffers', () {
      // Mutating the source buffer after construction must NOT
      // affect the stored XID — otherwise we'd ship mutable global
      // state through the FFI boundary.
      final source = Uint8List.fromList([1, 2, 3]);
      final xid = Xid(formatId: 0, gtrid: source);
      source[0] = 99;
      expect(xid.gtrid[0], equals(1), reason: 'Xid must own its bytes');
    });
  });

  group('Xid.fromStrings', () {
    test('UTF-8 encodes the gtrid and bqual', () {
      final xid = Xid.fromStrings(gtrid: 'order-42', bqual: 'branch-A');
      expect(xid.formatId, equals(0));
      expect(xid.gtrid, equals('order-42'.codeUnits));
      expect(xid.bqual, equals('branch-A'.codeUnits));
    });

    test('uses formatId default of 0', () {
      final xid = Xid.fromStrings(gtrid: 'g');
      expect(xid.formatId, equals(0));
      expect(xid.bqual, isEmpty);
    });

    test('honours an explicit formatId', () {
      final xid = Xid.fromStrings(gtrid: 'g', formatId: 0x1B);
      expect(xid.formatId, equals(0x1B));
    });

    test('rejects empty gtrid string', () {
      expect(
        () => Xid.fromStrings(gtrid: ''),
        throwsArgumentError,
      );
    });
  });

  group('Xid equality / hashCode', () {
    test('equal XIDs compare and hash identically', () {
      final a = Xid(
        formatId: 1,
        gtrid: Uint8List.fromList([1, 2, 3]),
        bqual: Uint8List.fromList([4]),
      );
      final b = Xid(
        formatId: 1,
        gtrid: Uint8List.fromList([1, 2, 3]),
        bqual: Uint8List.fromList([4]),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different formatId is not equal', () {
      final a = Xid(formatId: 1, gtrid: Uint8List.fromList([1]));
      final b = Xid(formatId: 2, gtrid: Uint8List.fromList([1]));
      expect(a, isNot(equals(b)));
    });

    test('different gtrid bytes are not equal', () {
      final a = Xid(formatId: 0, gtrid: Uint8List.fromList([1, 2]));
      final b = Xid(formatId: 0, gtrid: Uint8List.fromList([1, 3]));
      expect(a, isNot(equals(b)));
    });

    test('different bqual bytes are not equal', () {
      final a = Xid(
        formatId: 0,
        gtrid: Uint8List.fromList([1]),
        bqual: Uint8List.fromList([1]),
      );
      final b = Xid(
        formatId: 0,
        gtrid: Uint8List.fromList([1]),
        bqual: Uint8List.fromList([2]),
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('Xid toString', () {
    test('shows hex-encoded components', () {
      final xid = Xid(
        formatId: 27,
        gtrid: Uint8List.fromList([0xAB, 0xCD]),
        bqual: Uint8List.fromList([0x12]),
      );
      final s = xid.toString();
      expect(s, contains('formatId: 27'));
      expect(s, contains('0xabcd'));
      expect(s, contains('0x12'));
    });

    test('renders empty bqual cleanly', () {
      final xid = Xid(formatId: 0, gtrid: Uint8List.fromList([0xFF]));
      expect(xid.toString(), contains('bqual: 0x'));
    });
  });
}
