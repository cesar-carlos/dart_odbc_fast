# [REQ-005] Request Options Per Call

**Type**: `Feature`
**Priority**: `P1`
**Phase**: `Phase 1`
**Scope**: `Core`

### Description
Currently, timeout and buffer settings are global per connection. This limits fine-grained control and can lead to unexpected behavior in concurrent scenarios. Need to support per-request options similar to mssql package.

### Context
The mssql npm package supports per-request configuration through its Request class. Our current implementation only allows setting these options at connection level, which affects all queries indiscriminately. This prevents users from having fine-grained control over query execution.

### Problem
- Cannot set different timeouts for specific long-running queries
- Cannot control buffer size per request
- Global timeout affects all queries equally, even short ones
- Unexpected behavior when multiple queries run concurrently on same connection
- Difficult to optimize per-request based on query characteristics

### Solution
Add an optional `RequestOptions` parameter to relevant query methods with properties:
- `timeoutMs`: Override connection timeout for this specific request (0 = use connection default)
- `maxBufferSize`: Maximum buffer size in bytes for this request result
- `stream`: Enable/disable streaming for this specific request

### API Changes
```dart
// Domain entity
class RequestOptions {
  final int? timeoutMs;
  final int? maxBufferSize;
  final bool? stream;
}

// Service methods (before)
Future<Result<QueryResult>> executeQuery(
  String connectionId,
  String sql,
) async => _repository.executeQuery(connectionId, sql);

// Service methods (after)
Future<Result<QueryResult>> executeQuery(
  String connectionId,
  String sql,
  RequestOptions? options, // NEW
) async => _repository.executeQuery(connectionId, sql, options);
```

### Criteria
- [x] RequestOptions entity created in domain
- [x] Service methods accept optional options parameter
- [x] Repository methods accept options parameter
- [x] Tests pass with various timeout/buffer configurations
- [x] Documentation updated
- [x] No breaking changes to existing API

### Related Files
- `lib/domain/entities/request_options.dart` (new)
- `lib/application/services/odbc_service.dart` (modified)
- `lib/infrastructure/repositories/odbc_repository_impl.dart` (modified)
- `lib/domain/repositories/odbc_repository.dart` (interface modified)
- `native/odbc_engine/src/ffi/*.rs` (modified)
- `doc/issues/api/requests.md` (updated)

### References
- [mssql package - Requests](https://www.npmjs.com/package/mssql#requests)
- [Issue REQ-005 in doc/issues](../../../doc/issues/api/requests.md)

---

**Last updated**: 2026-02-11

