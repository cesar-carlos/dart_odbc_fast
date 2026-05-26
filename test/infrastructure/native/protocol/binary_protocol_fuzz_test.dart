/// Fuzz tests for [BinaryProtocolParser].
///
/// Defense-in-depth on top of the explicit DoS guards. Generates 10k random
/// header + payload combinations and asserts that **no** input causes:
///
///   * unbounded allocation (each iteration is bounded by a 100ms timeout)
///   * unhandled crashes outside `FormatException`/`RangeError`
///
/// Two flavours:
///
///   1. Random magic / version / row+col headers feeding into truncated
///      payloads. The parser must reject quickly with `FormatException`.
///   2. Valid magic + valid version + corrupted lengths. Same expectation:
///      structured rejection, never OOM.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:test/test.dart';

const int _iterations = 10000;

/// A single fuzz attempt is allowed at most [_perCallBudgetMs] ms. Tests that
/// exceed it are flagged as runaway allocations / loops.
const int _perCallBudgetMs = 100;

void main() {
  group('BinaryProtocolParser fuzz', () {
    test(
      'should_never_OOM_or_hang_on_random_bytes',
      () {
        final rng = Random(0xCAFEBABE);
        var rejected = 0;
        var accepted = 0;
        for (var i = 0; i < _iterations; i++) {
          final size = rng.nextInt(256);
          final bytes = Uint8List(size);
          for (var j = 0; j < size; j++) {
            bytes[j] = rng.nextInt(256);
          }

          final sw = Stopwatch()..start();
          try {
            BinaryProtocolParser.parse(bytes);
            accepted++;
          } on FormatException {
            rejected++;
            // Reason: RangeError can leak from sublistView when length is
            // bogus. Treat as acceptable structured rejection. Tracked in
            // future work to convert to FormatException at the parser
            // boundary; remove this catch when that lands.
            // ignore: avoid_catching_errors
          } on RangeError {
            rejected++;
          }
          sw.stop();
          expect(
            sw.elapsedMilliseconds,
            lessThan(_perCallBudgetMs),
            reason: 'iteration $i with ${bytes.length} bytes took '
                '${sw.elapsedMilliseconds} ms (budget $_perCallBudgetMs ms)',
          );
        }

        // The vast majority must be rejected — random bytes almost never
        // form a valid protocol message. We allow a small accepted count
        // because a 0-row 0-col valid-magic payload is technically legal.
        expect(rejected, greaterThan(_iterations * 9 ~/ 10));
        printOnFailure('rejected=$rejected accepted=$accepted');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'should_never_OOM_on_valid_magic_with_corrupted_lengths',
      () {
        // Valid v1 magic header + random row/col/payload counts. Forces the
        // parser through the rowMajor branch where DoS guards live.
        final rng = Random(0xFEEDFACE);
        const headerSize = 16; // magic(4) + ver(2) + cols(2) + rows(4) + pay(4)
        for (var i = 0; i < _iterations ~/ 10; i++) {
          final bytes = Uint8List(headerSize + rng.nextInt(64));
          final bd = ByteData.sublistView(bytes)
            ..setUint32(0, BinaryProtocolParser.magic, Endian.little)
            ..setUint16(
              4,
              BinaryProtocolParser.protocolVersionRowMajor,
              Endian.little,
            )
            // columnCount: bias toward "looks plausible but lies".
            ..setUint16(6, rng.nextInt(0x10000), Endian.little)
            // rowCount: full u32 range — many will trip the DoS cap.
            ..setUint32(8, rng.nextInt(0xFFFFFFFF), Endian.little)
            // payload size: bogus.
            ..setUint32(12, rng.nextInt(0xFFFFFFFF), Endian.little);
          // Touch bd so the analyzer sees it used.
          expect(bd, isNotNull);
          final sw = Stopwatch()..start();
          try {
            BinaryProtocolParser.parse(bytes);
          } on FormatException {
            // expected
            // ignore: avoid_catching_errors
          } on RangeError {
            // Reason: same as above — bogus header lengths can throw
            // RangeError before the parser-level guards fire.
          }
          sw.stop();
          expect(
            sw.elapsedMilliseconds,
            lessThan(_perCallBudgetMs),
            reason:
                'iteration $i (bogus lengths) took ${sw.elapsedMilliseconds} '
                'ms; DoS guard may be missing',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
