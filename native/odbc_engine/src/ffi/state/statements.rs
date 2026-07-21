//! Dedicated lock for prepared statement handles.
//!
//! Statement prepare/lookup/close no longer contend on the residual
//! `GlobalState` mutex used by pools, transactions, and XA. Disconnect
//! and pool-close cleanup call [`retain_statements_not_for_connection`]
//! while already holding `GLOBAL_STATE`, so this lock sits *after* the
//! outer mutex in the ordering (same pattern as streams).
//!
//! Lock ordering: **transactions** → pools → connections → streams →
//! **statements** → async requests → connection errors → metadata cache.

use super::super::global_state::MAX_ID_ALLOC_ATTEMPTS;
use crate::engine::StatementHandle;
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, OnceLock};

struct StatementMaps {
    statements: HashMap<u32, StatementHandle>,
    next_stmt_id: u32,
}

fn statement_maps() -> &'static Mutex<StatementMaps> {
    static MAPS: OnceLock<Mutex<StatementMaps>> = OnceLock::new();
    MAPS.get_or_init(|| {
        Mutex::new(StatementMaps {
            statements: HashMap::new(),
            next_stmt_id: 1,
        })
    })
}

fn try_lock_statement_maps() -> Option<MutexGuard<'static, StatementMaps>> {
    match statement_maps().lock() {
        Ok(guard) => Some(guard),
        Err(poisoned) => {
            #[cfg(test)]
            {
                Some(poisoned.into_inner())
            }
            #[cfg(not(test))]
            {
                let _ = poisoned;
                None
            }
        }
    }
}

/// Allocates a fresh non-zero statement ID, or `0` when exhausted.
///
/// Does not touch `GLOBAL_STATE` so callers that already hold the outer
/// mutex (or none at all) can allocate without re-locking.
pub(crate) fn allocate_statement_id() -> u32 {
    let Some(mut maps) = try_lock_statement_maps() else {
        return 0;
    };
    for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
        let candidate = maps.next_stmt_id;
        maps.next_stmt_id = maps.next_stmt_id.wrapping_add(1);
        if candidate != 0 && !maps.statements.contains_key(&candidate) {
            return candidate;
        }
    }
    0
}

pub(crate) fn insert_statement(stmt_id: u32, stmt: StatementHandle) {
    if let Some(mut maps) = try_lock_statement_maps() {
        maps.statements.insert(stmt_id, stmt);
    }
}

pub(crate) fn get_statement_snapshot(stmt_id: u32) -> Option<(u32, String, Option<usize>)> {
    try_lock_statement_maps().and_then(|maps| {
        maps.statements
            .get(&stmt_id)
            .map(|s| (s.conn_id(), s.sql().to_string(), s.timeout_sec()))
    })
}

pub(crate) fn contains_statement(stmt_id: u32) -> bool {
    try_lock_statement_maps().is_some_and(|maps| maps.statements.contains_key(&stmt_id))
}

pub(crate) fn remove_statement(stmt_id: u32) -> Option<StatementHandle> {
    let removed = try_lock_statement_maps().and_then(|mut maps| maps.statements.remove(&stmt_id));
    if removed.is_some() {
        super::pending::clear_pending_for_statement(stmt_id);
    }
    removed
}

pub(crate) fn clear_all_statements() {
    if let Some(mut maps) = try_lock_statement_maps() {
        maps.statements.clear();
    }
    super::pending::clear_pending_execute_entries();
}

/// Drop every prepared statement bound to `conn_id` (disconnect / pool close).
pub(crate) fn retain_statements_not_for_connection(conn_id: u32) {
    let mut dropped_stmt_ids = Vec::new();
    if let Some(mut maps) = try_lock_statement_maps() {
        maps.statements.retain(|stmt_id, stmt| {
            if stmt.conn_id() == conn_id {
                dropped_stmt_ids.push(*stmt_id);
                false
            } else {
                true
            }
        });
    }
    for stmt_id in dropped_stmt_ids {
        super::pending::clear_pending_for_statement(stmt_id);
    }
    super::pending::clear_pending_for_connection(conn_id);
}

#[cfg(test)]
pub(crate) fn statement_count_for_test() -> usize {
    try_lock_statement_maps()
        .map(|maps| maps.statements.len())
        .unwrap_or(0)
}

#[cfg(test)]
pub(crate) fn statements_empty_for_test() -> bool {
    try_lock_statement_maps()
        .map(|maps| maps.statements.is_empty())
        .unwrap_or(true)
}
