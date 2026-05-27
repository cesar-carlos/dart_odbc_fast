/// Unit tests for [DartSideMetrics] serialization helpers.
library;

import 'package:odbc_fast/domain/entities/dart_side_metrics.dart';
import 'package:test/test.dart';

void main() {
  group('DartSideMetrics', () {
    const sample = DartSideMetrics(
      connectionCount: 3,
      statementCount: 5,
      namedParamMetadataCount: 2,
      pooledConnectionCount: 1,
      poolCheckoutCount: 7,
      connectionOptionsCount: 4,
    );

    test('toJson should_expose_every_field_with_matching_key', () {
      final json = sample.toJson();
      expect(json, hasLength(6));
      expect(json['connectionCount'], equals(3));
      expect(json['statementCount'], equals(5));
      expect(json['namedParamMetadataCount'], equals(2));
      expect(json['pooledConnectionCount'], equals(1));
      expect(json['poolCheckoutCount'], equals(7));
      expect(json['connectionOptionsCount'], equals(4));
    });

    test('toString should_render_every_field_as_key_equals_value', () {
      final repr = sample.toString();
      expect(repr, startsWith('DartSideMetrics('));
      expect(repr, endsWith(')'));
      expect(repr, contains('connectionCount=3'));
      expect(repr, contains('statementCount=5'));
      expect(repr, contains('namedParamMetadataCount=2'));
      expect(repr, contains('pooledConnectionCount=1'));
      expect(repr, contains('poolCheckoutCount=7'));
      expect(repr, contains('connectionOptionsCount=4'));
    });

    test('toString should_join_fields_with_comma_space_separator', () {
      final repr = sample.toString();
      expect(repr.split(', ').length, greaterThanOrEqualTo(6));
    });
  });
}
