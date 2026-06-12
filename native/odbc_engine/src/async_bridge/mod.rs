use crate::error::OdbcError;
use std::sync::{Arc, OnceLock};
use tokio::runtime::Runtime;

static RUNTIME: OnceLock<std::result::Result<Arc<Runtime>, String>> = OnceLock::new();

fn get_runtime() -> Result<Arc<Runtime>, OdbcError> {
    let runtime = RUNTIME.get_or_init(|| {
        Runtime::new()
            .map(Arc::new)
            .map_err(|e| format!("Failed to create tokio runtime: {}", e))
    });

    match runtime {
        Ok(rt) => Ok(rt.clone()),
        Err(msg) => Err(OdbcError::InternalError(msg.clone())),
    }
}

/// Returns the stored runtime initialization error, if any.
///
/// Populated when [`init_runtime`] or the first [`get_runtime`] call fails.
/// Subsequent calls return the same message until process restart.
pub fn runtime_init_error() -> Option<&'static str> {
    RUNTIME
        .get()
        .and_then(|result| result.as_ref().err().map(String::as_str))
}

#[cfg(test)]
fn get_runtime_for_test() -> Result<Arc<Runtime>, OdbcError> {
    get_runtime()
}

/// Initialize the shared Tokio runtime. Idempotent on success.
///
/// On failure the error is stored in the [`RUNTIME`] `OnceLock` and is
/// consultable via [`runtime_init_error`].
pub fn init_runtime() -> Result<(), OdbcError> {
    get_runtime().map(|_| ())
}

#[allow(
    dead_code,
    reason = "Async FFI bridge helper; exercised by unit tests here; ODBC-ENG-421; remove by 2026-09-30."
)]
pub fn execute_async<F, R>(f: F) -> Result<R, OdbcError>
where
    F: std::future::Future<Output = Result<R, OdbcError>> + Send + 'static,
    R: Send + 'static,
{
    let runtime = get_runtime()?;
    runtime.block_on(f)
}

pub fn spawn_blocking_task<F>(f: F) -> Result<tokio::task::JoinHandle<()>, OdbcError>
where
    F: FnOnce() + Send + 'static,
{
    let runtime = get_runtime()?;
    Ok(runtime.spawn_blocking(f))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn test_init_runtime() {
        init_runtime().expect("runtime should initialize");
        init_runtime().expect("repeated init should succeed");
        init_runtime().expect("repeated init should succeed");
        assert!(runtime_init_error().is_none());
    }

    #[test]
    fn test_init_runtime_multiple_calls() {
        init_runtime().expect("runtime should initialize");
        let runtime1 = get_runtime_for_test().expect("runtime should initialize");
        init_runtime().expect("repeated init should succeed");
        let runtime2 = get_runtime_for_test().expect("runtime should initialize");

        assert!(Arc::ptr_eq(&runtime1, &runtime2));
    }

    #[test]
    fn test_get_runtime_singleton() {
        init_runtime().expect("runtime should initialize");
        let runtime1 = get_runtime_for_test().expect("runtime should initialize");
        let runtime2 = get_runtime_for_test().expect("runtime should initialize");

        assert!(Arc::ptr_eq(&runtime1, &runtime2));
    }

    #[test]
    fn test_get_runtime_creates_runtime() {
        init_runtime().expect("runtime should initialize");
        let runtime = get_runtime_for_test().expect("runtime should initialize");

        let future = async { Ok::<i32, OdbcError>(42) };

        let result = runtime.block_on(future);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 42);
    }

    #[test]
    fn test_execute_async_success() {
        init_runtime().expect("runtime should initialize");

        let future = async { Ok::<i32, OdbcError>(42) };

        let result = execute_async(future);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 42);
    }

    #[test]
    fn test_execute_async_error() {
        init_runtime().expect("runtime should initialize");

        let future = async { Err::<i32, OdbcError>(OdbcError::EmptyConnectionString) };

        let result = execute_async(future);
        assert!(result.is_err());
        match result {
            Err(OdbcError::EmptyConnectionString) => (),
            _ => panic!("Expected EmptyConnectionString error"),
        }
    }

    #[test]
    fn test_execute_async_string_result() {
        init_runtime().expect("runtime should initialize");

        let future = async { Ok::<String, OdbcError>("test".to_string()) };

        let result = execute_async(future);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "test");
    }

    #[test]
    fn test_execute_async_vec_result() {
        init_runtime().expect("runtime should initialize");

        let future = async { Ok::<Vec<i32>, OdbcError>(vec![1, 2, 3]) };

        let result = execute_async(future);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), vec![1, 2, 3]);
    }

    #[test]
    fn test_execute_async_async_operation() {
        init_runtime().expect("runtime should initialize");

        let future = async {
            std::thread::sleep(std::time::Duration::from_millis(10));
            Ok::<i32, OdbcError>(100)
        };

        let result = execute_async(future);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 100);
    }

    #[test]
    fn test_spawn_blocking_task_runs_closure() {
        init_runtime().expect("runtime should initialize");

        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let done = Arc::new(AtomicBool::new(false));
        let done_task = Arc::clone(&done);
        let handle = spawn_blocking_task(move || {
            done_task.store(true, Ordering::SeqCst);
        })
        .expect("spawn_blocking should succeed");

        let runtime = get_runtime_for_test().expect("runtime should initialize");
        runtime
            .block_on(handle)
            .expect("blocking task should finish");
        assert!(done.load(Ordering::SeqCst));
    }

    #[test]
    fn runtime_init_error_is_none_after_successful_init() {
        init_runtime().expect("runtime should initialize");
        assert!(runtime_init_error().is_none());
    }
}
