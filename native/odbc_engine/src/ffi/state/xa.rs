//! Dedicated lock for X/Open XA branch handles.
//!
//! Active / preparing / prepared maps and the shared XA ID allocator no
//! longer contend on the residual `GlobalState` mutex (env / BCP strings).
//! XA does not nest with transactions or pools; never acquire
//! `GLOBAL_STATE` while holding this lock.
//!
//! Lock ordering: `GLOBAL_STATE` → **xa** → transactions → pools →
//! connections → streams → statements → …

use super::super::global_state::MAX_ID_ALLOC_ATTEMPTS;
use crate::engine::{PreparedXa, PreparingXa, XaTransaction};
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, OnceLock};

struct XaMaps {
    active: HashMap<u32, XaTransaction>,
    preparing: HashMap<u32, PreparingXa>,
    prepared: HashMap<u32, PreparedXa>,
    next_xa_id: u32,
}

fn xa_maps() -> &'static Mutex<XaMaps> {
    static MAPS: OnceLock<Mutex<XaMaps>> = OnceLock::new();
    MAPS.get_or_init(|| {
        Mutex::new(XaMaps {
            active: HashMap::new(),
            preparing: HashMap::new(),
            prepared: HashMap::new(),
            next_xa_id: 1,
        })
    })
}

fn try_lock_xa_maps() -> Option<MutexGuard<'static, XaMaps>> {
    match xa_maps().lock() {
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

fn allocate_id(maps: &mut XaMaps) -> Option<u32> {
    for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
        let candidate = maps.next_xa_id;
        maps.next_xa_id = maps.next_xa_id.wrapping_add(1);
        if candidate != 0
            && !maps.active.contains_key(&candidate)
            && !maps.preparing.contains_key(&candidate)
            && !maps.prepared.contains_key(&candidate)
        {
            return Some(candidate);
        }
    }
    None
}

pub(crate) fn insert_active(xa_id: u32, xa: XaTransaction) {
    if let Some(mut maps) = try_lock_xa_maps() {
        maps.active.insert(xa_id, xa);
    }
}

pub(crate) fn remove_active(xa_id: u32) -> Option<XaTransaction> {
    try_lock_xa_maps().and_then(|mut maps| maps.active.remove(&xa_id))
}

pub(crate) fn insert_preparing(xa_id: u32, preparing: PreparingXa) {
    if let Some(mut maps) = try_lock_xa_maps() {
        maps.preparing.insert(xa_id, preparing);
    }
}

pub(crate) fn remove_preparing(xa_id: u32) -> Option<PreparingXa> {
    try_lock_xa_maps().and_then(|mut maps| maps.preparing.remove(&xa_id))
}

pub(crate) fn insert_prepared(xa_id: u32, prepared: PreparedXa) {
    if let Some(mut maps) = try_lock_xa_maps() {
        maps.prepared.insert(xa_id, prepared);
    }
}

pub(crate) fn remove_prepared(xa_id: u32) -> Option<PreparedXa> {
    try_lock_xa_maps().and_then(|mut maps| maps.prepared.remove(&xa_id))
}

/// Allocate an ID and insert into the active map atomically.
pub(crate) fn allocate_and_insert_active(xa: XaTransaction) -> Result<u32, XaTransaction> {
    let Some(mut maps) = try_lock_xa_maps() else {
        return Err(xa);
    };
    let Some(id) = allocate_id(&mut maps) else {
        return Err(xa);
    };
    maps.active.insert(id, xa);
    Ok(id)
}

/// Allocate an ID and insert into the prepared map atomically (resume path).
pub(crate) fn allocate_and_insert_prepared(prepared: PreparedXa) -> Result<u32, PreparedXa> {
    let Some(mut maps) = try_lock_xa_maps() else {
        return Err(prepared);
    };
    let Some(id) = allocate_id(&mut maps) else {
        return Err(prepared);
    };
    maps.prepared.insert(id, prepared);
    Ok(id)
}
