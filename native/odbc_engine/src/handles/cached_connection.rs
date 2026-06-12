//! Connection wrapper with optional prepared statement handle reuse.
//!
//! When `statement-handle-reuse` feature is enabled, maintains an LRU cache
//! of prepared statements per connection to avoid repeated prepare calls
//! for the same SQL.
//!
//! **Safety note**: Uses type erasure with Box to store prepared statements.
//! The prepared statement borrows from the connection, so we must ensure:
//! 1. Statements are dropped before connection in `Drop` impl
//! 2. `connection_mut()` clears cache before returning mutable reference
//! 3. Cache is private and never exposes references externally
//!
//! This approach uses a trait object to execute statements without exposing
//! the underlying borrow lifetime.

use crate::error::{OdbcError, Result};
#[cfg(feature = "statement-handle-reuse")]
use lru::LruCache;
use odbc_api::{Connection, Prepared, ResultSetMetadata};
#[cfg(feature = "statement-handle-reuse")]
use std::num::NonZeroUsize;
use std::sync::atomic::{AtomicU64, Ordering};

use std::ops::Deref;

use crate::protocol::{
    param_values_to_input_params, OdbcType, ParamValue, RowBuffer, RowBufferEncoder,
};

#[cfg(feature = "statement-handle-reuse")]
use super::owned_prepared::OwnedPreparedStatement;

/// Default cache size when statement-handle-reuse is enabled.
#[cfg(feature = "statement-handle-reuse")]
const DEFAULT_STMT_CACHE_SIZE: usize = 32;

/// Wrapper around Connection that optionally caches prepared statements.
///
/// When `statement-handle-reuse` is disabled (default), always prepares fresh.
/// When enabled, caches prepared statement handles for SQL reuse via
/// [`OwnedPreparedStatement`], which moves the unsafe lifetime-fabrication
/// into a typed RAII container (sprint 4 split).
///
/// ## Drop ordering invariant
///
/// `stmt_cache` is declared **before** `conn` so the auto-generated drop
/// glue runs `stmt_cache.drop()` first. This is the invariant the
/// [`OwnedPreparedStatement::from_borrowed`] safety contract relies on
/// — never reorder these fields.
pub struct CachedConnection {
    #[cfg(feature = "statement-handle-reuse")]
    stmt_cache: LruCache<String, OwnedPreparedStatement>,
    conn: Connection<'static>,
    cache_hits: AtomicU64,
    cache_misses: AtomicU64,
    #[cfg(feature = "statement-handle-reuse")]
    cache_evictions: AtomicU64,
}

impl CachedConnection {
    /// Create a new cached connection. When feature is off, cache is unused.
    #[cfg(not(feature = "statement-handle-reuse"))]
    pub fn new(conn: Connection<'static>) -> Self {
        Self {
            conn,
            cache_hits: AtomicU64::new(0),
            cache_misses: AtomicU64::new(0),
        }
    }

    #[cfg(feature = "statement-handle-reuse")]
    pub fn new(conn: Connection<'static>) -> Self {
        let cap = NonZeroUsize::new(DEFAULT_STMT_CACHE_SIZE)
            .unwrap_or_else(|| NonZeroUsize::new(32).expect("32 is non-zero"));
        Self {
            stmt_cache: LruCache::new(cap),
            conn,
            cache_hits: AtomicU64::new(0),
            cache_misses: AtomicU64::new(0),
            cache_evictions: AtomicU64::new(0),
        }
    }

    /// Get a reference to the underlying connection.
    pub fn connection(&self) -> &Connection<'static> {
        &self.conn
    }

    /// Get a mutable reference to the underlying connection.
    ///
    /// Safety: clears statement cache before returning mutable reference to ensure
    /// no borrowed statements remain alive while connection is mutated.
    pub fn connection_mut(&mut self) -> &mut Connection<'static> {
        #[cfg(feature = "statement-handle-reuse")]
        self.invalidate_cache();
        &mut self.conn
    }

    /// Execute a no-param query, using cached prepared statement when available.
    pub fn execute_query_no_params(&mut self, sql: &str) -> Result<Vec<u8>> {
        #[cfg(feature = "statement-handle-reuse")]
        {
            self.execute_query_with_reuse(sql)
        }

        #[cfg(not(feature = "statement-handle-reuse"))]
        {
            let mut stmt = self.conn.prepare(sql).map_err(OdbcError::from)?;
            execute_stmt_to_buffer(&mut stmt)
        }
    }

    /// Execute a parameterised query using cached prepared statement when
    /// available. Sprint 4.2 extension: the same `OwnedPreparedStatement`
    /// cache used by [`Self::execute_query_no_params`] now powers the
    /// params path, eliminating the per-execute `SQLPrepare` round-trip
    /// for repeated SQL in OLTP workloads.
    ///
    /// The parameter conversion (`param_values_to_input_params`) is done
    /// on every call because parameter types and values typically change
    /// between executes; only the `Prepared` handle itself is cached.
    /// Null-aware and inference plans still go through the
    /// non-cached `execute_query_with_params_inner` in
    /// `ExecutionEngine` because they need per-call descriptor lookups
    /// (`stmt.parameter_descriptions()`) and `conn.execute()` with
    /// inferred parameter sets, neither of which compose with a cached
    /// `Prepared` handle.
    pub fn execute_query_with_params(
        &mut self,
        sql: &str,
        params: &[ParamValue],
    ) -> Result<Vec<u8>> {
        #[cfg(feature = "statement-handle-reuse")]
        {
            self.execute_query_with_params_reuse(sql, params)
        }

        #[cfg(not(feature = "statement-handle-reuse"))]
        {
            let mut stmt = self.conn.prepare(sql).map_err(OdbcError::from)?;
            execute_stmt_with_params(&mut stmt, params)
        }
    }

    #[cfg(feature = "statement-handle-reuse")]
    fn execute_query_with_reuse(&mut self, sql: &str) -> Result<Vec<u8>> {
        let sql_key = sql.to_string();

        if let Some(cached) = self.stmt_cache.get_mut(&sql_key) {
            self.cache_hits.fetch_add(1, Ordering::Relaxed);
            return cached.with_mut(execute_stmt_to_buffer);
        }

        self.cache_misses.fetch_add(1, Ordering::Relaxed);

        let prepared = self.conn.prepare(sql).map_err(OdbcError::from)?;

        let capacity = self.stmt_cache.cap().get();
        let should_count_eviction = self.stmt_cache.len() >= capacity;

        // SAFETY: see [`OwnedPreparedStatement::from_borrowed`]. The cache
        // (`stmt_cache`) is declared before `conn` so it drops first; we
        // also clear it whenever `connection_mut()` runs. The unsafe
        // transmute that fakes `'static` is therefore confined to this
        // single line of construction inside the wrapper.
        let mut owned = unsafe { OwnedPreparedStatement::from_borrowed(prepared) };
        let result = owned.with_mut(execute_stmt_to_buffer)?;

        self.stmt_cache.put(sql_key, owned);

        if should_count_eviction {
            self.cache_evictions.fetch_add(1, Ordering::Relaxed);
        }

        Ok(result)
    }

    #[cfg(feature = "statement-handle-reuse")]
    fn execute_query_with_params_reuse(
        &mut self,
        sql: &str,
        params: &[ParamValue],
    ) -> Result<Vec<u8>> {
        let sql_key = sql.to_string();

        if let Some(cached) = self.stmt_cache.get_mut(&sql_key) {
            self.cache_hits.fetch_add(1, Ordering::Relaxed);
            // Re-bind every execute: parameter values typically change
            // between calls even when the SQL is identical, and ODBC
            // allows re-binding on a cached prepared statement.
            return cached.with_mut(|stmt| execute_stmt_with_params(stmt, params));
        }

        self.cache_misses.fetch_add(1, Ordering::Relaxed);

        let prepared = self.conn.prepare(sql).map_err(OdbcError::from)?;

        let capacity = self.stmt_cache.cap().get();
        let should_count_eviction = self.stmt_cache.len() >= capacity;

        // SAFETY: see [`OwnedPreparedStatement::from_borrowed`] and the
        // `execute_query_with_reuse` SAFETY note above — same invariant
        // (cache drops before connection, single point of unsafe).
        let mut owned = unsafe { OwnedPreparedStatement::from_borrowed(prepared) };
        let result = owned.with_mut(|stmt| execute_stmt_with_params(stmt, params))?;

        self.stmt_cache.put(sql_key, owned);

        if should_count_eviction {
            self.cache_evictions.fetch_add(1, Ordering::Relaxed);
        }

        Ok(result)
    }

    /// Cache hits (when feature enabled).
    pub fn cache_hits(&self) -> u64 {
        self.cache_hits.load(Ordering::Relaxed)
    }

    /// Cache misses (when feature enabled).
    pub fn cache_misses(&self) -> u64 {
        self.cache_misses.load(Ordering::Relaxed)
    }

    /// Roll back any open transaction and restore autocommit without
    /// evicting cached prepared statements. Used by pool acquire/release hooks.
    pub fn pool_session_reset(&mut self) -> Result<()> {
        let _ = self.conn.rollback();
        self.conn.set_autocommit(true).map_err(OdbcError::from)
    }

    #[cfg(feature = "statement-handle-reuse")]
    fn invalidate_cache(&mut self) {
        if !self.stmt_cache.is_empty() {
            self.stmt_cache.clear();
            self.cache_evictions.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// Cache evictions (feature-on only).
    #[cfg(feature = "statement-handle-reuse")]
    pub fn cache_evictions(&self) -> u64 {
        self.cache_evictions.load(Ordering::Relaxed)
    }

    /// Number of SQL entries tracked by statement cache (feature-on only).
    #[cfg(feature = "statement-handle-reuse")]
    pub fn tracked_sql_entries(&self) -> usize {
        self.stmt_cache.len()
    }
}

impl Deref for CachedConnection {
    type Target = Connection<'static>;

    fn deref(&self) -> &Self::Target {
        &self.conn
    }
}

#[cfg(feature = "statement-handle-reuse")]
impl Drop for CachedConnection {
    fn drop(&mut self) {
        self.stmt_cache.clear();
    }
}

fn execute_stmt_to_buffer<S>(stmt: &mut Prepared<S>) -> Result<Vec<u8>>
where
    S: odbc_api::handles::AsStatementRef,
{
    let cursor = stmt.execute(()).map_err(OdbcError::from)?;
    encode_optional_cursor_to_buffer(cursor)
}

fn execute_stmt_with_params<S>(stmt: &mut Prepared<S>, params: &[ParamValue]) -> Result<Vec<u8>>
where
    S: odbc_api::handles::AsStatementRef,
{
    let parameters = param_values_to_input_params(params)?;
    let cursor = stmt
        .execute(parameters.as_slice())
        .map_err(OdbcError::from)?;
    encode_optional_cursor_to_buffer(cursor)
}

/// Shared cursor drainer used by both the no-params and params cached
/// execution paths. Mirrors what `ExecutionEngine::encode_optional_cursor`
/// does for the same shape, minus the plugin/FOR-JSON normalisation
/// (which the engine layer is responsible for).
fn encode_optional_cursor_to_buffer<C>(cursor: Option<C>) -> Result<Vec<u8>>
where
    C: odbc_api::Cursor + ResultSetMetadata,
{
    let mut row_buffer = RowBuffer::new();

    if let Some(mut cursor) = cursor {
        let cols_i16 = cursor.num_result_cols().map_err(OdbcError::from)?;
        let cols_u16: u16 = cols_i16
            .try_into()
            .map_err(|_| OdbcError::InternalError("Invalid column count".to_string()))?;
        let cols_usize: usize = cols_u16.into();

        let mut column_types: Vec<OdbcType> = Vec::with_capacity(cols_usize);

        for col_idx in 1..=cols_u16 {
            let col_name = cursor.col_name(col_idx).map_err(OdbcError::from)?;
            let col_type = cursor.col_data_type(col_idx).map_err(OdbcError::from)?;
            let sql_type_code = OdbcType::sql_type_code_from_data_type(&col_type);
            let odbc_type = OdbcType::from_odbc_sql_type(sql_type_code);
            row_buffer.add_column(col_name.to_string(), odbc_type);
            column_types.push(odbc_type);
        }

        let _drained = crate::engine::fetch::fetch_cursor_into_row_buffer(
            cursor,
            &column_types,
            &mut row_buffer,
        )?;
    }

    RowBufferEncoder::encode_result(&row_buffer)
}
