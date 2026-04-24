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
use odbc_api::{Connection, Cursor, Prepared, ResultSetMetadata};
#[cfg(feature = "statement-handle-reuse")]
use std::num::NonZeroUsize;
use std::sync::atomic::{AtomicU64, Ordering};

use std::ops::Deref;

use crate::engine::cell_reader::CellReader;
use crate::protocol::{OdbcType, RowBuffer, RowBufferEncoder};

/// Default cache size when statement-handle-reuse is enabled.
#[cfg(feature = "statement-handle-reuse")]
const DEFAULT_STMT_CACHE_SIZE: usize = 32;

#[cfg(feature = "statement-handle-reuse")]
type StaticPrepared = Prepared<odbc_api::handles::StatementImpl<'static>>;

#[cfg(feature = "statement-handle-reuse")]
struct CachedPrepared {
    stmt: StaticPrepared,
}

/// Wrapper around Connection that optionally caches prepared statements.
///
/// When `statement-handle-reuse` is disabled (default), always prepares fresh.
/// When enabled, caches prepared statement handles for SQL reuse.
pub struct CachedConnection {
    conn: Connection<'static>,
    cache_hits: AtomicU64,
    cache_misses: AtomicU64,
    #[cfg(feature = "statement-handle-reuse")]
    cache_evictions: AtomicU64,
    #[cfg(feature = "statement-handle-reuse")]
    stmt_cache: LruCache<String, CachedPrepared>,
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
            conn,
            cache_hits: AtomicU64::new(0),
            cache_misses: AtomicU64::new(0),
            cache_evictions: AtomicU64::new(0),
            stmt_cache: LruCache::new(cap),
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

    #[cfg(feature = "statement-handle-reuse")]
    fn execute_query_with_reuse(&mut self, sql: &str) -> Result<Vec<u8>> {
        let sql_key = sql.to_string();

        if let Some(cached) = self.stmt_cache.get_mut(&sql_key) {
            self.cache_hits.fetch_add(1, Ordering::Relaxed);
            return execute_stmt_to_buffer(&mut cached.stmt);
        }

        self.cache_misses.fetch_add(1, Ordering::Relaxed);

        let prepared = self.conn.prepare(sql).map_err(OdbcError::from)?;

        let capacity = self.stmt_cache.cap().get();
        let should_count_eviction = self.stmt_cache.len() >= capacity;

        // SAFETY: `CachedConnection` owns the `Connection<'static>` and the
        // cache is cleared before `connection_mut` exposes mutable access or
        // before the connection is dropped. Cached statements therefore never
        // outlive or alias a mutated connection handle while this feature is
        // enabled. Keep this feature experimental until `odbc-api` exposes a
        // cache-friendly prepared statement lifetime.
        let static_stmt: StaticPrepared = unsafe { std::mem::transmute(prepared) };

        let mut cached = CachedPrepared { stmt: static_stmt };
        let result = execute_stmt_to_buffer(&mut cached.stmt)?;

        self.stmt_cache.put(sql_key, cached);

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

        let mut cell_reader = CellReader::new();
        while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
            let mut row_data = Vec::with_capacity(column_types.len());

            for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                let col_number: u16 = (col_idx + 1)
                    .try_into()
                    .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;

                let cell_data = cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?;

                row_data.push(cell_data);
            }

            row_buffer.add_row(row_data);
        }
    }

    Ok(RowBufferEncoder::encode(&row_buffer))
}
