import 'package:odbc_fast/infrastructure/native/telemetry/opentelemetry_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('OpenTelemetryFFI', () {
    late OpenTelemetryFFI ffi;

    setUp(() {
      ffi = OpenTelemetryFFI();
    });

    tearDown(() {
      try {
        ffi.shutdown();
      } catch (_) {
        // Ignore shutdown errors in tests
      }
    });

    test('should load OpenTelemetry library', () {
      expect(ffi, isNotNull);
    });

    test('should initialize OpenTelemetry with default endpoint', () {
      final result = ffi.initialize();

      expect(result, isTrue);
    });

    test('should initialize OpenTelemetry with custom endpoint', () {
      final result = ffi.initialize(
        otlpEndpoint: 'http://custom-collector:4318',
      );

      expect(result, isTrue);
    });

    test('should export trace JSON successfully', () {
      ffi.initialize();

      const traceJson = '{"trace_id":"test123","name":"test.trace"}';
      final result = ffi.exportTrace(traceJson);

      expect(result, isGreaterThanOrEqualTo(0));
    });

    test('should throw exception when exporting without initialization', () {
      // Create new instance without initialization
      final uninitializedFfi = OpenTelemetryFFI();

      expect(
        () => uninitializedFfi.exportTrace('{}'),
        throwsA(isA<Exception>()),
      );
    });

    test('should export trace to string buffer', () {
      ffi.initialize();

      final result = ffi.exportTraceToString('test');

      expect(result, isGreaterThanOrEqualTo(0));
    });

    test('should shutdown and release resources', () {
      ffi.initialize();

      expect(() => ffi.shutdown(), returnsNormally);
    });

    test('should get last error message', () {
      ffi.initialize();

      final error = ffi.getLastErrorMessage();

      expect(error, isA<String>());
    });

    test('should handle empty trace JSON', () {
      ffi.initialize();

      final result = ffi.exportTrace('{}');

      expect(result, isGreaterThanOrEqualTo(0));
    });

    test('should handle complex trace JSON', () {
      ffi.initialize();

      const complexJson = '''
      {
        "trace_id": "trace_123",
        "name": "odbc.query",
        "start_time": "2024-01-01T00:00:00.000Z",
        "end_time": "2024-01-01T00:00:01.000Z",
        "attributes": {
          "db.system": "postgresql",
          "db.name": "testdb",
          "db.statement": "SELECT * FROM users"
        }
      }
      ''';

      final result = ffi.exportTrace(complexJson);

      expect(result, isGreaterThanOrEqualTo(0));
    });

    test('should handle malformed trace JSON gracefully', () {
      ffi.initialize();

      const malformedJson = '{"trace_id": "test", "invalid": }';

      // Should return error code (non-zero) or throw
      expect(
        () => ffi.exportTrace(malformedJson),
        throwsAnything,
      );
    });

    test('should handle unicode in trace JSON', () {
      ffi.initialize();

      const unicodeJson = '{"trace_id":"test_unicøde","name":"test_öpëration"}';
      final result = ffi.exportTrace(unicodeJson);

      expect(result, isGreaterThanOrEqualTo(0));
    });

    test('should support multiple initialization calls', () {
      ffi.initialize();

      // Second initialization should be safe
      expect(() => ffi.initialize(), returnsNormally);
    });

    test('should handle shutdown without prior initialization', () {
      // Create new instance and shutdown without initialize
      final freshFfi = OpenTelemetryFFI();

      expect(freshFfi.shutdown, returnsNormally);
    });

    test('should export multiple traces in sequence', () {
      ffi.initialize();

      for (var i = 0; i < 10; i++) {
        final traceJson = '{"trace_id":"trace_$i","name":"operation_$i"}';
        final result = ffi.exportTrace(traceJson);
        expect(result, isGreaterThanOrEqualTo(0));
      }
    });
  });
}
