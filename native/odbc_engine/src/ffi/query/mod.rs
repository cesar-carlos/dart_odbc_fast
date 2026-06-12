// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

mod r#async;
mod helpers;
mod sync;

pub use r#async::*;
pub use sync::*;
