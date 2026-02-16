# Reliability and Performance Improvements Plan

## Table of Contents

- [Overview](#overview) - Executive summary and completion status
- [Phase 0 - Baseline and analysis](#phase-0---baseline-and-analysis) ✅
- [Phase 1 - High priority performance fixes](#phase-1---high-priority-performance-fixes)
- [Phase 2 - High priority reliability fixes](#phase-2---high-priority-reliability-fixes)
- [Phase 3 - Medium priority enhancements](#phase-3---medium-priority-enhancements)
- [Phase 4 - Documentation and testing](#phase-4---documentation-and-testing)
- [Definition of Done](#definition-of-done)

---

## Overview

**Status:** 🔄 PLANNED

This plan implements reliability and performance improvements identified during
codebase analysis, building upon the completed NULL handling implementation.

**Implementation Overview:**

- Phase 0: Baseline and analysis ✅
- Phase 1: High priority performance fixes
- Phase 2: High priority reliability fixes
- Phase 3: Medium priority enhancements
- Phase 4: Documentation and testing

**Expected Outcomes:**

- Reduced memory allocations in parameter serialization
- Fail-fast validation with better error messages
- Improved bulk insert performance
- Enhanced type safety and edge case handling

---

## Phase 0 - Baseline and analysis

### Tasks

- [x] P0.1 Analyze current implementation in `param_value.dart`
- [x] P0.2 Analyze current implementation in `bulk_insert_builder.dart`
- [x] P0.3 Identify allocation hotspots and optimization opportunities
- [x] P0.4 Document findings in detailed plan

### Validation

- ✅ Code review completed
- ✅ Performance bottlenecks identified
- ✅ Reliability gaps documented

### Phase 0 Notes

**Key Findings:**

1. **Allocation overhead in serialization helpers:**
   - Each `_u32Le()`, `_i32Le()`, etc. creates new `ByteData` + `List`
   - Double allocation for each primitive conversion
   - Opportunity: Use `Uint8List` with `ByteData.view()` directly

2. **Row copy in `addRow()`:**
   - `List<dynamic>.from(values)` creates unnecessary copy
   - Can trust caller immutability or document expectations

3. **Validation timing:**
   - Column length check in `addRow()` but nullability in `build()`
   - Inconsistent fail-fast behavior
   - Opportunity: Move all validation to `build()` with batch errors

4. **String interpolation in error messages:**
   - Complex error messages built with string interpolation
   - Opportunity: Use `StringBuffer` for better performance

5. **Type conversion edge cases:**
   - `double.toString()` may vary by locale
   - No validation for `NaN`, `Infinity`
   - No explicit `DateTime` range validation

---

## Phase 1 - High priority performance fixes

### 1.1 - Reduce allocation overhead in serialization helpers

**Files:** `lib/infrastructure/native/protocol/param_value.dart`

**Current Issue:**

```dart
List<int> _u32Le(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return b.buffer.asUint8List(0, 4).toList();  // Double allocation
}
```

**Target:**

```dart
List<int> _u32Le(int v) {
  final buffer = Uint8List(4);
  final byteData = ByteData.view(buffer.buffer);
  byteData.setUint32(0, v, Endian.little);
  return buffer;
}
```

**Expected Impact:**

- ~50% reduction in allocations for primitive serialization
- Faster bulk insert operations

**Tasks:**

- [ ] P1.1.1 Refactor `_u32Le()` to use `Uint8List` + `ByteData.view()`
- [ ] P1.1.2 Refactor `_i32Le()` to use `Uint8List` + `ByteData.view()`
- [ ] P1.1.3 Refactor `_i64Le()` to use `Uint8List` + `ByteData.view()`
- [ ] P1.1.4 Refactor `_u16Le()` to use `Uint8List` + `ByteData.view()`
- [ ] P1.1.5 Refactor `_i16Le()` to use `Uint8List` + `ByteData.view()`
- [ ] P1.1.6 Apply same pattern to `bulk_insert_builder.dart` helpers
- [ ] P1.1.7 Update tests to verify behavior unchanged
- [ ] P1.1.8 Run benchmarks to measure improvement

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests pass
- ✅ Benchmark shows measurable improvement

---

### 1.2 - Remove unnecessary row copy in addRow()

**Files:** `lib/infrastructure/native/protocol/bulk_insert_builder.dart`

**Current Issue:**

```dart
BulkInsertBuilder addRow(List<dynamic> values) {
  // ... validation ...
  _rows.add(List<dynamic>.from(values));  // Unnecessary copy
  return this;
}
```

**Target:**

```dart
BulkInsertBuilder addRow(List<dynamic> values) {
  // ... validation ...
  _rows.add(values);  // Store reference directly
  return this;
}
```

**Documentation Update:**

```dart
/// Adds a row of data to bulk insert.
///
/// The [values] list must contain values in the same order as columns
/// were added, and must match the column count.
///
/// **Note:** The builder takes ownership of the [values] list and may
/// mutate it internally. Do not modify the list after passing it to
/// this method.
///
/// Returns this builder for method chaining.
```

**Expected Impact:**

- Reduced memory usage for large bulk inserts
- Faster `addRow()` operations

**Tasks:**

- [ ] P1.2.1 Remove `List<dynamic>.from(values)` call
- [ ] P1.2.2 Add documentation about list ownership
- [ ] P1.2.3 Update tests to not reuse lists after `addRow()`
- [ ] P1.2.4 Run tests to verify no regressions
- [ ] P1.2.5 Profile memory usage improvement

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests pass
- ✅ Memory profile shows reduction

---

### 1.3 - Cache endianness constant

**Files:** `lib/infrastructure/native/protocol/*.dart`

**Current Issue:**

```dart
// Creates new Endian object on every call
setUint32(0, v, Endian.little);
```

**Target:**

```dart
const _littleEndian = Endian.little;

setUint32(0, v, _littleEndian);
```

**Expected Impact:**

- Small but measurable performance improvement
- Reduced object allocations

**Tasks:**

- [ ] P1.3.1 Add `_littleEndian` constant to all protocol files
- [ ] P1.3.2 Replace all `Endian.little` with constant
- [ ] P1.3.3 Run tests to verify no regressions

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests pass

---

## Phase 2 - High priority reliability fixes

### 2.1 - Move nullability validation to addRow()

**Files:** `lib/infrastructure/native/protocol/bulk_insert_builder.dart`

**Current Issue:**

```dart
// Nullability validation only in build()
void build() {
  // Validate nullability after all rows added
  for (var c = 0; c < _columns.length; c++) {
    // ... validation
  }
}
```

**Target:**

```dart
// Fail-fast validation in addRow()
BulkInsertBuilder addRow(List<dynamic> values) {
  // Validate row length
  if (values.length != _columns.length) {
    throw ArgumentError(
      'Row length ${values.length} != column count ${_columns.length}',
    );
  }

  // Validate nullability for non-nullable columns
  for (var i = 0; i < values.length; i++) {
    final value = values[i];
    if (value == null && !_columns[i].nullable) {
      throw StateError(
        'Column "${_columns[i].name}" is non-nullable but contains null '
        'at row ${_rows.length + 1}. '
        'Use nullable: true for columns that should accept null.',
      );
    }
  }

  _rows.add(values);
  return this;
}
```

**Optional:** Add flag to defer validation

```dart
final bool validateOnAddRow;

BulkInsertBuilder({this.validateOnAddRow = true});

BulkInsertBuilder addRow(List<dynamic> values) {
  if (validateOnAddRow) {
    // ... validation
  }
  // ...
}
```

**Expected Impact:**

- Fail-fast behavior for nullability errors
- Easier debugging with immediate error location
- Optional: Better performance for bulk operations

**Tasks:**

- [ ] P2.1.1 Add nullability validation to `addRow()`
- [ ] P2.1.2 Remove nullability validation from `build()` (or keep as final check)
- [ ] P2.1.3 Update tests to verify fail-fast behavior
- [ ] P2.1.4 Update error messages to show correct row number
- [ ] P2.1.5 Optional: Add `validateOnAddRow` flag
- [ ] P2.1.6 Optional: Add tests for deferred validation mode

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests pass
- ✅ Error messages show correct row number

---

### 2.2 - Add type validation per column

**Files:** `lib/infrastructure/native/protocol/bulk_insert_builder.dart`

**Current Issue:**

- No type checking when adding rows
- Can place `String` in `i32` column, etc.
- Only fails at serialization or database level

**Target:**

```dart
/// Validates value matches expected column type.
void _validateValueForColumn(dynamic value, BulkColumnSpec spec) {
  if (value == null && spec.nullable) return;
  if (value == null) {
    throw StateError(
      'Column "${spec.name}" is non-nullable but contains null.',
    );
  }

  switch (spec.colType) {
    case BulkColumnType.i32:
      if (value is! int || value < -0x80000000 || value > 0x7FFFFFFF) {
        throw ArgumentError(
          'Column "${spec.name}" expects i32 value but got $value '
          '(${value.runtimeType})',
        );
      }
      break;
    case BulkColumnType.i64:
      if (value is! int) {
        throw ArgumentError(
          'Column "${spec.name}" expects i64 value but got $value '
          '(${value.runtimeType})',
        );
      }
      break;
    case BulkColumnType.text:
      if (value is! String) {
        throw ArgumentError(
          'Column "${spec.name}" expects text value but got $value '
          '(${value.runtimeType})',
        );
      }
      if (spec.maxLen > 0 && value.length > spec.maxLen) {
        throw ArgumentError(
          'Column "${spec.name}" exceeds max length ${spec.maxLen} '
          '(got ${value.length})',
        );
      }
      break;
    case BulkColumnType.decimal:
      if (value is! String) {
        throw ArgumentError(
          'Column "${spec.name}" expects decimal string but got $value '
          '(${value.runtimeType})',
        );
      }
      break;
    case BulkColumnType.binary:
      if (value is! List<int>) {
        throw ArgumentError(
          'Column "${spec.name}" expects binary data but got $value '
          '(${value.runtimeType})',
        );
      }
      break;
    case BulkColumnType.timestamp:
      if (value is! BulkTimestamp) {
        throw ArgumentError(
          'Column "${spec.name}" expects timestamp but got $value '
          '(${value.runtimeType})',
        );
      }
      break;
  }
}
```

**Usage in `addRow()`:**

```dart
for (var i = 0; i < values.length; i++) {
  _validateValueForColumn(values[i], _columns[i]);
}
```

**Expected Impact:**

- Better type safety
- Clearer error messages
- Earlier error detection

**Tasks:**

- [ ] P2.2.1 Implement `_validateValueForColumn()` helper
- [ ] P2.2.2 Call validation in `addRow()`
- [ ] P2.2.3 Add tests for type validation errors
- [ ] P2.2.4 Update documentation with validation behavior
- [ ] P2.2.5 Optional: Add flag to disable type validation

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests pass
- ✅ Type errors caught at `addRow()` time

---

## Phase 3 - Medium priority enhancements

### 3.1 - Remove unnecessary null bitmap boundary check

**Files:** `lib/infrastructure/native/protocol/bulk_insert_builder.dart`

**Current Issue:**

```dart
void _setNullAt(List<int> bitmap, int row) {
  final byteIndex = row ~/ 8;
  if (byteIndex >= bitmap.length) return;  // Unnecessary if pre-sized
  bitmap[byteIndex] |= 1 << (row % 8);
}
```

**Target:**

```dart
void _setNullAt(List<int> bitmap, int row) {
  final byteIndex = row ~/ 8;
  final bitMask = 1 << (row % 8);
  bitmap[byteIndex] |= bitMask;
}
```

**Expected Impact:**

- Small performance improvement
- Cleaner code

**Tasks:**

- [ ] P3.1.1 Remove boundary check from `_setNullAt()`
- [ ] P3.1.2 Add comment explaining pre-sizing guarantee
- [ ] P3.1.3 Run tests to verify no regressions

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests pass

---

### 3.2 - Improve double to decimal conversion

**Files:** `lib/infrastructure/native/protocol/param_value.dart`

**Current Issue:**

```dart
if (value is double) {
  return ParamValueDecimal(value.toString());  // Locale-dependent
}
```

**Target:**

```dart
if (value is double) {
  if (value.isNaN) {
    throw ArgumentError(
      'Double value is NaN. Cannot convert to decimal. '
      'Use explicit ParamValue with desired representation.',
    );
  }
  if (value.isInfinite) {
    throw ArgumentError(
      'Double value is ${value.isNegative ? '-Infinity' : 'Infinity'}. '
      'Cannot convert to decimal. '
      'Use explicit ParamValue with desired representation.',
    );
  }
  return ParamValueDecimal(value.toStringAsFixed(6)); // Configurable precision
}
```

**Expected Impact:**

- Consistent decimal representation
- Better error messages for edge cases
- Configurable precision

**Tasks:**

- [ ] P3.2.1 Add validation for `NaN` and `Infinity`
- [ ] P3.2.2 Use `toStringAsFixed()` for consistent output
- [ ] P3.2.3 Add tests for double edge cases
- [ ] P3.2.4 Document precision behavior

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests pass
- ✅ Edge cases handled correctly

---

### 3.3 - Add DateTime range validation

**Files:** `lib/infrastructure/native/protocol/param_value.dart`

**Current Issue:**

```dart
if (value is DateTime) {
  return ParamValueString(value.toUtc().toIso8601String());
  // No validation for invalid dates
}
```

**Target:**

```dart
if (value is DateTime) {
  if (value.year < 1 || value.year > 9999) {
    throw ArgumentError(
      'DateTime year must be between 1 and 9999, got ${value.year}.',
    );
  }
  if (value.month < 1 || value.month > 12) {
    throw ArgumentError(
      'DateTime month must be between 1 and 12, got ${value.month}.',
    );
  }
  if (value.day < 1 || value.day > 31) {
    throw ArgumentError(
      'DateTime day must be between 1 and 31, got ${value.day}.',
    );
  }
  if (value.hour < 0 || value.hour > 23) {
    throw ArgumentError(
      'DateTime hour must be between 0 and 23, got ${value.hour}.',
    );
  }
  if (value.minute < 0 || value.minute > 59) {
    throw ArgumentError(
      'DateTime minute must be between 0 and 59, got ${value.minute}.',
    );
  }
  if (value.second < 0 || value.second > 59) {
    throw ArgumentError(
      'DateTime second must be between 0 and 59, got ${value.second}.',
    );
  }
  return ParamValueString(value.toUtc().toIso8601String());
}
```

**Expected Impact:**

- Better error detection for invalid dates
- Clearer error messages

**Tasks:**

- [ ] P3.3.1 Add DateTime range validation
- [ ] P3.3.2 Add tests for invalid DateTime values
- [ ] P3.3.3 Document valid DateTime ranges

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests pass
- ✅ Invalid dates caught with clear errors

---

### 3.4 - Add Unicode/string validation

**Files:** `lib/infrastructure/native/protocol/bulk_insert_builder.dart`

**Current Issue:**

```dart
// No validation for:
// - Invalid UTF-8 sequences
// - Strings exceeding maxLen
// - Unicode edge cases
```

**Target:**

```dart
/// Validates string value for text column.
void _validateTextColumn(String value, BulkColumnSpec spec) {
  // Check max length
  if (spec.maxLen > 0 && value.length > spec.maxLen) {
    throw ArgumentError(
      'Column "${spec.name}" exceeds max length ${spec.maxLen} '
      '(got ${value.length} characters)',
    );
  }

  // Check UTF-8 encoded length
  final utf8Bytes = utf8.encode(value);
  if (spec.maxLen > 0 && utf8Bytes.length > spec.maxLen) {
    throw ArgumentError(
      'Column "${spec.name}" UTF-8 encoding exceeds max length '
      '${spec.maxLen} (got ${utf8Bytes.length} bytes)',
    );
  }
}
```

**Expected Impact:**

- Better validation for text columns
- Clearer error messages for encoding issues

**Tasks:**

- [ ] P3.4.1 Implement `_validateTextColumn()` helper
- [ ] P3.4.2 Add validation in `addRow()` for text columns
- [ ] P3.4.3 Add tests for Unicode edge cases (emoji, combining chars)
- [ ] P3.4.4 Add tests for max length validation

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests pass
- ✅ Unicode edge cases handled

---

### 3.5 - Use StringBuffer for complex error messages

**Files:** `lib/infrastructure/native/protocol/param_value.dart`

**Current Issue:**

```dart
throw ArgumentError(
  'Unsupported parameter type: ${value.runtimeType}. '
  'Expected one of: null, int, String, List<int>, bool, double, DateTime, '
  'or ParamValue. '
  'Use explicit ParamValue wrapper if needed, e.g., '
  'ParamValueString(value) for custom string conversion.',
);
```

**Target:**

```dart
throw ArgumentError(
  StringBuffer()
    ..write('Unsupported parameter type: ')
    ..write(value.runtimeType)
    ..write('. Expected one of: null, int, String, List<int>, bool, double, DateTime, or ParamValue. ')
    ..write('Use explicit ParamValue wrapper if needed, e.g., ')
    ..write('ParamValueString(value) for custom string conversion.')
    .toString(),
);
```

**Expected Impact:**

- Slight performance improvement for complex error paths
- More maintainable error message construction

**Tasks:**

- [ ] P3.5.1 Replace string interpolation with `StringBuffer` in error messages
- [ ] P3.5.2 Run tests to verify messages unchanged
- [ ] P3.5.3 Profile error path performance

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests pass
- ✅ Error messages identical to before

---

## Phase 4 - Documentation and testing

### 4.1 - Update documentation with new validation behavior

**Files:** `doc/TYPE_MAPPING.md`, `doc/README.md`, `doc/TROUBLESHOOTING.md`

**Tasks:**

- [ ] P4.1.1 Document type validation in `addRow()`
- [ ] P4.1.2 Document `validateOnAddRow` flag (if implemented)
- [ ] P4.1.3 Add examples of validation error messages
- [ ] P4.1.4 Update TROUBLESHOOTING.md with new error types

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ Documentation reviewed and consistent

---

### 4.2 - Add benchmarks for performance improvements

**Files:** `test/performance/` (new directory or existing)

**Tasks:**

- [ ] P4.2.1 Create benchmark for serialization helpers (before/after)
- [ ] P4.2.2 Create benchmark for bulk insert (before/after)
- [ ] P4.2.3 Document benchmark results in plan

**Validation:**

- ✅ Benchmarks show measurable improvement
- ✅ Results documented

---

### 4.3 - Add edge case tests

**Files:** `test/infrastructure/native/protocol/param_value_test.dart`
`test/infrastructure/native/protocol/bulk_insert_builder_test.dart`

**Tasks:**

- [ ] P4.3.1 Add tests for double edge cases (NaN, Infinity)
- [ ] P4.3.2 Add tests for DateTime edge cases (invalid ranges)
- [ ] P4.3.3 Add tests for Unicode edge cases (emoji, combining chars)
- [ ] P4.3.4 Add tests for type validation errors

**Validation:**

- ✅ `dart analyze` - No issues found
- ✅ All edge case tests pass

---

## Definition of Done (DoD)

All acceptance criteria must be met for each phase:

### Phase 1 (High Priority Performance)

- [ ] All serialization helpers refactored to reduce allocations
- [ ] Row copy removed from `addRow()`
- [ ] Endianness constant cached
- [ ] All tests pass
- [ ] Benchmarks show measurable improvement

### Phase 2 (High Priority Reliability)

- [ ] Nullability validation moved to `addRow()`
- [ ] Type validation per column implemented
- [ ] All tests pass
- [ ] Error messages are clear and actionable

### Phase 3 (Medium Priority Enhancements)

- [ ] Unnecessary null bitmap check removed
- [ ] Double to decimal conversion improved
- [ ] DateTime range validation added
- [ ] Unicode/string validation added
- [ ] Complex error messages use `StringBuffer`
- [ ] All tests pass

### Phase 4 (Documentation and Testing)

- [ ] Documentation updated with new validation behavior
- [ ] Benchmarks created and documented
- [ ] Edge case tests added
- [ ] `dart analyze` - No issues found

---

## Performance Goals

| Metric                                 | Current              | Target        | Improvement   |
| -------------------------------------- | -------------------- | ------------- | ------------- |
| Serialization allocation per primitive | ~2 allocations       | ~1 allocation | 50%           |
| Bulk insert memory usage               | Baseline             | -20%          | 20% reduction |
| Null bitmap set operation              | O(n) with check      | O(n)          | 5-10%         |
| Error message construction             | String interpolation | StringBuffer  | Small         |

---

## Risk Assessment

| Risk                       | Probability | Impact | Mitigation                      |
| -------------------------- | ----------- | ------ | ------------------------------- |
| Row reference modification | Low         | High   | Document ownership expectations |
| Type validation too strict | Medium      | Medium | Add flag to disable             |
| Performance regression     | Low         | High   | Benchmark before/after          |
| Breaking changes           | Low         | High   | Document migration path         |

---

## Rollback Plan

If any phase introduces breaking changes:

1. Revert changes to affected files
2. Review test failures
3. Adjust approach and re-implement
4. Document learnings in plan notes

---

## Success Metrics

- All tests pass
- `dart analyze` shows no issues
- Benchmarks show measurable improvement
- No breaking changes to public API
- Documentation is complete and accurate

---

## Related Documents

- [NULL_HANDLING_RELIABILITY_PERFORMANCE_PLAN.md](NULL_HANDLING_RELIABILITY_PERFORMANCE_PLAN.md) - Completed NULL handling implementation
- [TYPE_MAPPING.md](../TYPE_MAPPING.md) - Type mapping documentation
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) - Common issues and solutions
- [FUTURE_IMPLEMENTATIONS.md](../FUTURE_IMPLEMENTATIONS.md) - Technical backlog
