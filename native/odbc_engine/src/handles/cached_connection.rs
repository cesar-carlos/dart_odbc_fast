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

use crate::engine::core::execution::result_encoding::encode_optional_cursor_with_encoding;
use crate::engine::query::ResultEncoding;
use crate::error::{OdbcError, Result};
#[cfg(feature = "statement-handle-reuse")]
use lru::LruCache;
use odbc_api::parameter::InputParameter;
use odbc_api::{Connection, Prepared};
#[cfg(feature = "statement-handle-reuse")]
use std::num::NonZeroUsize;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::OnceLock;

use std::ops::Deref;

use crate::protocol::{
    deserialize_param_buffer, has_null_param, param_values_to_input_params,
    param_values_to_input_params_with_inference, ParamList, ParamValue,
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
    #[cfg(feature = "statement-handle-reuse")]
    txn_cursor_behavior: Option<(Option<u16>, Option<u16>)>,
    conn: Connection<'static>,
    /// Canonical [`ENGINE_*`](crate::engine::core) id, filled on first
    /// [`Self::engine_id`] call via a single `SQL_DBMS_NAME` round-trip.
    engine_id: OnceLock<&'static str>,
    /// Set when a session-scoped lock-timeout override was applied
    /// (MySQL/MariaDB/SQL Server/SQLite/DB2). Cleared after reset to
    /// the documented engine default on txn end / pool checkin.
    session_lock_timeout_dirty: AtomicBool,
    session_isolation_dirty: AtomicBool,
    unusable: AtomicBool,
    validated_on_checkout: AtomicBool,
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
            engine_id: OnceLock::new(),
            session_lock_timeout_dirty: AtomicBool::new(false),
            session_isolation_dirty: AtomicBool::new(false),
            unusable: AtomicBool::new(false),
            validated_on_checkout: AtomicBool::new(false),
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
            txn_cursor_behavior: None,
            conn,
            engine_id: OnceLock::new(),
            session_lock_timeout_dirty: AtomicBool::new(false),
            session_isolation_dirty: AtomicBool::new(false),
            unusable: AtomicBool::new(false),
            validated_on_checkout: AtomicBool::new(false),
            cache_hits: AtomicU64::new(0),
            cache_misses: AtomicU64::new(0),
            cache_evictions: AtomicU64::new(0),
        }
    }

    /// Canonical engine id for this connection (`ENGINE_*`).
    ///
    /// Lazily resolved with a single `SQLGetInfo(SQL_DBMS_NAME)` call and
    /// cached for the lifetime of the connection. Subsequent calls are free.
    pub fn engine_id(&self) -> Result<&'static str> {
        if let Some(&id) = self.engine_id.get() {
            return Ok(id);
        }
        let id = crate::engine::dbms_info::detect_engine_id(&self.conn)?;
        // Concurrent first fills: OnceLock keeps the first successful value.
        let _ = self.engine_id.set(id);
        Ok(self.engine_id.get().copied().unwrap_or(id))
    }

    /// Test/helper: seed the engine-id cache without calling `SQLGetInfo`.
    #[cfg(test)]
    pub fn set_engine_id_for_test(&self, engine_id: &'static str) {
        let _ = self.engine_id.set(engine_id);
    }

    /// Returns `true` when [`Self::engine_id`] has already been resolved.
    #[cfg(test)]
    pub fn has_cached_engine_id(&self) -> bool {
        self.engine_id.get().is_some()
    }

    /// Mark that a session-scoped lock-timeout override is active.
    pub fn mark_session_lock_timeout_dirty(&self) {
        self.session_lock_timeout_dirty
            .store(true, Ordering::Relaxed);
    }

    pub(crate) fn mark_session_isolation_dirty(&self) {
        self.session_isolation_dirty.store(true, Ordering::Release);
    }

    pub(crate) fn mark_unusable(&self) {
        self.unusable.store(true, Ordering::Release);
    }

    pub(crate) fn is_unusable(&self) -> bool {
        self.unusable.load(Ordering::Acquire)
    }

    pub(crate) fn mark_validated_on_checkout(&self) {
        self.validated_on_checkout.store(true, Ordering::Release);
    }

    pub(crate) fn was_validated_on_checkout(&self) -> bool {
        self.validated_on_checkout.load(Ordering::Acquire)
    }

    pub(crate) fn clear_checkout_validation(&self) {
        self.validated_on_checkout.store(false, Ordering::Release);
    }

    pub(crate) fn ensure_usable(&self) -> Result<()> {
        if self.is_unusable() {
            Err(OdbcError::PoolError(
                "Connection state is indeterminate; discard it".to_string(),
            ))
        } else {
            Ok(())
        }
    }

    pub(crate) fn end_transaction(&mut self, commit: bool) -> Result<()> {
        self.ensure_usable()?;
        self.invalidate_cache_for_transaction_end(commit);
        let result = run_session_end(
            self,
            |cached| {
                if commit {
                    cached.conn.commit()
                } else {
                    cached.conn.rollback()
                }
                .map_err(OdbcError::from)
            },
            |cached| cached.conn.set_autocommit(true).map_err(OdbcError::from),
            |cached| cached.try_restore_session_settings_if_dirty(),
        );
        if result.is_err() {
            self.mark_unusable();
        }
        result
    }

    #[cfg(feature = "statement-handle-reuse")]
    fn invalidate_cache_for_transaction_end(&mut self, commit: bool) {
        let (commit_behavior, rollback_behavior) =
            *self.txn_cursor_behavior.get_or_insert_with(|| {
                crate::engine::odbc_get_info::transaction_cursor_behavior(&self.conn)
            });
        let behavior = if commit {
            commit_behavior
        } else {
            rollback_behavior
        };
        if !crate::engine::odbc_get_info::cursor_behavior_preserves_prepared(behavior) {
            self.invalidate_cache();
        }
    }

    #[cfg(not(feature = "statement-handle-reuse"))]
    fn invalidate_cache_for_transaction_end(&mut self, _commit: bool) {}

    /// Best-effort restore of session lock-timeout to the engine default
    /// when [`Self::mark_session_lock_timeout_dirty`] was set.
    pub fn restore_session_lock_timeout_if_dirty(&mut self) {
        if let Err(e) = self.try_restore_session_lock_timeout_if_dirty() {
            log::warn!("CachedConnection: failed to restore lock timeout: {e}");
        }
    }

    pub(crate) fn try_restore_session_lock_timeout_if_dirty(&mut self) -> Result<()> {
        restore_dirty_flag(&self.session_lock_timeout_dirty, || {
            let engine = self.engine_id()?;
            if let Some(sql) =
                crate::engine::session_defaults::session_lock_timeout_reset_sql(engine)
            {
                self.conn.execute(sql, (), None).map_err(OdbcError::from)?;
            }
            Ok(())
        })
    }

    pub(crate) fn try_restore_session_settings_if_dirty(&mut self) -> Result<()> {
        self.try_restore_session_lock_timeout_if_dirty()?;
        restore_dirty_flag(&self.session_isolation_dirty, || {
            let engine = self.engine_id()?;
            if let Some(sql) = crate::engine::session_defaults::session_isolation_reset_sql(engine)
            {
                self.conn.execute(sql, (), None).map_err(OdbcError::from)?;
            }
            Ok(())
        })
    }

    /// Get a reference to the underlying connection.
    pub fn connection(&self) -> &Connection<'static> {
        &self.conn
    }

    pub(crate) fn checked_connection(&self) -> Result<&Connection<'static>> {
        self.ensure_usable()?;
        Ok(&self.conn)
    }

    /// Get a mutable reference to the underlying connection.
    ///
    /// Safety: clears statement cache before returning mutable reference to ensure
    /// no borrowed statements remain alive while connection is mutated.
    pub fn connection_mut(&mut self) -> &mut Connection<'static> {
        #[cfg(feature = "statement-handle-reuse")]
        {
            self.invalidate_cache();
            self.txn_cursor_behavior = None;
        }
        &mut self.conn
    }

    /// Execute a no-param query, using cached prepared statement when available.
    pub fn execute_query_no_params(&mut self, sql: &str) -> Result<Vec<u8>> {
        self.execute_with_encoding(sql, ResultEncoding::RowMajor, None)
    }

    /// Execute a no-param query with an explicit wire encoding, reusing a
    /// cached prepared handle when [`statement-handle-reuse`] is enabled.
    ///
    /// `fetch_size` of `None` keeps the process block-fetch default.
    pub fn execute_with_encoding(
        &mut self,
        sql: &str,
        encoding: ResultEncoding,
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        self.ensure_usable()?;
        #[cfg(feature = "statement-handle-reuse")]
        {
            self.execute_query_with_reuse(sql, encoding, fetch_size)
        }

        #[cfg(not(feature = "statement-handle-reuse"))]
        {
            let mut stmt = self.conn.prepare(sql).map_err(OdbcError::from)?;
            execute_stmt_to_buffer_with_encoding(&mut stmt, encoding, fetch_size)
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
        self.execute_with_params_and_encoding(sql, params, ResultEncoding::RowMajor, None)
    }

    /// Parameterised execute with explicit wire encoding and prepared-handle
    /// reuse when eligible.
    pub fn execute_with_params_and_encoding(
        &mut self,
        sql: &str,
        params: &[ParamValue],
        encoding: ResultEncoding,
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        self.ensure_usable()?;
        #[cfg(feature = "statement-handle-reuse")]
        {
            self.execute_query_with_params_reuse(sql, params, encoding, fetch_size)
        }

        #[cfg(not(feature = "statement-handle-reuse"))]
        {
            let mut stmt = self.conn.prepare(sql).map_err(OdbcError::from)?;
            execute_stmt_with_params_and_encoding(&mut stmt, params, encoding, fetch_size)
        }
    }

    /// Execute from a raw FFI parameter buffer when the legacy plan is
    /// eligible for the prepared cache (including NULL binds that share a
    /// sibling non-null type via inference); otherwise falls back to the raw
    /// connection dispatcher (`PreparedNullAware` / directed params).
    pub fn try_execute_param_buffer_with_encoding(
        &mut self,
        sql: &str,
        param_bytes: &[u8],
        encoding: ResultEncoding,
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        self.ensure_usable()?;
        let list = deserialize_param_buffer(param_bytes)?;
        if let ParamList::Legacy(params) = &list {
            if params.is_empty() {
                return self.execute_with_encoding(sql, encoding, fetch_size);
            }
            if let Some(prepared_params) = prepared_params_for_cache(params)? {
                return self.execute_with_prepared_params(
                    sql,
                    &prepared_params,
                    encoding,
                    fetch_size,
                );
            }
        }
        crate::engine::query::execute_query_with_parsed_params_encoding(
            self.connection(),
            sql,
            list,
            encoding,
            fetch_size,
        )
    }

    fn execute_with_prepared_params(
        &mut self,
        sql: &str,
        params: &[Box<dyn InputParameter>],
        encoding: ResultEncoding,
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        #[cfg(feature = "statement-handle-reuse")]
        {
            self.with_prepared_mut(sql, |stmt| {
                execute_prepared_params(stmt, params, encoding, fetch_size)
            })
        }
        #[cfg(not(feature = "statement-handle-reuse"))]
        {
            let mut stmt = self.conn.prepare(sql).map_err(OdbcError::from)?;
            execute_prepared_params(&mut stmt, params, encoding, fetch_size)
        }
    }

    #[cfg(feature = "statement-handle-reuse")]
    fn execute_query_with_reuse(
        &mut self,
        sql: &str,
        encoding: ResultEncoding,
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        if let Some(cached) = self.stmt_cache.get_mut(sql) {
            self.cache_hits.fetch_add(1, Ordering::Relaxed);
            return cached
                .with_mut(|stmt| execute_stmt_to_buffer_with_encoding(stmt, encoding, fetch_size));
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
        let result = owned
            .with_mut(|stmt| execute_stmt_to_buffer_with_encoding(stmt, encoding, fetch_size))?;

        self.stmt_cache.put(sql.to_string(), owned);

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
        encoding: ResultEncoding,
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        if let Some(cached) = self.stmt_cache.get_mut(sql) {
            self.cache_hits.fetch_add(1, Ordering::Relaxed);
            // Re-bind every execute: parameter values typically change
            // between calls even when the SQL is identical, and ODBC
            // allows re-binding on a cached prepared statement.
            return cached.with_mut(|stmt| {
                execute_stmt_with_params_and_encoding(stmt, params, encoding, fetch_size)
            });
        }

        self.cache_misses.fetch_add(1, Ordering::Relaxed);

        let prepared = self.conn.prepare(sql).map_err(OdbcError::from)?;

        let capacity = self.stmt_cache.cap().get();
        let should_count_eviction = self.stmt_cache.len() >= capacity;

        // SAFETY: see [`OwnedPreparedStatement::from_borrowed`] and the
        // `execute_query_with_reuse` SAFETY note above — same invariant
        // (cache drops before connection, single point of unsafe).
        let mut owned = unsafe { OwnedPreparedStatement::from_borrowed(prepared) };
        let result = owned.with_mut(|stmt| {
            execute_stmt_with_params_and_encoding(stmt, params, encoding, fetch_size)
        })?;

        self.stmt_cache.put(sql.to_string(), owned);

        if should_count_eviction {
            self.cache_evictions.fetch_add(1, Ordering::Relaxed);
        }

        Ok(result)
    }

    /// True when params can rebind on a cached prepared handle (no NULLs, or
    /// NULLs with an inferable sibling non-null type).
    pub fn can_reuse_prepared_for_params(&self, params: &[ParamValue]) -> bool {
        params_eligible_for_prepared_cache(params)
    }

    /// Cache hits (when feature enabled).
    pub fn cache_hits(&self) -> u64 {
        self.cache_hits.load(Ordering::Relaxed)
    }

    /// Cache misses (when feature enabled).
    pub fn cache_misses(&self) -> u64 {
        self.cache_misses.load(Ordering::Relaxed)
    }

    /// Get-or-prepare a cached statement and run `f` while the handle is
    /// exclusively borrowed. Used by batched streaming to avoid re-prepare.
    #[cfg(feature = "statement-handle-reuse")]
    pub fn with_prepared_mut<R, F>(&mut self, sql: &str, f: F) -> Result<R>
    where
        F: FnOnce(&mut Prepared<odbc_api::handles::StatementImpl<'static>>) -> Result<R>,
    {
        self.ensure_usable()?;
        if let Some(cached) = self.stmt_cache.get_mut(sql) {
            self.cache_hits.fetch_add(1, Ordering::Relaxed);
            return cached.with_mut(f);
        }

        self.cache_misses.fetch_add(1, Ordering::Relaxed);
        let prepared = self.conn.prepare(sql).map_err(OdbcError::from)?;
        let capacity = self.stmt_cache.cap().get();
        let should_count_eviction = self.stmt_cache.len() >= capacity;
        // SAFETY: see [`OwnedPreparedStatement::from_borrowed`].
        let mut owned = unsafe { OwnedPreparedStatement::from_borrowed(prepared) };
        let result = owned.with_mut(f)?;
        self.stmt_cache.put(sql.to_string(), owned);
        if should_count_eviction {
            self.cache_evictions.fetch_add(1, Ordering::Relaxed);
        }
        Ok(result)
    }

    /// Streaming MULT may leave a cursor/statement in an unusable state on
    /// cancellation, fetch failure, encode failure, or consumer abandonment.
    /// Invalidate both cache hits and misses when the operation fails.
    #[cfg(feature = "statement-handle-reuse")]
    pub(crate) fn with_multi_prepared_mut<R, F>(&mut self, sql: &str, f: F) -> Result<R>
    where
        F: FnOnce(&mut Prepared<odbc_api::handles::StatementImpl<'static>>) -> Result<R>,
    {
        let result = self.with_prepared_mut(sql, f);
        if result.is_err() {
            self.invalidate_prepared(sql);
        }
        result
    }

    #[cfg(feature = "statement-handle-reuse")]
    pub(crate) fn invalidate_prepared(&mut self, sql: &str) {
        if self.stmt_cache.pop(sql).is_some() {
            self.cache_evictions.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// Roll back any open transaction and restore autocommit. Statements are
    /// retained only when the driver's rollback behavior preserves them.
    /// Used by pool acquire/release hooks. Session-scoped overrides are reset.
    pub fn pool_session_reset(&mut self) -> Result<()> {
        self.ensure_usable()?;
        self.invalidate_cache_for_transaction_end(false);
        let result = run_session_end(
            self,
            |cached| cached.conn.rollback().map_err(OdbcError::from),
            |cached| cached.conn.set_autocommit(true).map_err(OdbcError::from),
            |cached| cached.try_restore_session_settings_if_dirty(),
        );
        if result.is_err() {
            self.mark_unusable();
        }
        result
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

fn run_session_end<T>(
    target: &mut T,
    finish: impl FnOnce(&mut T) -> Result<()>,
    autocommit: impl FnOnce(&mut T) -> Result<()>,
    restore: impl FnOnce(&mut T) -> Result<()>,
) -> Result<()> {
    finish(target)?;
    autocommit(target)?;
    restore(target)
}

fn restore_dirty_flag(dirty: &AtomicBool, reset: impl FnOnce() -> Result<()>) -> Result<()> {
    if dirty.load(Ordering::Acquire) {
        reset()?;
        dirty.store(false, Ordering::Release);
    }
    Ok(())
}

#[cfg(feature = "statement-handle-reuse")]
impl Drop for CachedConnection {
    fn drop(&mut self) {
        self.stmt_cache.clear();
    }
}

fn execute_stmt_to_buffer_with_encoding<S>(
    stmt: &mut Prepared<S>,
    encoding: ResultEncoding,
    fetch_size: Option<u32>,
) -> Result<Vec<u8>>
where
    S: odbc_api::handles::AsStatementRef,
{
    let cursor = stmt.execute(()).map_err(OdbcError::from)?;
    encode_optional_cursor_with_encoding(cursor, encoding, None, fetch_size)
}

fn execute_stmt_with_params_and_encoding<S>(
    stmt: &mut Prepared<S>,
    params: &[ParamValue],
    encoding: ResultEncoding,
    fetch_size: Option<u32>,
) -> Result<Vec<u8>>
where
    S: odbc_api::handles::AsStatementRef,
{
    let parameters = if has_null_param(params) {
        // Inference-only path: sibling non-null values fix the C type so
        // `SQL_NULL_DATA` rebinds stay safe without re-describe.
        param_values_to_input_params_with_inference(params)?.ok_or_else(|| {
            OdbcError::InternalError(
                "NULL params reached prepared cache without inferable type".to_string(),
            )
        })?
    } else {
        param_values_to_input_params(params)?
    };
    execute_prepared_params(stmt, &parameters, encoding, fetch_size)
}

fn execute_prepared_params<S>(
    stmt: &mut Prepared<S>,
    parameters: &[Box<dyn InputParameter>],
    encoding: ResultEncoding,
    fetch_size: Option<u32>,
) -> Result<Vec<u8>>
where
    S: odbc_api::handles::AsStatementRef,
{
    let cursor = stmt.execute(parameters).map_err(OdbcError::from)?;
    encode_optional_cursor_with_encoding(cursor, encoding, None, fetch_size)
}

pub(crate) fn prepared_params_for_cache(
    params: &[ParamValue],
) -> Result<Option<Vec<Box<dyn InputParameter>>>> {
    if has_null_param(params) {
        param_values_to_input_params_with_inference(params)
    } else {
        param_values_to_input_params(params).map(Some)
    }
}

/// Legacy params may use the prepared cache when there are no NULLs, or when
/// NULLs share an inferable sibling non-null type (avoids untyped string NULL).
fn params_eligible_for_prepared_cache(params: &[ParamValue]) -> bool {
    if !has_null_param(params) {
        return true;
    }
    matches!(
        param_values_to_input_params_with_inference(params),
        Ok(Some(_))
    )
}

#[cfg(test)]
mod param_plan_tests {
    use super::*;

    #[test]
    fn prepared_plan_handles_plain_inferable_and_fallback_inputs() {
        assert_eq!(
            prepared_params_for_cache(&[ParamValue::Integer(4), ParamValue::Integer(5)])
                .expect("plain")
                .expect("cacheable")
                .len(),
            2
        );
        assert_eq!(
            prepared_params_for_cache(&[ParamValue::Null, ParamValue::Integer(5)])
                .expect("inferable")
                .expect("cacheable")
                .len(),
            2
        );
        assert!(
            prepared_params_for_cache(&[ParamValue::Null, ParamValue::Null])
                .expect("all NULL")
                .is_none()
        );
        assert!(prepared_params_for_cache(&[
            ParamValue::Null,
            ParamValue::Integer(5),
            ParamValue::Binary(vec![1]),
        ])
        .expect("mixed")
        .is_none());
        assert!(prepared_params_for_cache(&[ParamValue::RefCursorOut]).is_err());
    }
}

#[cfg(test)]
mod session_end_tests {
    use super::*;

    fn failure(stage: &str) -> OdbcError {
        OdbcError::PoolError(stage.to_string())
    }

    #[test]
    fn failed_finish_never_enables_autocommit_or_restores_timeout() {
        let mut calls = Vec::new();
        let error = run_session_end(
            &mut calls,
            |calls| {
                calls.push("finish");
                Err(failure("finish failed"))
            },
            |calls| {
                calls.push("autocommit");
                Ok(())
            },
            |calls| {
                calls.push("restore");
                Ok(())
            },
        )
        .expect_err("finish failure must propagate");
        assert_eq!(calls, ["finish"]);
        assert!(error.to_string().contains("finish failed"));
    }

    #[test]
    fn autocommit_failure_stops_before_timeout_restore() {
        let mut calls = Vec::new();
        let error = run_session_end(
            &mut calls,
            |calls| {
                calls.push("finish");
                Ok(())
            },
            |calls| {
                calls.push("autocommit");
                Err(failure("autocommit failed"))
            },
            |calls| {
                calls.push("restore");
                Ok(())
            },
        )
        .expect_err("autocommit failure must propagate");
        assert_eq!(calls, ["finish", "autocommit"]);
        assert!(error.to_string().contains("autocommit failed"));
    }

    #[test]
    fn timeout_mark_is_cleared_only_after_successful_restore() {
        let dirty = AtomicBool::new(true);
        let error = restore_dirty_flag(&dirty, || Err(failure("reset failed")))
            .expect_err("reset failure must propagate");
        assert!(error.to_string().contains("reset failed"));
        assert!(dirty.load(Ordering::Acquire));

        let mut resets = 0;
        restore_dirty_flag(&dirty, || {
            resets += 1;
            Ok(())
        })
        .expect("reset succeeds");
        restore_dirty_flag(&dirty, || {
            resets += 1;
            Ok(())
        })
        .expect("clean state skips reset");
        assert_eq!(resets, 1);
        assert!(!dirty.load(Ordering::Acquire));
    }
}
