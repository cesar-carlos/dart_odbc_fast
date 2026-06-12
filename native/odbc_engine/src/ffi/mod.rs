// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod columnar_decompress;
pub mod guard;
pub mod release_buffer;
pub mod state;

mod bulk;
mod capabilities;
mod catalog;
mod connection;
mod diagnostics;
mod global;
mod global_state;
mod init;
mod pool;
mod prelude;
mod query;
mod runnable;
mod statement;
mod stream;
mod transaction;
mod xa;

#[cfg(test)]
mod tests;

pub use bulk::*;
pub use capabilities::*;
pub use catalog::*;
pub use connection::*;
pub use diagnostics::*;
pub use init::*;
pub use pool::*;
pub use query::*;
pub use statement::*;
pub use stream::*;
pub use transaction::*;
pub use xa::*;

/// Default rows per batch when caller passes 0 to odbc_stream_start_batched.
pub use global_state::{DEFAULT_CHUNK_SIZE, DEFAULT_FETCH_SIZE};
