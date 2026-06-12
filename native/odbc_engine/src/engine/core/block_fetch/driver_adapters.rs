use super::MAX_INLINE_VAR_LEN_BYTES;
use crate::error::{OdbcError, Result};
use crate::protocol::OdbcType;
use odbc_api::buffers::BufferDesc;
use odbc_api::{DataType, ResultSetMetadata};

/// Decide whether the current cursor can be served by the block-cursor
/// path. Returns the per-column [`BufferDesc`]s ready for
/// `ColumnarAnyBuffer::try_from_descs` when every column is bindable, or
/// `None` if at least one column would force the legacy fallback.
///
/// `column_types` must already be populated by the caller using the same
/// `describe_columns` helper that fills `RowBuffer::columns`, so the
/// `OdbcType → BufferDesc` mapping stays consistent with the wire format.
pub fn plan_buffer_descs<C>(
    cursor: &mut C,
    column_types: &[OdbcType],
) -> Result<Option<Vec<BufferDesc>>>
where
    C: ResultSetMetadata,
{
    let mut descs = Vec::with_capacity(column_types.len());
    for (idx, &odbc_type) in column_types.iter().enumerate() {
        // ODBC column indices are 1-based; the slice is 0-based.
        let col_idx: u16 = (idx + 1)
            .try_into()
            .map_err(|_| OdbcError::InternalError(format!("Column index {idx} overflows u16")))?;
        let data_type = cursor.col_data_type(col_idx).map_err(OdbcError::from)?;
        match buffer_desc_for(odbc_type, &data_type) {
            Some(desc) => descs.push(desc),
            None => return Ok(None),
        }
    }
    Ok(Some(descs))
}

pub(crate) fn buffer_desc_for(odbc_type: OdbcType, data_type: &DataType) -> Option<BufferDesc> {
    match odbc_type {
        OdbcType::Integer => Some(BufferDesc::I32 { nullable: true }),
        OdbcType::BigInt => Some(BufferDesc::I64 { nullable: true }),
        OdbcType::Binary => binary_buffer_desc(data_type),
        // Sprint 4 follow-up B5: temporal types can be bound natively so
        // we skip the driver-side WCHAR transcoding for the common case.
        // The formatting we apply afterwards uses ISO 8601 with
        // 6-digit microseconds for `Timestamp` — a precision shared by
        // PostgreSQL, MySQL/MariaDB, Snowflake, Oracle. SQL Server
        // produces 7-digit (100-ns) fractions in its WCHAR path; the
        // last digit is dropped here, which downstream Dart datetime
        // parsers tolerate. Callers needing the exact driver string
        // can opt out via `default-features = false`.
        OdbcType::Date => Some(BufferDesc::Date { nullable: true }),
        OdbcType::Time => Some(BufferDesc::Time { nullable: true }),
        OdbcType::Timestamp => Some(BufferDesc::Timestamp { nullable: true }),
        // All other OdbcType variants are sent as wide text through the
        // existing wire format (UTF-16 LE → UTF-8). Keeping this consistent
        // matches `CellReader::read_text` and `CellReader::read_wide_text`.
        _ => wide_text_buffer_desc(data_type),
    }
}

fn binary_buffer_desc(data_type: &DataType) -> Option<BufferDesc> {
    let length = match data_type {
        DataType::Binary { length: Some(n) } | DataType::Varbinary { length: Some(n) } => n.get(),
        // LongVarbinary or unknown length: fall back to per-cell.
        _ => return None,
    };
    if length == 0 || length > MAX_INLINE_VAR_LEN_BYTES {
        return None;
    }
    Some(BufferDesc::Binary { length })
}

fn wide_text_buffer_desc(data_type: &DataType) -> Option<BufferDesc> {
    let utf16_chars = data_type.utf16_len()?.get();
    // 2 bytes per UTF-16 code unit + 1 indicator entry per row.
    if utf16_chars == 0 || utf16_chars * 2 > MAX_INLINE_VAR_LEN_BYTES {
        return None;
    }
    Some(BufferDesc::WText {
        max_str_len: utf16_chars,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::num::NonZeroUsize;

    #[test]
    fn buffer_desc_for_integer_is_nullable_i32() {
        let desc = buffer_desc_for(OdbcType::Integer, &DataType::Integer);
        assert_eq!(desc, Some(BufferDesc::I32 { nullable: true }));
    }

    #[test]
    fn buffer_desc_for_bigint_is_nullable_i64() {
        let desc = buffer_desc_for(OdbcType::BigInt, &DataType::BigInt);
        assert_eq!(desc, Some(BufferDesc::I64 { nullable: true }));
    }

    #[test]
    fn buffer_desc_for_varchar_with_known_length_is_wide_text() {
        let dt = DataType::Varchar {
            length: NonZeroUsize::new(100),
        };
        let desc = buffer_desc_for(OdbcType::Varchar, &dt);
        // `DataType::utf16_len` reports the worst-case number of UTF-16
        // code units required, which is 2 * source-character-length to
        // accommodate surrogate pairs (see odbc-api doc example:
        // `Varchar(10).utf16_len() == 20`). So `Varchar(100)` becomes
        // `WText { max_str_len: 200 }` here.
        assert_eq!(desc, Some(BufferDesc::WText { max_str_len: 200 }));
    }

    #[test]
    fn buffer_desc_for_varchar_with_unknown_length_falls_back() {
        let dt = DataType::Varchar { length: None };
        assert!(buffer_desc_for(OdbcType::Varchar, &dt).is_none());
    }

    #[test]
    fn buffer_desc_for_long_varchar_with_unknown_length_falls_back() {
        let dt = DataType::WLongVarchar { length: None };
        assert!(buffer_desc_for(OdbcType::NVarchar, &dt).is_none());
    }

    #[test]
    fn buffer_desc_for_oversized_text_falls_back() {
        // `utf16_len` doubles the advertised char length to handle surrogate
        // pairs (`Varchar(n).utf16_len() == 2n`). The buffer size cap then
        // multiplies that by 2 bytes/code unit. Worst case: any varchar
        // wider than `MAX_INLINE_VAR_LEN_BYTES / 4` chars must fall back.
        let oversized_chars = MAX_INLINE_VAR_LEN_BYTES / 4 + 1;
        let dt = DataType::Varchar {
            length: NonZeroUsize::new(oversized_chars),
        };
        assert!(buffer_desc_for(OdbcType::Varchar, &dt).is_none());
    }

    #[test]
    fn buffer_desc_for_binary_with_known_length() {
        let dt = DataType::Varbinary {
            length: NonZeroUsize::new(64),
        };
        assert_eq!(
            buffer_desc_for(OdbcType::Binary, &dt),
            Some(BufferDesc::Binary { length: 64 })
        );
    }

    #[test]
    fn buffer_desc_for_long_varbinary_falls_back() {
        let dt = DataType::LongVarbinary {
            length: NonZeroUsize::new(1024),
        };
        // LongVarbinary deliberately falls back — driver-reported lengths
        // for LOB types are commonly unreliable.
        assert!(buffer_desc_for(OdbcType::Binary, &dt).is_none());
    }

    #[test]
    fn buffer_desc_for_oversized_binary_falls_back() {
        let dt = DataType::Binary {
            length: NonZeroUsize::new(MAX_INLINE_VAR_LEN_BYTES + 1),
        };
        assert!(buffer_desc_for(OdbcType::Binary, &dt).is_none());
    }

    #[test]
    fn buffer_desc_for_decimal_estimates_via_utf16_len() {
        let dt = DataType::Decimal {
            precision: 18,
            scale: 4,
        };
        // utf16_len returns precision + 2 for decimals; that becomes max_str_len.
        let desc = buffer_desc_for(OdbcType::Decimal, &dt);
        assert!(matches!(desc, Some(BufferDesc::WText { max_str_len }) if max_str_len > 0));
    }

    #[test]
    fn buffer_desc_for_date_now_routes_native() {
        // Sprint 4 follow-up B5 promoted `OdbcType::Date` from the
        // `WText` fallback to the native `Date` buffer. The old
        // expectation (`matches!(desc, Some(BufferDesc::WText { .. }))`)
        // is intentionally inverted here so a future revert (or a
        // partial revert of B5) trips this test.
        let desc = buffer_desc_for(OdbcType::Date, &DataType::Date);
        assert_eq!(desc, Some(BufferDesc::Date { nullable: true }));
    }

    #[test]
    fn buffer_desc_for_unknown_data_type_falls_back() {
        let desc = buffer_desc_for(OdbcType::Varchar, &DataType::Unknown);
        assert!(desc.is_none());
    }

    #[test]
    fn buffer_desc_for_date_routes_to_native_date() {
        assert_eq!(
            buffer_desc_for(OdbcType::Date, &DataType::Date),
            Some(BufferDesc::Date { nullable: true })
        );
    }

    #[test]
    fn buffer_desc_for_time_routes_to_native_time() {
        assert_eq!(
            buffer_desc_for(OdbcType::Time, &DataType::Time { precision: 0 }),
            Some(BufferDesc::Time { nullable: true })
        );
    }

    #[test]
    fn buffer_desc_for_timestamp_routes_to_native_timestamp() {
        assert_eq!(
            buffer_desc_for(OdbcType::Timestamp, &DataType::Timestamp { precision: 6 }),
            Some(BufferDesc::Timestamp { nullable: true })
        );
    }
}
