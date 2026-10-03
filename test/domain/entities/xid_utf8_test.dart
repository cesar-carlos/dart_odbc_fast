import 'dart:convert';

import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:test/test.dart';

void main() {
  test('should_encode_non_ascii_identifiers_as_utf8', () {
    final xid = Xid.fromStrings(gtrid: 'éĀ😀', bqual: 'ç');
    expect(xid.gtrid, utf8.encode('éĀ😀'));
    expect(xid.bqual, utf8.encode('ç'));
    expect(
      Xid.fromStrings(gtrid: 'Ā'),
      isNot(Xid.fromStrings(gtrid: '\u0000')),
    );
  });
  test('should_validate_encoded_byte_limits', () {
    expect(Xid.fromStrings(gtrid: 'é' * 32).gtrid.length, 64);
    expect(() => Xid.fromStrings(gtrid: 'é' * 33), throwsArgumentError);
  });
  test('should_reject_unpaired_surrogates', () {
    expect(() => Xid.fromStrings(gtrid: '\uD800'), throwsArgumentError);
    expect(
      () => Xid.fromStrings(gtrid: 'valid', bqual: '\uDC00'),
      throwsArgumentError,
    );
  });
}
