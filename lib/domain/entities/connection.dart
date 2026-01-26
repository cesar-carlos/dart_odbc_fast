class Connection {
  final String id;
  final String connectionString;
  final DateTime createdAt;
  final bool isActive;

  const Connection({
    required this.id,
    required this.connectionString,
    required this.createdAt,
    this.isActive = false,
  });

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
