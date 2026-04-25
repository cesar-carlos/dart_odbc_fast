import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:test/test.dart';

void main() {
  group('Connection', () {
    test('stores connection metadata', () {
      final createdAt = DateTime.utc(2026);
      final connection = Connection(
        id: 'conn-1',
        connectionString: 'DSN=Test',
        createdAt: createdAt,
        isActive: true,
      );

      expect(connection.id, 'conn-1');
      expect(connection.connectionString, 'DSN=Test');
      expect(connection.createdAt, createdAt);
      expect(connection.isActive, isTrue);
    });

    test('copyWith preserves existing values by default', () {
      final createdAt = DateTime.utc(2026);
      final connection = Connection(
        id: 'conn-1',
        connectionString: 'DSN=Test',
        createdAt: createdAt,
        isActive: true,
      );

      final copy = connection.copyWith();

      expect(copy.id, connection.id);
      expect(copy.connectionString, connection.connectionString);
      expect(copy.createdAt, connection.createdAt);
      expect(copy.isActive, connection.isActive);
    });

    test('copyWith replaces selected values', () {
      final createdAt = DateTime.utc(2026);
      final updatedAt = DateTime.utc(2026, 2);
      final connection = Connection(
        id: 'conn-1',
        connectionString: 'DSN=Test',
        createdAt: createdAt,
      );

      final copy = connection.copyWith(
        id: 'conn-2',
        connectionString: 'DSN=Other',
        createdAt: updatedAt,
        isActive: true,
      );

      expect(copy.id, 'conn-2');
      expect(copy.connectionString, 'DSN=Other');
      expect(copy.createdAt, updatedAt);
      expect(copy.isActive, isTrue);
    });
  });
}
