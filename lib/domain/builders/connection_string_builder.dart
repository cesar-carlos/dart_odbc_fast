/// Fluent builder for ODBC connection strings.
///
/// Collects driver, server, port, database, credentials, and custom
/// options, then produces a semicolon-separated key=value string
/// suitable for use with the service connect method.
///
/// Use [SqlServerBuilder], [PostgreSqlBuilder], or [MySqlBuilder]
/// for vendor-specific defaults, or [ConnectionStringBuilder] for full control.
class ConnectionStringBuilder {
  ConnectionStringBuilder({
    String? driver,
    String? server,
    int? port,
    String? database,
    String? uid,
    String? pwd,
    bool trustedConnection = false,
  })  : _driver = driver,
        _server = server,
        _port = port,
        _database = database,
        _uid = uid,
        _pwd = pwd,
        _trustedConnection = trustedConnection;

  String? _driver;
  String? _server;
  int? _port;
  String? _database;
  String? _uid;
  String? _pwd;
  bool _trustedConnection;

  final Map<String, String> _options = {};

  ConnectionStringBuilder server(String value) {
    _server = value;
    return this;
  }

  ConnectionStringBuilder port(int value) {
    _port = value;
    return this;
  }

  ConnectionStringBuilder database(String value) {
    _database = value;
    return this;
  }

  ConnectionStringBuilder credentials(String user, String password) {
    _uid = user;
    _pwd = password;
    return this;
  }

  ConnectionStringBuilder trusted() {
    _trustedConnection = true;
    return this;
  }

  ConnectionStringBuilder option(String key, String value) {
    _options[key] = value;
    return this;
  }

  /// Produces an ODBC connection string (key=value;key=value;...).
  /// Only includes non-null, non-empty values.
  String build() {
    final parts = <String>[];

    void add(String key, Object? value) {
      if (value == null) return;
      final s = value.toString().trim();
      if (s.isEmpty) return;
      parts.add('$key=$s');
    }

    add('Driver', _driver);
    add('Server', _server);
    add('Port', _port);
    add('Database', _database);
    add('Uid', _uid);
    add('Pwd', _pwd);
    if (_trustedConnection) {
      parts.add('Trusted_Connection=yes');
    }
    for (final e in _options.entries) {
      add(e.key, e.value);
    }
    return parts.join(';');
  }
}

/// Builder preconfigured for SQL Server.
///
/// Default driver is `{SQL Server}`. Use [server], [database], [credentials]
/// or [trusted], and [option] for extra keys.
class SqlServerBuilder extends ConnectionStringBuilder {
  SqlServerBuilder()
      : super(driver: r'{SQL Server}');
}

/// Builder preconfigured for PostgreSQL.
///
/// Default driver is `{PostgreSQL Unicode}`. Use [server], [port], [database],
/// [credentials], and [option] for extra keys.
class PostgreSqlBuilder extends ConnectionStringBuilder {
  PostgreSqlBuilder()
      : super(driver: r'{PostgreSQL Unicode}', port: 5432);
}

/// Builder preconfigured for MySQL.
///
/// Default driver is `{MySQL ODBC 8.0 Driver}`. Use [server], [port],
/// [database], [credentials], and [option] for extra keys.
class MySqlBuilder extends ConnectionStringBuilder {
  MySqlBuilder()
      : super(driver: r'{MySQL ODBC 8.0 Driver}', port: 3306);
}
