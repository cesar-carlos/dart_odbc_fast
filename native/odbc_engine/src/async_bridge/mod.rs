use crate::error::OdbcError;
use std::sync::{Arc, Mutex, OnceLock};
use tokio::runtime::Runtime;

static RUNTIME: OnceLock<std::result::Result<Arc<Mutex<Runtime>>, String>> = OnceLock::new();

fn get_runtime() -> Result<Arc<Mutex<Runtime>>, OdbcError> {
    let runtime = RUNTIME.get_or_init(|| {
        Runtime::new()
            .map(|rt| Arc::new(Mutex::new(rt)))
            .map_err(|e| format!("Failed to create tokio runtime: {}", e))
    });

    match runtime {
        Ok(rt) => Ok(rt.clone()),
        Err(msg) => Err(OdbcError::InternalError(msg.clone())),
    }
}

#[cfg(test)]
fn get_runtime_for_test() -> Result<Arc<Mutex<Runtime>>, OdbcError> {
    get_runtime()
}

#[allow(dead_code)]
pub fn init_runtime() {
    if let Err(e) = get_runtime() {
        eprintln!("init_runtime failed: {}", e);
    }
}

#[allow(dead_code)]
pub fn execute_async<F, R>(f: F) -> Result<R, OdbcError>
where
    F: std::future::Future<Output = Result<R, OdbcError>> + Send + 'static,
    R: Send + 'static,
{
    let runtime = get_runtime()?;
    let rt = runtime
        .lock()
        .map_err(|_| OdbcError::InternalError("Async runtime lock poisoned".to_string()))?;
    rt.block_on(f)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn test_init_runtime() {
        init_runtime();
        init_runtime();
        init_runtime();
    }

    #[test]
    fn test_init_runtime_multiple_calls() {
        init_runtime();
        let runtime1 = get_runtime_for_test().expect("runtime should initialize");
        init_runtime();
        let runtime2 = get_runtime_for_test().expect("runtime should initialize");

        assert!(Arc::ptr_eq(&runtime1, &runtime2));
    }

    #[test]
    fn test_get_runtime_singleton() {
        init_runtime();
        let runtime1 = get_runtime_for_test().expect("runtime should initialize");
        let runtime2 = get_runtime_for_test().expect("runtime should initialize");

        assert!(Arc::ptr_eq(&runtime1, &runtime2));
    }

    #[test]
    fn test_get_runtime_creates_runtime() {
        init_runtime();
        let runtime = get_runtime_for_test().expect("runtime should initialize");

        let future = async { Ok::<i32, OdbcError>(42) };

        let rt = runtime.lock().unwrap();
        let result = rt.block_on(future);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 42);
    }

    #[test]
    fn test_execute_async_success() {
        init_runtime();

        let future = async { Ok::<i32, OdbcError>(42) };

        let result = execute_async(future);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 42);
    }

    #[test]
    fn test_execute_async_error() {
        init_runtime();

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
        init_runtime();

        let future = async { Ok::<String, OdbcError>("test".to_string()) };

        let result = execute_async(future);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "test");
    }

    #[test]
    fn test_execute_async_vec_result() {
        init_runtime();

        let future = async { Ok::<Vec<i32>, OdbcError>(vec![1, 2, 3]) };

        let result = execute_async(future);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), vec![1, 2, 3]);
    }

    #[test]
    fn test_execute_async_async_operation() {
        init_runtime();

        let future = async {
            std::thread::sleep(std::time::Duration::from_millis(10));
            Ok::<i32, OdbcError>(100)
        };

        let result = execute_async(future);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 100);
    }
}
