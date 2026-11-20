# ODBC Fast - Rust-native ODBC for Dart

[![CI](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml)
[![E2E Multi-DB](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/e2e_multidb.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/e2e_multidb.yml)
[![codecov](https://codecov.io/gh/cesar-carlos/dart_odbc_fast/branch/main/graph/badge.svg)](https://codecov.io/gh/cesar-carlos/dart_odbc_fast)

`odbc_fast` is an ODBC data access package for Dart backed by an in-repo Rust engine over `dart:ffi`.

Current package version: **5.0.5**. See the [changelog](CHANGELOG.md) for release history and [4.x migration notes](CHANGELOG.md#500---2026-10-03).

## Installation

Use Dart 3.6 or later in the 3.x line. Install the ODBC driver for your database and configure its connection string or DSN. Windows provides the ODBC Driver Manager. On Linux, install unixODBC. See the [build guide](doc/BUILD.md) for native library resolution and source builds.

```yaml
dependencies:
  odbc_fast: ^5.0.5
```

Run `dart pub get`. Application code imports `package:odbc_fast/odbc_fast.dart`. For direct FFI access, use `package:odbc_fast/odbc_fast_native.dart`.

## Quick Start (High-level service)

For a general-purpose async application, select `OdbcUsageProfile.balanced` explicitly. Calling `initialize()` without a profile selects the synchronous legacy preset. Replace `DSN=MyDsn` with your configured connection string.

```dart
import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

void reportFailure(Object error) {
  exitCode = 1;
  if (error is OdbcError) {
    stderr.writeln('${error.code.name}: ${error.userMessage}');
  } else {
    stderr.writeln('The database operation could not be completed.');
  }
}

Future<void> main() async {
  AppLogger.initialize();
  final locator = ServiceLocator();
  try {
    locator.initialize(profile: OdbcUsageProfile.balanced);
    final service = locator.service;
    (await service.initialize()).getOrThrow();
    final connection = (await service.connect(
      'DSN=MyDsn',
      options: locator.recommendedConnectionOptions,
    )).getOrThrow();
    try {
      final result = (await locator.queryService.executeQueryParamValues(
        connection.id,
        'SELECT CAST(? AS INTEGER) AS id',
        const [ParamValueInt32(1)],
      )).getOrThrow();
      final id = result.reader().scalar<int>('id', ignoreCase: true);
      stdout.writeln('rows=${result.rowCount} id=$id');
    } finally {
      final disconnected = await service.disconnect(connection.id);
      disconnected.fold((_) {}, reportFailure);
    }
  } on Object catch (error, stackTrace) {
    reportFailure(error);
    AppLogger.severe('Database operation failed', error, stackTrace);
  } finally {
    locator.shutdown();
  }
}
```

The CLI boundary catches `getOrThrow()` failures, prints the presentation
message and keeps technical diagnostics in the logger. Disconnect is checked
separately, and shutdown runs after initialization or query failures.
Adapt the sample SELECT for your driver's dialect; connection settings stay
outside SQL parameter values. Runnable version:
[quick_start_balanced_demo.dart](example/quick_start_balanced_demo.dart).

## Choosing a query API

| Workload | API and usage |
| --- | --- |
| A bounded result consumed by row | Use `executeQueryParamValues` with bound values. Reuse one `result.reader()` for named lookups. |
| A large scan consumed by row | Process each batch from `streamQuery` before requesting more. Retaining every batch also retains its rows. |
| Processing values by column | Use `executeQueryColumnarParamValues` or `streamQueryColumnar` and resolve the typed columns once per batch. [Typed column example](example/typed_columnar_demo.dart) |
| Several result sets | Use `executeQueryMultiParamValues` for bounded results or `streamQueryMultiBatches` for incremental processing. [Multi-result batches](example/multi_result_batches_demo.dart) |
| Repeated SQL or batch writes | Prepare once and bind each set of values. For bulk inserts, send bounded batches and compare parallel execution on your own driver. [Bulk insert example](example/bulk_insert_demo.dart) |

The [performance guide](doc/PERFORMANCE.md) explains fetch sizes, worker profiles and how to measure the path your application actually uses.

## Transactions and recovery

Use the [transaction helper](example/run_in_transaction_demo.dart) for local transactions. For distributed transactions, check the driver's [XA capabilities](doc/CAPABILITIES_v3.md) before using `runInXaTransaction`. [XA example](example/xa_2pc_demo.dart)

Reconnection restores the connection for subsequent operations. Enable query replay only for operations that are safe to repeat. If a timeout or completion failure leaves `OdbcError.details.outcomeUnknown` set, reconcile the transaction outcome before retrying a write.

## Documentation

- [Runnable examples](example/README.md) for connection strings, pooling, streaming and writes
- [Type and parameter mapping](doc/notes/TYPE_MAPPING.md) and [driver capabilities](doc/CAPABILITIES_v3.md)
- [Architecture](doc/ARCHITECTURE.md), [test commands](doc/TESTING.md) and [documentation index](doc/README.md)

## Support

If this project helps you, consider supporting the maintainer via Pix:

- `cesar_carlos@msn.com`

## License

MIT (see [LICENSE](LICENSE)).
