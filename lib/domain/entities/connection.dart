/// Represents an active ODBC database connection.
///
/// Contains connection metadata including the unique [id], the original
/// [connectionString], creation timestamp [createdAt], and active status.
///
/// Example:
/// ```dart
/// final conn = Connection(
///   id: '1',
///   connectionString: 'DSN=MyDB',
///   createdAt: DateTime.now(),
///   isActive: true,
/// );
/// ```
class Connection {
  /// Creates a new [Connection] instance.
  ///
  /// The [id] is a unique identifier assigned by the ODBC engine.
  /// The [connectionString] is the original ODBC connection string used
  /// to establish this connection.
  const Connection({
    required this.id,
    required this.connectionString,
    required this.createdAt,
    this.isActive = false,
  });

  /// Unique connection identifier assigned by the engine.
  final String id;

  /// Original ODBC connection string used to establish this connection.
  final String connectionString;

  /// Timestamp when this connection was created.
  final DateTime createdAt;

  /// Whether this connection is currently active and ready for queries.
  final bool isActive;

  /// Creates a copy of this connection with the given fields replaced.
  ///
  /// Returns a new [Connection] instance with the same values as this one,
  /// except for the fields explicitly provided.
  Connection copyWith({
    String? id,
    String? connectionString,
    DateTime? createdAt,
    bool? isActive,
  }) {
    return Connection(
      id: id ?? this.id,
      connectionString: connectionString ?? this.connectionString,
      createdAt: createdAt ?? this.createdAt,
      isActive: isActive ?? this.isActive,
    );
  }
}
