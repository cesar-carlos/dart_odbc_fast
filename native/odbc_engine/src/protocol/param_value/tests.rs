use super::*;
use odbc_api::{
    handles::{HasDataType, ParameterDescription},
    DataType, Nullability,
};
use std::num::NonZeroUsize;

#[test]
fn test_param_value_null_roundtrip() {
    let p = ParamValue::Null;
    let enc = p.serialize();
    let (dec, n) = ParamValue::deserialize(&enc).unwrap();
    assert_eq!(dec, ParamValue::Null);
    assert_eq!(n, enc.len());
}

#[test]
fn test_param_value_string_roundtrip() {
    let p = ParamValue::String("hello".to_string());
    let enc = p.serialize();
    let (dec, n) = ParamValue::deserialize(&enc).unwrap();
    assert_eq!(dec, p);
    assert_eq!(n, enc.len());
}

#[test]
fn test_param_value_integer_roundtrip() {
    let p = ParamValue::Integer(42);
    let enc = p.serialize();
    let (dec, n) = ParamValue::deserialize(&enc).unwrap();
    assert_eq!(dec, p);
    assert_eq!(n, enc.len());
}

#[test]
fn test_param_value_bigint_roundtrip() {
    let p = ParamValue::BigInt(1234567890123456789i64);
    let enc = p.serialize();
    let (dec, n) = ParamValue::deserialize(&enc).unwrap();
    assert_eq!(dec, p);
    assert_eq!(n, enc.len());
}

#[test]
fn test_param_value_decimal_roundtrip() {
    let p = ParamValue::Decimal("3.14159".to_string());
    let enc = p.serialize();
    let (dec, n) = ParamValue::deserialize(&enc).unwrap();
    assert_eq!(dec, p);
    assert_eq!(n, enc.len());
}

#[test]
fn test_param_value_binary_roundtrip() {
    let p = ParamValue::Binary(vec![1, 2, 3, 0xff]);
    let enc = p.serialize();
    let (dec, n) = ParamValue::deserialize(&enc).unwrap();
    assert_eq!(dec, p);
    assert_eq!(n, enc.len());
}

#[test]
fn test_param_value_ref_cursor_out_roundtrip() {
    let p = ParamValue::RefCursorOut;
    let enc = p.serialize();
    assert_eq!(enc, vec![6, 0, 0, 0, 0]);
    let (dec, n) = ParamValue::deserialize(&enc).unwrap();
    assert_eq!(dec, p);
    assert_eq!(n, enc.len());
}

#[test]
fn test_deserialize_params_empty() {
    let out = deserialize_params(&[]).unwrap();
    assert!(out.is_empty());
}

#[test]
fn test_serialize_deserialize_params_mixed() {
    let params = vec![
        ParamValue::Integer(1),
        ParamValue::String("a".to_string()),
        ParamValue::Null,
    ];
    let enc = serialize_params(&params);
    let dec = deserialize_params(&enc).unwrap();
    assert_eq!(dec, params);
}

#[test]
fn test_deserialize_too_short() {
    let r = ParamValue::deserialize(&[0u8, 0, 0]);
    assert!(r.is_err());
}

#[test]
fn test_has_null_param_no_null() {
    let params = vec![
        ParamValue::Integer(1),
        ParamValue::String("test".to_string()),
        ParamValue::BigInt(100),
    ];
    assert!(!has_null_param(&params));
}

#[test]
fn test_has_null_param_with_null() {
    let params = vec![
        ParamValue::Integer(1),
        ParamValue::Null,
        ParamValue::String("test".to_string()),
    ];
    assert!(has_null_param(&params));
}

#[test]
fn test_has_null_param_all_null() {
    let params = vec![ParamValue::Null, ParamValue::Null];
    assert!(has_null_param(&params));
}

#[test]
fn test_has_null_param_empty() {
    let params = vec![];
    assert!(!has_null_param(&params));
}

#[test]
fn test_param_count_exceeds_limit_true() {
    let params = vec![
        ParamValue::Integer(1),
        ParamValue::Integer(2),
        ParamValue::Integer(3),
    ];
    assert!(param_count_exceeds_limit(&params, 2));
}

#[test]
fn test_param_count_exceeds_limit_false() {
    let params = vec![ParamValue::Integer(1), ParamValue::Integer(2)];
    assert!(!param_count_exceeds_limit(&params, 10));
}

#[test]
fn test_param_count_exceeds_limit_equal() {
    let params = vec![ParamValue::Null, ParamValue::Null];
    assert!(!param_count_exceeds_limit(&params, 2));
}

#[test]
fn test_max_param_string_len_empty() {
    let params = vec![];
    assert_eq!(max_param_string_len(&params), 1);
}

#[test]
fn test_max_param_string_len_strings() {
    let params = vec![
        ParamValue::String("a".to_string()),
        ParamValue::String("abc".to_string()),
        ParamValue::String("ab".to_string()),
    ];
    assert_eq!(max_param_string_len(&params), 3);
}

#[test]
fn test_max_param_string_len_decimal() {
    let params = vec![
        ParamValue::Decimal("1.5".to_string()),
        ParamValue::Decimal("12.345".to_string()),
    ];
    assert_eq!(max_param_string_len(&params), 6);
}

#[test]
fn test_max_param_string_len_binary() {
    let params = vec![
        ParamValue::Binary(vec![1, 2]),
        ParamValue::Binary(vec![1, 2, 3, 4]),
    ];
    assert_eq!(max_param_string_len(&params), 8);
}

#[test]
fn test_max_param_string_len_mixed() {
    let params = vec![
        ParamValue::Integer(42),
        ParamValue::String("hello world".to_string()),
        ParamValue::Binary(vec![1, 2, 3]),
    ];
    assert_eq!(max_param_string_len(&params), 11);
}

#[test]
fn test_param_values_to_strings_with_null() {
    let params = vec![
        ParamValue::String("test".to_string()),
        ParamValue::Null,
        ParamValue::Integer(42),
    ];
    let result = param_values_to_strings(&params).unwrap();
    assert_eq!(result.len(), 3);
    assert_eq!(result[0], Some("test".to_string()));
    assert_eq!(result[1], None);
    assert_eq!(result[2], Some("42".to_string()));
}

#[test]
fn test_param_values_to_strings_decimal_and_binary() {
    let params = vec![
        ParamValue::Decimal("3.14".to_string()),
        ParamValue::Binary(vec![0xab, 0xcd]),
    ];
    let result = param_values_to_strings(&params).unwrap();
    assert_eq!(result.len(), 2);
    assert_eq!(result[0], Some("3.14".to_string()));
    assert_eq!(result[1], Some("abcd".to_string()));
}

#[test]
fn test_deserialize_buffer_truncated() {
    let enc = ParamValue::String("hello".to_string()).serialize();
    let truncated = &enc[0..enc.len() - 2];
    let result = ParamValue::deserialize(truncated);
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("truncated"));
}

#[test]
fn test_deserialize_invalid_utf8_string() {
    let mut data = vec![TAG_STRING, 0, 0, 0, 2];
    data.extend_from_slice(&[0xFF, 0xFE]);
    let result = ParamValue::deserialize(&data);
    assert!(result.is_err());
}

#[test]
fn test_deserialize_integer_wrong_length() {
    let mut data = vec![TAG_INTEGER, 0, 0, 0, 2];
    data.extend_from_slice(&[1, 2]);
    let result = ParamValue::deserialize(&data);
    assert!(result.is_err());
}

#[test]
fn test_deserialize_bigint_wrong_length() {
    let mut data = vec![TAG_BIGINT, 0, 0, 0, 4];
    data.extend_from_slice(&[1, 2, 3, 4]);
    let result = ParamValue::deserialize(&data);
    assert!(result.is_err());
}

#[test]
fn test_deserialize_invalid_utf8_decimal() {
    let mut data = vec![TAG_DECIMAL, 0, 0, 0, 2];
    data.extend_from_slice(&[0x80, 0xFF]);
    let result = ParamValue::deserialize(&data);
    assert!(result.is_err());
}

#[test]
fn test_deserialize_unknown_tag() {
    let data = vec![0xFF, 0, 0, 0, 0];
    let result = ParamValue::deserialize(&data);
    assert!(result.is_err());
    assert!(result
        .unwrap_err()
        .to_string()
        .contains("Unknown ParamValue tag"));
}

#[test]
fn test_deserialize_rejects_huge_payload_length_before_slice() {
    let data = vec![TAG_STRING, 0xff, 0xff, 0xff, 0xff];

    let result = ParamValue::deserialize(&data);

    assert!(result.unwrap_err().to_string().contains("payload length"));
}

#[test]
fn test_serialize_params_rejects_too_many_params() {
    let params = vec![ParamValue::Null; MAX_PARAM_COUNT + 1];

    let result = try_serialize_params(&params);

    assert!(result.unwrap_err().to_string().contains("Parameter count"));
}

#[test]
fn test_deserialize_params_rejects_too_many_params() {
    let enc_one = ParamValue::Null.try_serialize().expect("ok");
    let mut buf = Vec::new();
    for _ in 0..(MAX_PARAM_COUNT + 1) {
        buf.extend_from_slice(&enc_one);
    }
    let err = deserialize_params(&buf).expect_err("decode must fail");
    assert!(err.to_string().contains("Parameter count exceeds limit"));
}

#[test]
fn test_param_values_to_strings_rejects_ref_cursor() {
    let r = param_values_to_strings(&[ParamValue::RefCursorOut]);
    let msg = r.expect_err("RefCursor out").to_string();
    assert!(msg.contains("not convertible to string"));
}

#[test]
fn test_param_value_to_input_parameter_accepts_integer_and_binary() {
    let int_param =
        param_value_to_input_parameter(&ParamValue::Integer(7)).expect("int param should bind");
    let binary_param = param_value_to_input_parameter(&ParamValue::Binary(vec![1, 2, 3]))
        .expect("binary param should bind");

    assert_eq!(int_param.data_type(), 4_i32.data_type());
    assert_eq!(
        binary_param.data_type(),
        vec![1_u8, 2, 3].into_parameter().data_type()
    );
}

#[test]
fn test_param_value_to_input_parameter_rejects_ref_cursor() {
    let err = match param_value_to_input_parameter(&ParamValue::RefCursorOut) {
        Ok(_) => panic!("RefCursorOut must not bind as input"),
        Err(err) => err,
    };
    assert!(err.to_string().contains("not bindable as an input"));
}

#[test]
fn test_param_values_to_input_params_with_descriptions_uses_integer_null_type() {
    let params = [ParamValue::Null];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::Integer,
    }];

    let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
        .expect("described NULL should bind");

    assert_eq!(bound.len(), 1);
    assert_eq!(bound[0].data_type(), 4_i32.data_type());
}

#[test]
fn test_param_values_to_input_params_with_descriptions_uses_binary_null_type() {
    let params = [ParamValue::Null];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::Varbinary {
            length: Some(NonZeroUsize::new(32).expect("non-zero")),
        },
    }];

    let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
        .expect("binary NULL should bind");

    assert_eq!(bound.len(), 1);
    assert_eq!(
        bound[0].data_type(),
        DataType::Varbinary {
            length: Some(NonZeroUsize::new(32).expect("non-zero")),
        },
    );
}

#[test]
fn test_param_values_to_input_params_with_descriptions_rejects_non_nullable_null() {
    let params = [ParamValue::Null];
    let descriptions = [ParameterDescription {
        nullability: Nullability::NoNulls,
        data_type: DataType::Integer,
    }];

    let err = match param_values_to_input_params_with_descriptions(&params, &descriptions) {
        Ok(_) => panic!("non-nullable metadata must reject NULL"),
        Err(err) => err,
    };

    assert!(err.to_string().contains("does not accept NULL"));
}

#[test]
fn test_param_values_to_input_params_with_inference_promotes_integer_family_to_bigint() {
    let params = [
        ParamValue::Integer(7),
        ParamValue::Null,
        ParamValue::BigInt(9),
    ];

    let bound = param_values_to_input_params_with_inference(&params)
        .expect("inference should succeed")
        .expect("mixed integer family should infer");

    assert_eq!(bound.len(), 3);
    assert_eq!(bound[0].data_type(), DataType::BigInt);
    assert_eq!(bound[1].data_type(), DataType::BigInt);
    assert_eq!(bound[2].data_type(), DataType::BigInt);
}

#[test]
fn test_param_values_to_input_params_with_inference_returns_none_for_mixed_families() {
    let params = [
        ParamValue::Integer(7),
        ParamValue::Null,
        ParamValue::String("x".into()),
    ];

    let bound =
        param_values_to_input_params_with_inference(&params).expect("inference should not error");

    assert!(bound.is_none());
}

#[test]
fn test_try_serialize_string_rejects_huge_payload() {
    let s = "x".repeat(MAX_PARAM_VALUE_PAYLOAD_LEN + 1);
    let r = ParamValue::String(s).try_serialize();
    let msg = r.expect_err("oversize").to_string();
    assert!(msg.contains("ParamValue::String"));
    assert!(msg.contains("exceeds limit"));
}

#[test]
fn test_deserialize_ref_cursor_rejects_non_empty_payload() {
    let mut data = vec![TAG_REF_CURSOR_OUT];
    data.extend_from_slice(&1u32.to_le_bytes());
    data.push(0);
    let err = ParamValue::deserialize(&data).expect_err("non-empty ref cursor");
    assert!(
        err.to_string().contains("0-byte payload"),
        "unexpected: {err:?}"
    );
}

#[test]
fn test_deserialize_params_rejects_incomplete_second_param() {
    let mut buf = ParamValue::Null.serialize();
    buf.push(0xff);
    let err = deserialize_params(&buf).expect_err("trailing/incomplete");
    assert!(err.to_string().contains("too short"), "unexpected: {err:?}");
}

#[test]
fn test_param_values_to_strings_empty_binary_hex() {
    let params = [ParamValue::Binary(vec![])];
    let out = param_values_to_strings(&params).expect("strings");
    assert_eq!(out.len(), 1);
    assert_eq!(out[0], Some(String::new()));
}

#[test]
fn should_reject_description_count_mismatch_when_binding() {
    let params = [ParamValue::Integer(1), ParamValue::Integer(2)];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::Integer,
    }];
    let err = match param_values_to_input_params_with_descriptions(&params, &descriptions) {
        Ok(_) => panic!("count mismatch should fail"),
        Err(err) => err,
    };
    assert!(err.to_string().contains("does not match parameter count"));
}

#[test]
fn should_bind_null_with_smallint_description() {
    let params = [ParamValue::Null];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::SmallInt,
    }];
    let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
        .expect("smallint null");
    assert_eq!(bound[0].data_type(), DataType::SmallInt);
}

#[test]
fn should_bind_integer_with_unknown_description_type() {
    let params = [ParamValue::Integer(9)];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::Unknown,
    }];
    let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
        .expect("fallback bind");
    assert_eq!(bound[0].data_type(), 4_i32.data_type());
}

#[test]
fn should_return_none_inference_when_ref_cursor_present() {
    let params = [ParamValue::Integer(1), ParamValue::RefCursorOut];
    let bound = param_values_to_input_params_with_inference(&params).expect("inference ok");
    assert!(bound.is_none());
}

#[test]
fn should_reject_huge_decimal_try_serialize() {
    let s = "9".repeat(MAX_PARAM_VALUE_PAYLOAD_LEN + 1);
    let err = ParamValue::Decimal(s)
        .try_serialize()
        .expect_err("oversize");
    assert!(err.to_string().contains("ParamValue::Decimal"));
}

#[test]
fn should_reject_huge_binary_try_serialize() {
    let b = vec![0u8; MAX_PARAM_VALUE_PAYLOAD_LEN + 1];
    let err = ParamValue::Binary(b).try_serialize().expect_err("oversize");
    assert!(err.to_string().contains("ParamValue::Binary"));
}

#[test]
fn test_deserialize_binary_truncated_payload() {
    let enc = ParamValue::Binary(vec![1, 2, 3]).serialize();
    let truncated = &enc[..enc.len() - 1];
    let err = ParamValue::deserialize(truncated).expect_err("truncated binary");
    assert!(err.to_string().contains("truncated"));
}

#[test]
fn test_deserialize_length_overflow_at_consumed_boundary() {
    let data = vec![TAG_NULL, 0xff, 0xff, 0xff, 0xff];
    let err = ParamValue::deserialize(&data).expect_err("overflow");
    assert!(
        err.to_string().contains("payload length") || err.to_string().contains("length overflow")
    );
}

#[test]
fn should_bind_null_with_real_description() {
    let params = [ParamValue::Null];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::Real,
    }];
    let bound =
        param_values_to_input_params_with_descriptions(&params, &descriptions).expect("real null");
    assert_eq!(bound[0].data_type(), DataType::Real);
}

#[test]
fn should_bind_null_with_float_description() {
    let params = [ParamValue::Null];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::Float { precision: 10 },
    }];
    let bound =
        param_values_to_input_params_with_descriptions(&params, &descriptions).expect("float null");
    assert_eq!(bound[0].data_type(), DataType::Float { precision: 10 });
}

#[test]
fn should_bind_null_with_date_description_via_text_null_box() {
    let params = [ParamValue::Null];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::Date,
    }];
    let bound =
        param_values_to_input_params_with_descriptions(&params, &descriptions).expect("date null");
    assert_eq!(bound[0].data_type(), DataType::Date);
}

#[test]
fn should_infer_decimal_family_for_null_and_decimal() {
    let params = [ParamValue::Null, ParamValue::Decimal("1.0".into())];
    let bound = param_values_to_input_params_with_inference(&params)
        .expect("infer")
        .expect("decimal family");
    assert_eq!(bound.len(), 2);
    assert!(matches!(
        bound[0].data_type(),
        DataType::Varchar { length: None }
    ));
}

#[test]
fn should_infer_string_family_for_null_and_string() {
    let params = [ParamValue::Null, ParamValue::String("x".into())];
    let bound = param_values_to_input_params_with_inference(&params)
        .expect("infer")
        .expect("string family");
    assert_eq!(bound.len(), 2);
    assert!(matches!(
        bound[0].data_type(),
        DataType::Varchar { length: None }
    ));
}

#[test]
fn should_infer_binary_family_for_null_and_binary() {
    let params = [ParamValue::Null, ParamValue::Binary(vec![0xAB])];
    let bound = param_values_to_input_params_with_inference(&params)
        .expect("infer")
        .expect("binary family");
    assert_eq!(bound.len(), 2);
    assert!(matches!(
        bound[0].data_type(),
        DataType::Varbinary { length: None }
    ));
}

#[test]
fn test_param_values_to_input_params_maps_all_bindable_variants() {
    let params = [
        ParamValue::String("s".into()),
        ParamValue::BigInt(9),
        ParamValue::Decimal("1".into()),
    ];
    let bound = param_values_to_input_params(&params).expect("bind all");
    assert_eq!(bound.len(), 3);
}

#[test]
fn test_param_values_to_strings_unicode() {
    let params = [ParamValue::String("日本語".into())];
    let out = param_values_to_strings(&params).expect("unicode");
    assert_eq!(out[0].as_deref(), Some("日本語"));
}

#[test]
fn should_bind_null_with_double_description() {
    let params = [ParamValue::Null];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::Double,
    }];
    let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
        .expect("double null");
    assert_eq!(bound[0].data_type(), DataType::Double);
}

#[test]
fn should_bind_null_with_binary_family_description() {
    let params = [ParamValue::Null];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::LongVarbinary { length: None },
    }];
    let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
        .expect("long varbinary null");
    assert_eq!(
        bound[0].data_type(),
        DataType::LongVarbinary { length: None }
    );
}

#[test]
fn should_infer_integer_family_without_bigint_values() {
    let params = [
        ParamValue::Integer(1),
        ParamValue::Null,
        ParamValue::Integer(2),
    ];
    let bound = param_values_to_input_params_with_inference(&params)
        .expect("infer")
        .expect("integer family");
    assert_eq!(bound.len(), 3);
    assert_eq!(bound[0].data_type(), DataType::Integer);
    assert_eq!(bound[1].data_type(), DataType::Integer);
}

#[test]
fn should_bind_bigint_with_bigint_description() {
    let params = [ParamValue::BigInt(42)];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::BigInt,
    }];
    let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
        .expect("bigint bind");
    assert_eq!(bound[0].data_type(), DataType::BigInt);
}

#[test]
fn should_map_null_only_to_default_input_parameter() {
    let bound = param_values_to_input_params(&[ParamValue::Null]).expect("null bind");
    assert_eq!(bound.len(), 1);
}

#[test]
fn should_bind_null_with_tinyint_and_bit_descriptions() {
    for data_type in [DataType::TinyInt, DataType::Bit] {
        let params = [ParamValue::Null];
        let descriptions = [ParameterDescription {
            nullability: Nullability::Nullable,
            data_type,
        }];
        let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
            .expect("nullable bind");
        assert_eq!(bound[0].data_type(), data_type);
    }
}

#[test]
fn should_roundtrip_via_try_serialize() {
    let p = ParamValue::String("via try".to_string());
    let enc = p.try_serialize().expect("try_serialize");
    let (dec, n) = ParamValue::deserialize(&enc).expect("deserialize");
    assert_eq!(dec, p);
    assert_eq!(n, enc.len());
}

#[test]
fn should_bind_null_via_default_input_parameter() {
    let bound = param_value_to_input_parameter(&ParamValue::Null).expect("null bind");
    assert_eq!(
        bound.data_type(),
        Option::<String>::None.into_parameter().data_type()
    );
}

#[test]
fn should_bind_integer_with_smallint_description_type() {
    let params = [ParamValue::Integer(12)];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::SmallInt,
    }];
    let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
        .expect("smallint integer");
    assert_eq!(bound[0].data_type(), DataType::SmallInt);
}

#[test]
fn should_bind_bigint_with_bigint_description_type() {
    let params = [ParamValue::BigInt(99)];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::BigInt,
    }];
    let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
        .expect("bigint bind");
    assert_eq!(bound[0].data_type(), DataType::BigInt);
}

#[test]
fn should_bind_null_with_unknown_description_when_inference_succeeds() {
    let params = [ParamValue::Null, ParamValue::String("x".into())];
    let descriptions = [
        ParameterDescription {
            nullability: Nullability::Nullable,
            data_type: DataType::Unknown,
        },
        ParameterDescription {
            nullability: Nullability::Nullable,
            data_type: DataType::Unknown,
        },
    ];
    let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
        .expect("inferred null");
    assert!(matches!(
        bound[0].data_type(),
        DataType::Varchar { length: None }
    ));
}

#[test]
fn should_serialize_params_via_try_serialize_params() {
    let params = vec![ParamValue::Integer(1), ParamValue::Null];
    let enc = try_serialize_params(&params).expect("try serialize list");
    let dec = deserialize_params(&enc).expect("deserialize list");
    assert_eq!(dec, params);
}

#[test]
fn should_ignore_ref_cursor_in_max_param_string_len() {
    let params = [ParamValue::RefCursorOut, ParamValue::String("ab".into())];
    assert_eq!(max_param_string_len(&params), 2);
}

#[test]
fn should_bind_null_with_numeric_family_description() {
    let params = [ParamValue::Null];
    let descriptions = [ParameterDescription {
        nullability: Nullability::Nullable,
        data_type: DataType::Numeric {
            precision: 10,
            scale: 2,
        },
    }];
    let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
        .expect("numeric null");
    assert_eq!(
        bound[0].data_type(),
        DataType::Numeric {
            precision: 10,
            scale: 2
        }
    );
}
