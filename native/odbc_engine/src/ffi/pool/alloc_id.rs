use std::sync::Arc;

use super::super::global::*;
use super::super::prelude::*;
use crate::ffi::state;

pub(super) fn pool_create_inner(
    conn_str: &str,
    max_size: c_uint,
    options: crate::pool::PoolOptions,
) -> c_uint {
    match ConnectionPool::new_with_options(conn_str, max_size, options) {
        Ok(pool) => {
            let Some(pool_id) = state::allocate_pool_id() else {
                if let Some(mut gs) = try_lock_global_state() {
                    set_error(&mut gs, "Failed to allocate pool ID".to_string());
                }
                return 0;
            };
            state::insert_pool(pool_id, Arc::new(pool));
            pool_id
        }
        Err(e) => {
            let Some(mut gs) = try_lock_global_state() else {
                return 0;
            };
            set_error(&mut gs, format!("odbc_pool_create failed: {}", e));
            0
        }
    }
}
