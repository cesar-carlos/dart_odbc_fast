# Statement Reuse and Timeout Implementation Review

## Current Implementation Status (2026-03-02)

### ✅ Implemented Features

#### 1. **Prepared Statement Cache**
**Location**: `src/engine/core/prepared_cache.rs`

- **LRU Cache**: Tracks prepared SQL statements with configurable max size
- **Metrics**: Comprehensive tracking of cache hits, misses, prepares, and executions
- **Thread-safe**: Uses `Arc<Mutex<LruCache>>` for concurrent access
- **Lock Poisoning Resilience**: Graceful degradation on mutex poisoning

**Capabilities**:
```rust
pub struct PreparedStatementCache {
    cache: Arc<Mutex<LruCache<String, ()>>>,  // SQL -> placeholder
    max_size: usize,
    cache_hits: Arc<AtomicU64>,
    cache_misses: Arc<AtomicU64>,
    total_prepares: Arc<AtomicU64>,
    total_executions: Arc<AtomicU64>,
}
```

**Metrics Available**:
- Cache size and max size
- Hit/miss ratio
- Total prepares and executions
- Average executions per statement
- Estimated memory usage

#### 2. **Timeout Support**
**Location**: `src/ffi/mod.rs`

**Connection-level Timeout**:
```c
uint32_t odbc_connect_with_timeout(const char* conn_str, uint32_t timeout_ms);
```
- Login timeout in milliseconds
- Default: 1 second if `timeout_ms == 0`
- Minimum: 1 second (enforced)

**Statement-level Timeout**:
```c
uint32_t odbc_prepare(uint32_t conn_id, const char* sql, uint32_t timeout_ms);
```
- Query timeout stored in `StatementHandle`
- Can be overridden per execution

**Execution Timeout Override**:
```c
int32_t odbc_execute(
    uint32_t stmt_id,
    const uint8_t* params_buffer,
    uint32_t params_len,
    uint32_t timeout_override_ms,  // Per-execution override
    uint8_t* out_buffer,
    uint32_t buffer_len,
    uint32_t* out_written
);
```

### 🔄 Current Limitations

#### 1. **Statement Reuse Scope**
**Issue**: The `PreparedStatementCache` currently tracks SQL strings but doesn't maintain actual ODBC statement handles for reuse.

**Current Behavior**:
- Cache tracks which SQL has been prepared (for metrics)
- Each `odbc_prepare` call creates a new `StatementHandle`
- No actual ODBC handle reuse between executions

**Impact**:
- Prepare overhead on every `odbc_prepare` call
- No benefit from ODBC driver's prepared statement optimization
- Cache primarily serves metrics/observability purpose

#### 2. **Timeout Granularity**
**Issue**: Timeout is set at prepare time, not dynamically per execution.

**Current Behavior**:
```rust
pub struct StatementHandle {
    pub conn_id: u32,
    pub sql: String,
    pub timeout_ms: u32,  // Set at prepare, not per-execute
}
```

**Workaround Available**:
- `timeout_override_ms` parameter in `odbc_execute` (but not fully utilized)

### 📋 Recommendations for Fase 2 Completion

#### Option A: Full Statement Handle Reuse (High Impact)
**Effort**: 2-3 days  
**Benefit**: Significant performance improvement for repeated queries

**Implementation**:
1. Extend `PreparedStatementCache` to store actual ODBC statement handles:
   ```rust
   LruCache<String, Arc<Mutex<odbc_api::StatementImpl<'static>>>>
   ```
2. Implement handle lifecycle management:
   - Prepare on cache miss
   - Reuse on cache hit
   - Close on eviction
3. Handle thread-safety for concurrent executions
4. Add tests for handle reuse scenarios

**Risks**:
- ODBC driver compatibility (some drivers may not support handle reuse)
- Connection affinity (statement tied to specific connection)
- Complexity in error handling and cleanup

#### Option B: Enhanced Timeout Control (Medium Impact)
**Effort**: 0.5-1 day  
**Benefit**: More flexible timeout configuration

**Implementation**:
1. Utilize `timeout_override_ms` in `odbc_execute`:
   ```rust
   let effective_timeout = if timeout_override_ms > 0 {
       timeout_override_ms
   } else {
       stmt.timeout_ms
   };
   // Apply to ODBC statement before execution
   ```
2. Document timeout precedence clearly
3. Add E2E tests for timeout override scenarios

#### Option C: Hybrid Approach (Recommended)
**Effort**: 1-2 days  
**Benefit**: Balanced improvement with manageable risk

**Implementation**:
1. **Phase 1**: Implement Option B (timeout enhancement) ✅ Quick win
2. **Phase 2**: Add opt-in statement handle reuse behind feature flag
3. **Phase 3**: Gather metrics and validate across drivers before enabling by default

### 🎯 Proposed Action Plan

#### Immediate (Fase 2 Completion)
1. ✅ **Document current state** (this file)
2. ⚠️ **Implement timeout override** in `odbc_execute`
3. ⚠️ **Add E2E tests** for timeout scenarios
4. ✅ **Update `implementation_plan.md`** with findings

#### Future (Post-Fase 2)
1. **Feature Flag**: Add `statement-handle-reuse` feature
2. **Prototype**: Implement handle reuse for single-threaded scenarios
3. **Benchmark**: Compare prepare overhead with/without reuse
4. **Validate**: Test across SQL Server, PostgreSQL, MySQL
5. **Document**: Add driver compatibility matrix

### 📊 Current Test Coverage

**Timeout Tests**:
- ✅ `test_ffi_prepare_with_timeout` - validates timeout parameter acceptance
- ⚠️ Missing: actual timeout enforcement tests (requires long-running query)

**Statement Reuse Tests**:
- ✅ Cache metrics validation in `PreparedStatementCache::tests`
- ⚠️ Missing: E2E tests for repeated prepare/execute cycles

### 🔍 Code References

**Timeout Implementation**:
- `src/ffi/mod.rs:310` - `odbc_connect_with_timeout`
- `src/ffi/mod.rs:1660` - `odbc_prepare` with timeout
- `src/ffi/mod.rs:1717` - `odbc_execute` with timeout override

**Statement Cache**:
- `src/engine/core/prepared_cache.rs` - Full implementation
- `src/engine/core/execution_engine.rs` - Cache integration

**Documentation**:
- `native/doc/ffi_api.md:200-250` - Transaction and timeout API docs

### ✅ Conclusion

**Current Status**: 
- ✅ Timeout infrastructure is in place
- ⚠️ Statement reuse is partial (metrics only, no handle reuse)

**Recommendation**:
- **Mark Fase 2 as "Substantially Complete"** with documented limitations
- **Create follow-up task** for full statement handle reuse (optional enhancement)
- **Implement timeout override** as final Fase 2 item (low effort, high value)

The current implementation provides solid foundation for timeout control and observability. Full statement handle reuse is a valuable optimization but not critical for core functionality.
