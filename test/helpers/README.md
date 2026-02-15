# Test Helpers

Utility functions for writing database-agnostic tests.

## Database Detection

The test suite now supports automatic database detection and conditional test execution based on the database type.

### Usage

#### Skip tests on specific databases

```dart
import 'package:test/test.dart';
import '../helpers/load_env.dart';

test(
  'savepoint release',
  () async {
    // Test code...
  },
  skip: skipIfDatabase(
    [DatabaseType.sqlServer],
    reason: 'SQL Server does not support RELEASE SAVEPOINT syntax',
  ),
);
```

#### Run tests only on specific databases

```dart
test(
  'PostgreSQL-specific feature',
  () async {
    // Test code...
  },
  skip: skipUnlessDatabase(
    [DatabaseType.postgresql, DatabaseType.oracle],
    reason: 'Feature only available on PostgreSQL and Oracle',
  ),
);
```

#### Manual database type checking

```dart
test('conditional behavior', () async {
  if (isDatabaseType([DatabaseType.sqlServer])) {
    // SQL Server-specific assertions
  } else if (isDatabaseType([DatabaseType.postgresql])) {
    // PostgreSQL-specific assertions
  }
});
```

### Supported Database Types

- `DatabaseType.sqlServer` - Microsoft SQL Server
- `DatabaseType.postgresql` - PostgreSQL
- `DatabaseType.mysql` - MySQL / MariaDB
- `DatabaseType.oracle` - Oracle Database
- `DatabaseType.sqlite` - SQLite
- `DatabaseType.unknown` - Unrecognized or not detected

### How Detection Works

The database type is detected by parsing the `ODBC_TEST_DSN` connection string from the `.env` file. The detection looks for driver name patterns in the DSN:

```dart
// SQL Server examples
'Driver={SQL Server Native Client 11.0};Server=localhost'
'Driver={ODBC Driver 17 for SQL Server};Server=localhost'

// PostgreSQL examples
'Driver={PostgreSQL Unicode};Server=localhost'
'Driver={PostgreSQL ANSI};Server=localhost'

// MySQL examples
'Driver={MySQL ODBC 8.0 Driver};Server=localhost'

// Oracle examples
'Driver={Oracle ODBC Driver};Server=localhost'
```

### Helper Functions

#### `detectDatabaseType(String? connectionString) -> DatabaseType`

Detects the database type from a connection string.

#### `getTestDatabaseType() -> DatabaseType`

Gets the database type from the test environment (`ODBC_TEST_DSN`).

#### `isDatabaseType(List<DatabaseType> types) -> bool`

Returns true if the current test database is one of the specified types.

#### `skipIfDatabase(List<DatabaseType> skipFor, {String? reason}) -> String?`

Returns a skip reason if the test should be skipped for the current database.

#### `skipUnlessDatabase(List<DatabaseType> onlyFor, {String? reason}) -> String?`

Returns a skip reason if the test should ONLY run on specific databases.

### Example: Database-Specific Feature Test

```dart
import 'package:test/test.dart';
import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Database-Specific Features', () {
    test(
      'JSON functions',
      () async {
        // Test JSON support...
      },
      skip: skipUnlessDatabase(
        [DatabaseType.postgresql, DatabaseType.mysql],
        reason: 'JSON functions only in PostgreSQL/MySQL',
      ),
    );

    test(
      'XML parsing',
      () async {
        // Test XML support...
      },
      skip: skipIfDatabase(
        [DatabaseType.sqlite],
        reason: 'SQLite does not support native XML',
      ),
    );

    test('common SQL operations', () async {
      // This test runs on all databases
      final result = await service.executeQuery(
        connectionId,
        'SELECT 1 AS test_col',
      );
      expect(result.isSuccess(), isTrue);
    });
  });
}
```

## Other Helpers

### `loadTestEnv()`

Loads environment variables from `.env` file for testing.

### `getTestEnv(String key) -> String?`

Gets a test environment variable value.

### `isE2eEnabled() -> bool`

Returns true if end-to-end tests are enabled (`ENABLE_E2E_TESTS=1`).

### `runSkippedTests -> bool`

Returns true when `RUN_SKIPPED_TESTS=1` (or `true`/`yes`). When true, the 10 normally-skipped tests (slow integration, stress, native-assets) run. Use for CI or local validation: `RUN_SKIPPED_TESTS=1 dart test`.

### `kInvalidConnectionId`

Constant for an invalid connection ID (999) used in tests.

