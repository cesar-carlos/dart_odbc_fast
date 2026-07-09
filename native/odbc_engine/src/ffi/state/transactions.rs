//! Dedicated lock for local (non-XA) transaction handles.
//!
//! Begin/commit/rollback/savepoint and disconnect/pool cleanup no longer
//! contend on the residual `GlobalState` mutex used by XA and env init.
//! Cross-category cleanup still acquires this lock *before* pools when both
//! are needed (checkin / close / resize begin guards).
//!
//! Lock ordering: `GLOBAL_STATE` → xa → **transactions** → pools →
//! connections → streams → statements → …

use super::super::global_state::MAX_ID_ALLOC_ATTEMPTS;
use crate::engine::Transaction;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

pub(crate) struct TransactionMaps {
    transactions: HashMap<u32, Arc<Transaction>>,
    begins_in_progress: HashSet<u32>,
    next_txn_id: u32,
}

fn transaction_maps() -> &'static Mutex<TransactionMaps> {
    static MAPS: OnceLock<Mutex<TransactionMaps>> = OnceLock::new();
    MAPS.get_or_init(|| {
        Mutex::new(TransactionMaps {
            transactions: HashMap::new(),
            begins_in_progress: HashSet::new(),
            next_txn_id: 1,
        })
    })
}

fn try_lock_transaction_maps() -> Option<MutexGuard<'static, TransactionMaps>> {
    match transaction_maps().lock() {
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

/// Run `f` while holding the transaction maps lock.
pub(crate) fn with_transaction_maps_mut<R>(f: impl FnOnce(&mut TransactionMaps) -> R) -> Option<R> {
    try_lock_transaction_maps().map(|mut maps| f(&mut maps))
}

pub(crate) fn remove_begin_in_progress(conn_id: u32) {
    if let Some(mut maps) = try_lock_transaction_maps() {
        maps.begins_in_progress.remove(&conn_id);
    }
}

pub(crate) fn insert_transaction(txn_id: u32, txn: Arc<Transaction>) {
    if let Some(mut maps) = try_lock_transaction_maps() {
        maps.transactions.insert(txn_id, txn);
    }
}

pub(crate) fn remove_transaction(txn_id: u32) -> Option<Arc<Transaction>> {
    try_lock_transaction_maps().and_then(|mut maps| maps.transactions.remove(&txn_id))
}

pub(crate) fn get_transaction(txn_id: u32) -> Option<Arc<Transaction>> {
    try_lock_transaction_maps().and_then(|maps| maps.transactions.get(&txn_id).cloned())
}

pub(crate) fn rollback_transactions_best_effort(transactions: Vec<(u32, Transaction)>) {
    for (txn_id, txn) in transactions {
        if let Err(e) = txn.rollback() {
            log::warn!(
                "Failed to rollback transaction {txn_id} during pooled connection cleanup: {e}"
            );
        }
    }
}

impl TransactionMaps {
    pub(crate) fn has_active_for_connection(&self, conn_id: u32) -> bool {
        self.transactions
            .values()
            .any(|txn| txn.conn_id() == conn_id)
    }

    pub(crate) fn begin_in_progress(&self, conn_id: u32) -> bool {
        self.begins_in_progress.contains(&conn_id)
    }

    pub(crate) fn insert_begin_in_progress(&mut self, conn_id: u32) -> bool {
        self.begins_in_progress.insert(conn_id)
    }

    pub(crate) fn begins_snapshot(&self) -> HashSet<u32> {
        self.begins_in_progress.clone()
    }

    pub(crate) fn take_for_connection(&mut self, conn_id: u32) -> Vec<(u32, Transaction)> {
        let txn_ids: Vec<u32> = self
            .transactions
            .iter()
            .filter_map(|(txn_id, txn)| (txn.conn_id() == conn_id).then_some(*txn_id))
            .collect();
        txn_ids
            .into_iter()
            .filter_map(|txn_id| {
                self.transactions
                    .remove(&txn_id)
                    .and_then(|txn_arc| Arc::try_unwrap(txn_arc).ok().map(|txn| (txn_id, txn)))
            })
            .collect()
    }

    pub(crate) fn allocate_and_insert(&mut self, txn: Transaction) -> Result<u32, Transaction> {
        let mut id = 0u32;
        for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
            let candidate = self.next_txn_id;
            self.next_txn_id = self.next_txn_id.wrapping_add(1);
            if candidate != 0 && !self.transactions.contains_key(&candidate) {
                id = candidate;
                break;
            }
        }
        if id == 0 {
            return Err(txn);
        }
        self.transactions.insert(id, Arc::new(txn));
        Ok(id)
    }
}

#[cfg(test)]
pub(crate) fn contains_transaction_for_test(txn_id: u32) -> bool {
    try_lock_transaction_maps().is_some_and(|maps| maps.transactions.contains_key(&txn_id))
}

#[cfg(test)]
pub(crate) fn get_transaction_for_test(txn_id: u32) -> Option<Arc<Transaction>> {
    get_transaction(txn_id)
}
