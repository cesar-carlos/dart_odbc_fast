use super::*;
use crate::plugins::{
    mariadb::MariaDbPlugin, postgres::PostgresPlugin, sqlserver::SqlServerPlugin, PluginRegistry,
};
use crate::protocol::bound_param::{BoundParam, ParamDirection};
use crate::protocol::OdbcType;
use crate::protocol::ParamValue;

#[test]
fn test_execution_engine_new() {
    let engine = ExecutionEngine::new(100);
    assert_eq!(engine.prepared_cache.max_size(), 100);
    assert!(!engine.use_columnar);
    assert!(!engine.use_compression);
    assert!(engine.plugin_registry.is_some());
}

#[test]
fn test_execution_engine_with_columnar() {
    let engine = ExecutionEngine::with_columnar(50, true);
    assert_eq!(engine.prepared_cache.max_size(), 50);
    assert!(engine.use_columnar);
    assert!(engine.use_compression);
}

#[test]
fn test_execution_engine_with_columnar_no_compression() {
    let engine = ExecutionEngine::with_columnar(50, false);
    assert_eq!(engine.prepared_cache.max_size(), 50);
    assert!(engine.use_columnar);
    assert!(!engine.use_compression);
}

#[test]
fn test_execution_engine_with_plugin_registry() {
    let registry = Arc::new(PluginRegistry::default());
    let engine = ExecutionEngine::with_plugin_registry(200, registry.clone());
    assert_eq!(engine.prepared_cache.max_size(), 200);
    assert!(!engine.use_columnar);
    assert!(!engine.use_compression);
    assert!(engine.plugin_registry.is_some());
}

#[test]
fn test_set_connection_string() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("Driver={SQL Server};Server=localhost;");
    assert!(engine.plugin_registry.is_some());
}

#[test]
fn test_set_connection_string_with_invalid_string() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("invalid connection string");
    assert!(engine.plugin_registry.is_some());
}

#[test]
fn test_clear_cache() {
    let engine = ExecutionEngine::new(100);
    assert!(engine.prepared_cache.is_empty());

    engine.prepared_cache.get_or_insert("SELECT 1");
    assert!(!engine.prepared_cache.is_empty());

    engine.clear_cache();
    assert!(engine.prepared_cache.is_empty());
}

#[test]
fn test_get_metrics() {
    let engine = ExecutionEngine::new(100);
    let metrics = engine.get_metrics();
    assert!(Arc::ptr_eq(&engine.metrics, &metrics));
}

#[test]
fn test_get_tracer() {
    let engine = ExecutionEngine::new(100);
    let tracer = engine.get_tracer();
    assert!(Arc::ptr_eq(&engine.tracer, &tracer));
}

#[test]
fn test_prepared_cache_integration() {
    let engine = ExecutionEngine::new(10);
    assert_eq!(engine.prepared_cache.max_size(), 10);
    assert!(engine.prepared_cache.is_empty());

    engine.prepared_cache.get_or_insert("SELECT 1");
    assert_eq!(engine.prepared_cache.len(), 1);

    engine.prepared_cache.get_or_insert("SELECT 2");
    assert_eq!(engine.prepared_cache.len(), 2);

    engine.clear_cache();
    assert!(engine.prepared_cache.is_empty());
}

#[test]
fn test_set_connection_string_sqlserver() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("Driver={SQL Server};Server=localhost;Database=test;");

    let active_plugin = engine.active_plugin.read().unwrap();
    assert!(active_plugin.is_some());
    if let Some(ref plugin) = *active_plugin {
        assert_eq!(plugin.name(), "sqlserver");
    }
}

#[test]
fn test_set_connection_string_postgres() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("Driver={PostgreSQL};Server=localhost;Database=test;");

    let active_plugin = engine.active_plugin.read().unwrap();
    assert!(active_plugin.is_some());
    if let Some(ref plugin) = *active_plugin {
        assert_eq!(plugin.name(), "postgres");
    }
}

#[test]
fn test_set_connection_string_oracle() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("Driver={Oracle};Server=localhost;Database=test;");

    let active_plugin = engine.active_plugin.read().unwrap();
    assert!(active_plugin.is_some());
    if let Some(ref plugin) = *active_plugin {
        assert_eq!(plugin.name(), "oracle");
    }
}

#[test]
fn test_set_connection_string_sybase() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("Driver={Sybase};Server=localhost;Database=test;");

    let active_plugin = engine.active_plugin.read().unwrap();
    assert!(active_plugin.is_some());
    if let Some(ref plugin) = *active_plugin {
        assert_eq!(plugin.name(), "sybase");
    }
}

#[test]
fn test_set_connection_string_mssql_variant() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("Driver={MSSQL};Server=localhost;Database=test;");

    let active_plugin = engine.active_plugin.read().unwrap();
    assert!(active_plugin.is_some());
    if let Some(ref plugin) = *active_plugin {
        assert_eq!(plugin.name(), "sqlserver");
    }
}

#[test]
fn test_set_connection_string_postgresql_variant() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("Driver={PostgreSQL};Server=localhost;Database=test;");

    let active_plugin = engine.active_plugin.read().unwrap();
    assert!(active_plugin.is_some());
    if let Some(ref plugin) = *active_plugin {
        assert_eq!(plugin.name(), "postgres");
    }
}

#[test]
fn test_set_connection_string_sql_anywhere() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("Driver={SQL Anywhere};Server=localhost;Database=test;");

    let active_plugin = engine.active_plugin.read().unwrap();
    assert!(active_plugin.is_some());
    if let Some(ref plugin) = *active_plugin {
        assert_eq!(plugin.name(), "sybase");
    }
}

#[test]
fn test_set_connection_string_unknown_driver() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("Driver={UnknownDriver};Server=localhost;");

    let active_plugin = engine.active_plugin.read().unwrap();
    assert!(active_plugin.is_none());
}

#[test]
fn test_set_connection_string_empty() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("");

    let active_plugin = engine.active_plugin.read().unwrap();
    assert!(active_plugin.is_none());
}

#[test]
fn test_set_connection_string_case_insensitive() {
    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("DRIVER={SQL SERVER};SERVER=localhost;");

    let active_plugin = engine.active_plugin.read().unwrap();
    assert!(active_plugin.is_some());
    if let Some(ref plugin) = *active_plugin {
        assert_eq!(plugin.name(), "sqlserver");
    }
}

#[test]
fn test_set_connection_string_multiple_times() {
    let engine = ExecutionEngine::new(100);

    engine.set_connection_string("Driver={SQL Server};Server=localhost;");
    let active_plugin1 = engine.active_plugin.read().unwrap();
    assert!(active_plugin1.is_some());
    if let Some(ref plugin) = *active_plugin1 {
        assert_eq!(plugin.name(), "sqlserver");
    }
    drop(active_plugin1);

    engine.set_connection_string("Driver={PostgreSQL};Server=localhost;");
    let active_plugin2 = engine.active_plugin.read().unwrap();
    assert!(active_plugin2.is_some());
    if let Some(ref plugin) = *active_plugin2 {
        assert_eq!(plugin.name(), "postgres");
    }
}

#[test]
fn test_metrics_recording() {
    let engine = ExecutionEngine::new(100);
    let metrics = engine.get_metrics();

    let query_metrics = metrics.get_query_metrics();
    let initial_query_count = query_metrics.query_count;
    let initial_error_count = metrics.get_error_count();

    assert_eq!(initial_query_count, 0);
    assert_eq!(initial_error_count, 0);
}

#[test]
fn test_tracer_span_creation() {
    let engine = ExecutionEngine::new(100);
    let tracer = engine.get_tracer();

    let span_id = tracer.start_span("test_query".to_string());
    assert!(span_id > 0);

    let span = tracer.finish_span(span_id);
    assert!(span.is_some());
}

#[test]
fn test_tracer_multiple_spans() {
    let engine = ExecutionEngine::new(100);
    let tracer = engine.get_tracer();

    let span1 = tracer.start_span("query1".to_string());
    let span2 = tracer.start_span("query2".to_string());

    assert_ne!(span1, span2);

    let finished1 = tracer.finish_span(span1);
    let finished2 = tracer.finish_span(span2);

    assert!(finished1.is_some());
    assert!(finished2.is_some());
}

#[test]
fn test_prepared_cache_with_different_sql() {
    let engine = ExecutionEngine::new(5);

    engine.prepared_cache.get_or_insert("SELECT 1");
    engine.prepared_cache.get_or_insert("SELECT 2");
    engine.prepared_cache.get_or_insert("SELECT 3");
    engine.prepared_cache.get_or_insert("SELECT 4");
    engine.prepared_cache.get_or_insert("SELECT 5");

    assert_eq!(engine.prepared_cache.len(), 5);

    engine.prepared_cache.get_or_insert("SELECT 1");
    assert_eq!(engine.prepared_cache.len(), 5);
}

#[test]
fn test_prepared_cache_eviction() {
    let engine = ExecutionEngine::new(2);

    engine.prepared_cache.get_or_insert("SELECT 1");
    engine.prepared_cache.get_or_insert("SELECT 2");
    assert_eq!(engine.prepared_cache.len(), 2);

    engine.prepared_cache.get_or_insert("SELECT 3");
    assert_eq!(engine.prepared_cache.len(), 2);
}

#[test]
fn test_with_plugin_registry_custom() {
    let registry = Arc::new(PluginRegistry::new());
    let engine = ExecutionEngine::with_plugin_registry(150, registry.clone());

    assert_eq!(engine.prepared_cache.max_size(), 150);
    assert!(!engine.use_columnar);
    assert!(!engine.use_compression);
    assert!(engine.plugin_registry.is_some());
}

#[test]
fn test_with_columnar_compression_enabled() {
    let engine = ExecutionEngine::with_columnar(75, true);
    assert_eq!(engine.prepared_cache.max_size(), 75);
    assert!(engine.use_columnar);
    assert!(engine.use_compression);
}

#[test]
fn test_with_columnar_compression_disabled() {
    let engine = ExecutionEngine::with_columnar(75, false);
    assert_eq!(engine.prepared_cache.max_size(), 75);
    assert!(engine.use_columnar);
    assert!(!engine.use_compression);
}

#[test]
fn test_plugin_registry_default_has_plugins() {
    let registry = Arc::new(PluginRegistry::default());
    let engine = ExecutionEngine::with_plugin_registry(100, registry);

    engine.set_connection_string("Driver={SQL Server};Server=localhost;");
    let active_plugin = engine.active_plugin.read().unwrap();
    assert!(active_plugin.is_some());
}

#[test]
fn test_clear_cache_preserves_config() {
    let engine = ExecutionEngine::with_columnar(50, true);

    engine.prepared_cache.get_or_insert("SELECT 1");
    assert!(!engine.prepared_cache.is_empty());

    engine.clear_cache();
    assert!(engine.prepared_cache.is_empty());
    assert!(engine.use_columnar);
    assert!(engine.use_compression);
}

#[test]
fn test_get_metrics_returns_same_instance() {
    let engine = ExecutionEngine::new(100);
    let metrics1 = engine.get_metrics();
    let metrics2 = engine.get_metrics();

    assert!(Arc::ptr_eq(&metrics1, &metrics2));
}

#[test]
fn test_get_tracer_returns_same_instance() {
    let engine = ExecutionEngine::new(100);
    let tracer1 = engine.get_tracer();
    let tracer2 = engine.get_tracer();

    assert!(Arc::ptr_eq(&tracer1, &tracer2));
}

#[test]
fn should_treat_sqlstate_02000_as_no_more_results() {
    let err = OdbcError::Structured {
        sqlstate: [b'0', b'2', b'0', b'0', b'0'],
        native_code: 0,
        message: "no data".to_string(),
    };
    assert!(is_no_more_results(&err));
}

#[test]
fn should_not_treat_unrelated_errors_as_no_more_results() {
    assert!(!is_no_more_results(&OdbcError::ValidationError(
        "x".to_string()
    )));
    assert!(!is_no_more_results(&OdbcError::OdbcApi("fail".to_string())));
    let err = OdbcError::Structured {
        sqlstate: [b'4', b'2', b'S', b'0', b'2'],
        native_code: 18456,
        message: "login failed".to_string(),
    };
    assert!(!is_no_more_results(&err));
}

#[test]
fn should_leave_sql_unchanged_when_no_plugin_is_active() {
    let engine = ExecutionEngine::new(10);
    assert_eq!(
        engine.test_optimize_sql("SELECT * FROM t", None),
        "SELECT * FROM t"
    );
}

#[test]
fn should_apply_plugin_query_optimization_when_plugin_is_provided() {
    let engine = ExecutionEngine::new(10);
    let plugin = SqlServerPlugin::new();
    let optimized = engine.test_optimize_sql("SELECT * FROM t", Some(&plugin));
    assert!(optimized.contains("TOP 1000"));
}

#[test]
fn should_map_sql_type_via_plugin_when_plugin_is_provided() {
    let engine = ExecutionEngine::new(10);
    let plugin = SqlServerPlugin::new();
    assert_eq!(
        engine.test_map_sql_type(4, Some(&plugin)),
        OdbcType::Integer
    );
    assert_eq!(
        engine.test_map_sql_type(4, None),
        OdbcType::from_odbc_sql_type(4)
    );
}

#[test]
fn should_report_oracle_plugin_active_only_after_oracle_connection_string() {
    let engine = ExecutionEngine::new(10);
    assert!(!engine.test_is_oracle_plugin_active());
    engine.set_connection_string("Driver={Oracle};Server=localhost;");
    assert!(engine.test_is_oracle_plugin_active());
    engine.set_connection_string("Driver={SQL Server};Server=localhost;");
    assert!(!engine.test_is_oracle_plugin_active());
}

#[test]
fn should_reject_ref_cursor_out_when_oracle_plugin_is_not_active() {
    let bound = [BoundParam {
        direction: ParamDirection::Output,
        value: ParamValue::RefCursorOut,
    }];
    let err = ensure_ref_cursor_oracle_only(&bound, false)
        .expect_err("ref cursor without oracle should fail");
    let OdbcError::ValidationError(msg) = err else {
        panic!("expected ValidationError, got {err:?}");
    };
    assert!(msg.contains("ref_cursor_out_oracle_only"), "{msg}");
}

#[test]
fn should_allow_ref_cursor_gate_when_oracle_plugin_is_active() {
    let bound = [BoundParam {
        direction: ParamDirection::Output,
        value: ParamValue::RefCursorOut,
    }];
    ensure_ref_cursor_oracle_only(&bound, true).expect("oracle active should pass gate");
}

#[test]
fn should_skip_ref_cursor_gate_when_no_ref_cursor_markers() {
    let bound = [BoundParam {
        direction: ParamDirection::Input,
        value: ParamValue::Integer(1),
    }];
    ensure_ref_cursor_oracle_only(&bound, false).expect("no ref cursor should pass gate");
}

#[test]
fn should_not_treat_internal_or_odbc_api_errors_as_no_more_results() {
    assert!(!is_no_more_results(&OdbcError::InternalError(
        "x".to_string()
    )));
    assert!(!is_no_more_results(&OdbcError::OdbcApi(
        "SQL_NO_DATA".to_string()
    )));
}

#[test]
fn should_plan_direct_query_when_params_are_empty() {
    assert_eq!(
        plan_query_param_binding(&[]).expect("empty query plan"),
        QueryParamBindingPlan::DirectNoParams
    );
}

#[test]
fn should_plan_standard_query_for_non_null_params() {
    let params = vec![ParamValue::Integer(1), ParamValue::String("x".to_string())];
    assert_eq!(
        plan_query_param_binding(&params).expect("standard query plan"),
        QueryParamBindingPlan::PreparedStandard
    );
}

#[test]
fn should_plan_inference_query_for_homogeneous_nullable_integers() {
    let params = vec![ParamValue::Integer(1), ParamValue::Null];
    assert_eq!(
        plan_query_param_binding(&params).expect("inference query plan"),
        QueryParamBindingPlan::InferenceExecute
    );
}

#[test]
fn should_plan_null_aware_query_when_null_types_are_mixed() {
    let params = vec![
        ParamValue::String("a".to_string()),
        ParamValue::Integer(1),
        ParamValue::Null,
    ];
    assert_eq!(
        plan_query_param_binding(&params).expect("null-aware query plan"),
        QueryParamBindingPlan::PreparedNullAware
    );
}

#[test]
fn should_plan_multi_result_inference_for_homogeneous_integer_params() {
    let params = vec![ParamValue::Integer(1), ParamValue::Integer(2)];
    assert_eq!(
        plan_multi_result_param_binding(&params).expect("multi inference plan"),
        MultiResultParamBindingPlan::InferencePrealloc
    );
}

#[test]
fn should_plan_multi_result_standard_for_non_null_mixed_params() {
    let params = vec![ParamValue::String("a".to_string()), ParamValue::Integer(1)];
    assert_eq!(
        plan_multi_result_param_binding(&params).expect("multi standard plan"),
        MultiResultParamBindingPlan::PreparedStandard
    );
}

#[test]
fn should_plan_multi_result_null_aware_for_null_params_without_inference() {
    let params = vec![
        ParamValue::String("a".to_string()),
        ParamValue::Integer(1),
        ParamValue::Null,
    ];
    assert_eq!(
        plan_multi_result_param_binding(&params).expect("multi null-aware plan"),
        MultiResultParamBindingPlan::PreparedNullAware
    );
}

#[test]
fn should_plan_multi_result_standard_for_empty_params() {
    assert_eq!(
        plan_multi_result_param_binding(&[]).expect("empty multi plan"),
        MultiResultParamBindingPlan::PreparedStandard
    );
}

#[test]
fn should_activate_mariadb_plugin_from_connection_string() {
    let engine = ExecutionEngine::new(10);
    engine.set_connection_string("Driver={MariaDB};Server=localhost;Database=test;");
    let active = engine.active_plugin.read().unwrap();
    assert!(active.is_some());
    assert_eq!(active.as_ref().unwrap().name(), "mariadb");
}

#[test]
fn should_activate_mysql_plugin_from_connection_string() {
    let engine = ExecutionEngine::new(10);
    engine.set_connection_string("Driver={MySQL ODBC 8.0 Driver};Server=localhost;");
    let active = engine.active_plugin.read().unwrap();
    assert!(active.is_some());
    assert_eq!(active.as_ref().unwrap().name(), "mysql");
}

#[test]
fn should_apply_mariadb_limit_optimization_when_plugin_active() {
    let engine = ExecutionEngine::new(10);
    let plugin = MariaDbPlugin::new();
    let optimized = engine.test_optimize_sql("SELECT * FROM users", Some(&plugin));
    assert!(optimized.contains("LIMIT 1000"), "{optimized}");
}

#[test]
fn should_map_postgres_type_via_plugin() {
    let engine = ExecutionEngine::new(10);
    let plugin = PostgresPlugin::new();
    assert_eq!(
        engine.test_map_sql_type(4, Some(&plugin)),
        OdbcType::Integer
    );
    assert_eq!(
        engine.test_map_sql_type(999, Some(&plugin)),
        OdbcType::Varchar
    );
}

#[test]
fn should_map_odbc_row_count_none_to_zero() {
    assert_eq!(odbc_row_count_i64(None), 0);
    assert_eq!(odbc_row_count_i64(Some(0)), 0);
    assert_eq!(odbc_row_count_i64(Some(42)), 42);
}

#[test]
fn should_build_bound_params_first_item_as_row_count_when_no_cursor() {
    let item = bound_params_first_multi_item(false, 7, vec![1, 2, 3]);
    assert_eq!(item, MultiResultItem::RowCount(7));
}

#[test]
fn should_build_bound_params_first_item_as_result_set_when_cursor_present() {
    let body = vec![9, 8, 7];
    let item = bound_params_first_multi_item(true, 0, body.clone());
    assert_eq!(item, MultiResultItem::ResultSet(body));
}

#[test]
fn should_encode_empty_row_buffer_row_major() {
    let buffer = RowBuffer::new();
    let bytes = encode_query_result_payload(buffer, false, false).expect("encode");
    assert!(!bytes.is_empty());
}

#[test]
fn should_encode_empty_row_buffer_columnar_with_compression() {
    let buffer = RowBuffer::new();
    let bytes = encode_query_result_payload(buffer, true, true).expect("encode");
    assert!(!bytes.is_empty());
}

#[test]
fn should_encode_nonempty_row_buffer_row_major() {
    let mut buffer = RowBuffer::new();
    buffer.add_column("id".to_string(), OdbcType::Integer);
    buffer.add_row_vecs(vec![Some(1i32.to_le_bytes().to_vec())]);
    let bytes = encode_query_result_payload(buffer, false, false).expect("encode");
    assert!(!bytes.is_empty());
}

#[test]
fn should_not_treat_no_more_results_variant_as_sqlstate_02000() {
    assert!(!is_no_more_results(&OdbcError::NoMoreResults));
}

#[test]
fn should_not_treat_structured_non_02000_as_no_more_results() {
    let err = OdbcError::Structured {
        sqlstate: [b'0', b'1', b'0', b'0', b'0'],
        native_code: 0,
        message: "general".to_string(),
    };
    assert!(!is_no_more_results(&err));
}

#[test]
fn should_plan_query_standard_for_homogeneous_bigint_params_without_null() {
    let params = vec![ParamValue::BigInt(1), ParamValue::BigInt(2)];
    assert_eq!(
        plan_query_param_binding(&params).expect("bigint query plan"),
        QueryParamBindingPlan::PreparedStandard
    );
}

#[test]
fn should_plan_query_standard_for_bigint_and_string_without_null() {
    let params = vec![ParamValue::BigInt(1), ParamValue::String("x".to_string())];
    assert_eq!(
        plan_query_param_binding(&params).expect("mixed query plan"),
        QueryParamBindingPlan::PreparedStandard
    );
}

#[test]
fn should_plan_multi_result_inference_for_nullable_bigint_params() {
    let params = vec![ParamValue::BigInt(9), ParamValue::Null];
    assert_eq!(
        plan_multi_result_param_binding(&params).expect("nullable bigint multi"),
        MultiResultParamBindingPlan::InferencePrealloc
    );
}

#[test]
fn should_plan_multi_result_inference_for_mixed_integer_and_bigint() {
    let params = vec![ParamValue::Integer(1), ParamValue::BigInt(2)];
    assert_eq!(
        plan_multi_result_param_binding(&params).expect("promoted multi"),
        MultiResultParamBindingPlan::InferencePrealloc
    );
}

#[test]
fn should_plan_multi_result_inference_for_string_and_null_same_family() {
    let params = vec![ParamValue::String("a".to_string()), ParamValue::Null];
    assert_eq!(
        plan_multi_result_param_binding(&params).expect("string+null multi"),
        MultiResultParamBindingPlan::InferencePrealloc
    );
}

#[test]
fn should_plan_query_inference_for_nullable_bigint_params() {
    let params = vec![ParamValue::BigInt(9), ParamValue::Null];
    assert_eq!(
        plan_query_param_binding(&params).expect("nullable bigint query"),
        QueryParamBindingPlan::InferenceExecute
    );
}

#[test]
fn should_plan_query_null_aware_for_all_null_without_inference_family() {
    let params = vec![ParamValue::Null, ParamValue::Null];
    assert_eq!(
        plan_query_param_binding(&params).expect("all-null query"),
        QueryParamBindingPlan::PreparedNullAware
    );
}

#[test]
fn should_plan_multi_result_null_aware_for_all_null_without_inference() {
    let params = vec![ParamValue::Null];
    assert_eq!(
        plan_multi_result_param_binding(&params).expect("single null multi"),
        MultiResultParamBindingPlan::PreparedNullAware
    );
}

#[test]
fn should_map_negative_odbc_row_count_none_to_zero() {
    assert_eq!(odbc_row_count_i64(None), 0);
}

#[test]
fn should_encode_columnar_payload_with_multiple_rows() {
    let mut buffer = RowBuffer::new();
    buffer.add_column("n".to_string(), OdbcType::Integer);
    buffer.add_row_vecs(vec![Some(1i32.to_le_bytes().to_vec())]);
    buffer.add_row_vecs(vec![Some(2i32.to_le_bytes().to_vec())]);
    let bytes = {
        let mut columnar_buf = RowBuffer::new();
        columnar_buf.add_column("n".to_string(), OdbcType::Integer);
        columnar_buf.add_row_vecs(vec![Some(1i32.to_le_bytes().to_vec())]);
        columnar_buf.add_row_vecs(vec![Some(2i32.to_le_bytes().to_vec())]);
        encode_query_result_payload(columnar_buf, true, false).expect("columnar encode")
    };
    assert!(!bytes.is_empty());
    let row_major = encode_query_result_payload(buffer, false, false).expect("row-major");
    assert_ne!(bytes, row_major);
}

#[test]
fn should_apply_postgres_limit_optimization_when_plugin_provided() {
    let engine = ExecutionEngine::new(10);
    let plugin = PostgresPlugin::new();
    let optimized = engine.test_optimize_sql("SELECT * FROM t", Some(&plugin));
    assert!(optimized.contains("LIMIT"), "{optimized}");
}

#[test]
fn should_require_inference_input_params_for_nullable_integer_family() {
    let params = vec![ParamValue::Integer(1), ParamValue::Null];
    assert_eq!(
        plan_query_param_binding(&params).expect("plan"),
        QueryParamBindingPlan::InferenceExecute
    );
    let converted = require_inference_input_params(&params).expect("inference params");
    assert_eq!(converted.len(), 2);
}

#[test]
fn should_return_internal_error_when_inference_params_unavailable() {
    let params = vec![ParamValue::Null, ParamValue::Null];
    assert!(matches!(
        require_inference_input_params(&params),
        Err(OdbcError::InternalError(msg)) if msg.contains("binding plan mismatch")
    ));
    assert_eq!(
        plan_query_param_binding(&params).expect("plan"),
        QueryParamBindingPlan::PreparedNullAware
    );
}

#[test]
fn should_reject_ref_cursor_inout_when_oracle_inactive() {
    let bound = [BoundParam {
        direction: ParamDirection::InOut,
        value: ParamValue::RefCursorOut,
    }];
    let err = ensure_ref_cursor_oracle_only(&bound, false).expect_err("inout ref cursor");
    assert!(matches!(err, OdbcError::ValidationError(_)));
}
