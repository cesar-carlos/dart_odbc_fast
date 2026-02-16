# NULL Handling, Reliability, and Performance Plan

## Table of Contents

- [Overview](#overview) - Executive summary and completion status
- [Phase 0 - Baseline and safety net](#phase-0-baseline-and-safety-net) ✅
- [Phase 1 - Parameter conversion hardening](#phase-1-parameter-conversion-hardening) ✅
- [Phase 2 - Bulk insert nullability correctness](#phase-2-bulk-insert-nullability-correctness) ✅
- [Phase 3 - Performance improvements](#phase-3-performance-improvements) ✅
- [Phase 4 - Documentation updates](#phase-4-documentation-updates) ✅

---

## Overview

**Status:** ✅ COMPLETE

This plan was implemented across multiple phases to improve NULL handling
correctness, reliability, and performance in `dart_odbc_fast`.

**Implementation Overview:**

- Phase 0: Baseline and safety net ✅
- Phase 1: Parameter conversion hardening ✅
- Phase 2: Bulk insert nullability correctness ✅
- Phase 3: Performance improvements ✅
- Phase 4: Documentation updates ✅

**Breaking Change:** Callers relying on silent `toString()` fallback for
unsupported types will now receive `ArgumentError`.

---

## Phase 0 - Baseline and safety net

### Tasks

- [x] P0.1 Capture baseline behavior with focused tests for:
  - `null` insert via `executeQueryParams`
  - `"null"` string insert via `executeQueryParams`
  - non-nullable bulk column receiving `null`
- [x] P0.2 Record current behavior in a short test note.

### Validation

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests passed (31 tests)

### Phase 0 Notes

**Baseline Behavior Observed:**

1. **NULL handling in `paramValuesFromObjects`:**
   - `null` converts to `ParamValueNull` ✅
   - `"null"` string remains as string (not coerced to NULL) ✅
   - Empty string remains as string ✅
   - Multiple nulls and strings preserve semantics ✅

2. **Unsupported type conversion (silent `toString()` fallback):**
   - `bool` → `ParamValueString` with "true"/"false" ⚠️
   - `double` → `ParamValueString` with decimal representation ⚠️
   - `DateTime` → `ParamValueString` with platform-specific `toString()` ⚠️
   - Custom objects → `ParamValueString` via `toString()` ⚠️

3. **Bulk insert nullability:**
   - Non-nullable columns accept `null` without throwing ⚠️
   - Default values (0, empty string, zero timestamp) are serialized ⚠️
   - Nullable columns set null bitmap correctly ✅

---

## Phase 1 - Parameter conversion hardening

### Design

Replace silent fallback conversion with explicit behavior:

- Supported implicit input types:
  - `null`, `ParamValue`, `int`, `String`, `List<int>`/`Uint8List`, `bool`, `double`, `DateTime`
- Unsupported types:
  - return explicit `ArgumentError` (no implicit `toString()` fallback)

Recommended canonical mappings:

- `bool` -> `ParamValueInt32(1|0)` (stable SQL compatibility)
- `double` -> `ParamValueDecimal(value.toString())`
- `DateTime` -> `ParamValueString(value.toUtc().toIso8601String())`

### Tasks

- [x] P1.1 Create a single shared parameter mapping utility used by both:
  - `param_value.dart` conversion helper
  - `odbc_repository_impl.dart` conversion path
- [x] P1.2 Remove implicit unknown-type `toString()` fallback.
- [x] P1.3 Add explicit error path with actionable message:
  - includes received runtime type
  - suggests explicit `ParamValue*` wrapper when needed
- [x] P1.4 Add fast path for pre-typed `List<ParamValue>`.

### Validation

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests passed (35 tests)

### Phase 1 Notes

**Implementation Details:**

1. Created `toParamValue()` function in `param_value.dart` with:
   - Explicit type checking for supported types
   - Canonical mappings: `bool` → `ParamValueInt32(1|0)`
   - Canonical mappings: `double` → `ParamValueDecimal(value.toString())`
   - Canonical mappings: `DateTime` → `ParamValueString(value.toUtc().toIso8601String())`
   - Error throwing for unsupported types with actionable message

2. Updated `paramValuesFromObjects()` to:
   - Use fast path for pre-typed `List<ParamValue>` (and `null`)
   - Pre-size output list for better performance
   - Call `toParamValue()` for each item

3. Updated `_toParamValues()` in `odbc_repository_impl.dart` to:
   - Use shared `paramValuesFromObjects()` function
   - Eliminated duplicated mapping logic

**Breaking Change:** Callers relying on silent `toString()` fallback for
unsupported types will now receive `ArgumentError`. Migration path is to use explicit
`ParamValue` wrapper or convert to supported type beforehand.

---

## Phase 2 - Bulk insert nullability correctness

### Tasks

- [x] P2.1 In `BulkInsertBuilder.build()`, validate all rows:
  - if `spec.nullable == false` and row value is `null`, throw `StateError` with column name and row index
- [x] P2.2 Keep current nullable bitmap behavior for `nullable: true`.
- [x] P2.3 Add clear error messages for invalid nullability input.

### Validation

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests passed (34 tests)

### Phase 2 Notes

**Implementation Details:**

1. Added nullability validation in `BulkInsertBuilder.build()`:
   - Iterates through all columns and rows
   - Throws `StateError` for non-nullable columns containing `null`
   - Error message includes column name and row number for easy debugging
   - Suggests using `nullable: true` for columns that should accept `null`

2. Nullable bitmap behavior preserved:
   - `nullable: true` columns still use null bitmap correctly
   - Null values in nullable columns set appropriate bits

**Breaking Change:** Bulk insert operations that previously silently accepted
`null` values in non-nullable columns will now throw `StateError`.

---

## Phase 3 - Performance improvements (non-breaking)

### Tasks

- [x] P3.1 Eliminated duplicated mapping loops by using shared utility.
- [x] P3.2 Pre-sized output lists in mapping helpers via `List.filled()`.
- [x] P3.3 Avoided extra intermediate allocations with fast path.

### Validation

- ✅ `dart analyze` - No issues found
- ✅ `dart test` - All tests passed (35 tests)

### Phase 3 Notes

**Implementation Details:**

1. Duplicated mapping loops eliminated:
   - `odbc_repository_impl.dart._toParamValues()` now uses shared `paramValuesFromObjects()`
   - Single source of truth for parameter conversion logic

2. Pre-sized output lists:
   - `paramValuesFromObjects()` pre-allocates result list with `List.filled()`
   - Reduces dynamic array resizing overhead

3. Fast path for pre-typed `List<ParamValue>`:
   - Checks if all items are `ParamValue` or `null`
   - Skips conversion for already-typed items
   - Optimized for common use case (prepared statements with explicit types)

---

## Phase 4 - Documentation updates

### Tasks

- [x] P4.1 Updated `TYPE_MAPPING.md` with canonical mappings.
- [x] P4.2 Updated `README.md` with bulk insert nullability behavior.
- [x] P4.3 Updated `TROUBLESHOOTING.md` with nullability error section.

### Validation

- ✅ `dart analyze` - No issues found
- ✅ Documentation reviewed and updated

### Phase 4 Notes

**Documentation Updates:**

1. `TYPE_MAPPING.md`:
   - Added canonical mappings for `bool`, `double`, `DateTime`
   - Documented `ArgumentError` for unsupported types
   - Added bulk insert nullability behavior

2. `README.md`:
   - Added bulk insert nullability section
   - Documented error message format
   - Provided migration examples

3. `TROUBLESHOOTING.md`:
   - Added new section: "Bulk insert nullability"
   - Documented error message format
   - Provided usage examples

---

## Definition of Done (DoD)

All acceptance criteria from the original plan have been met:

1. ✅ No fallback to `toString()` for unsupported types
   - Removed implicit conversion
   - Added explicit `ArgumentError` with actionable message

2. ✅ `null` persists as SQL `NULL` in parametrized paths
   - `null` → `ParamValueNull`
   - `"null"` string remains as string (intentional text, not coerced)

3. ✅ Non-nullable bulk insert columns fail on `null` values
   - `StateError` thrown with column name and row index
   - Error message suggests using `nullable: true`

4. ✅ Canonical mappings for `bool`, `double`, `DateTime`
   - `bool` → `ParamValueInt32(1|0)`
   - `double` → `ParamValueDecimal(value.toString())`
   - `DateTime` → `ParamValueString(value.toUtc().toIso8601String())`

5. ✅ Fast path for pre-typed `List<ParamValue>`
   - Checks if all items are already `ParamValue` or `null`
   - Skips conversion for already-typed items

6. ✅ Pre-sized output lists
   - `List.filled()` used to reduce allocations

7. ✅ Single shared parameter mapping utility
   - `toParamValue()` and `paramValuesFromObjects()` in `param_value.dart`
   - Used by `odbc_repository_impl.dart`

8. ✅ All tests pass (35 tests)
   - `dart analyze` - No issues found

9. ✅ Documentation updated
   - `TYPE_MAPPING.md`, `README.md`, `TROUBLESHOOTING.md`
