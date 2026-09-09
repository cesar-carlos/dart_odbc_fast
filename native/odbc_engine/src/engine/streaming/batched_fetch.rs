//! Shared batched cursor drain for single- and multi-result streaming.

use super::columns::{describe_streaming_columns, encode_row_buffer_with_encoding_into};
use crate::engine::query::ResultEncoding;
use crate::error::{OdbcError, Result};
use crate::protocol::RowBuffer;
use odbc_api::{Cursor, ResultSetMetadata};

#[cfg(feature = "block-cursor-fetch")]
use crate::engine::core::block_fetch::{plan_buffer_descs, RowMajorBlockSession};
#[cfg(feature = "block-cursor-fetch")]
use crate::engine::core::columnar_fetch::ColumnarStreamingSession;
#[cfg(feature = "block-cursor-fetch")]
use crate::protocol::columnar::ColumnMetadata;
#[cfg(feature = "block-cursor-fetch")]
use crate::protocol::ColumnarEncoder;

/// Drain `cursor` in fetch-sized batches, invoking `on_batch` for each
/// encoded payload. Returns the cursor for callers that need
/// `into_stmt()` (multi-result).
pub(crate) fn drain_cursor_in_batches<C, F, T>(
    mut cursor: C,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    on_batch: &mut F,
    next_frame_tag: &mut T,
    cancel_check: impl Fn() -> bool,
) -> Result<C>
where
    C: Cursor + ResultSetMetadata,
    F: FnMut(Vec<u8>) -> Result<()>,
    T: FnMut() -> Option<u8>,
{
    let batch_size = fetch_size.max(1);
    let mut row_buffer = RowBuffer::new();
    let column_types = describe_streaming_columns(&mut cursor, &mut row_buffer)?;
    #[cfg(feature = "block-cursor-fetch")]
    let mut first_batch = true;
    #[cfg(not(feature = "block-cursor-fetch"))]
    let first_batch = true;

    #[cfg(feature = "block-cursor-fetch")]
    {
        let use_columnar = matches!(
            result_encoding,
            ResultEncoding::Columnar | ResultEncoding::ColumnarCompressed
        );
        let for_json = crate::engine::sqlserver_json::is_for_json_result(&row_buffer);

        if !for_json {
            if let Some(descs) = plan_buffer_descs(&mut cursor, &column_types)? {
                if use_columnar {
                    let column_metas: Vec<ColumnMetadata> = row_buffer
                        .columns
                        .iter()
                        .map(|c| ColumnMetadata {
                            name: c.name.clone(),
                            odbc_type: c.odbc_type,
                        })
                        .collect();
                    let compress = matches!(result_encoding, ResultEncoding::ColumnarCompressed);
                    let mut session = ColumnarStreamingSession::try_begin(
                        cursor,
                        column_metas,
                        column_types,
                        descs,
                        batch_size,
                    )?;
                    loop {
                        if cancel_check() {
                            return Err(OdbcError::Cancelled);
                        }
                        match session.fetch_next_batch_v2()? {
                            None => {
                                if first_batch {
                                    emit_row_buffer_batch(
                                        &mut row_buffer,
                                        result_encoding,
                                        on_batch,
                                        next_frame_tag,
                                    )?;
                                }
                                cursor = session.into_cursor()?;
                                break;
                            }
                            Some(v2) => {
                                let frame_tag = next_frame_tag();
                                let mut encoded = begin_batch_output(frame_tag);
                                ColumnarEncoder::encode_into(&mut encoded, v2, compress)?;
                                finish_batch_frame(&mut encoded, frame_tag)?;
                                on_batch(encoded)?;
                                first_batch = false;
                            }
                        }
                    }
                    return Ok(cursor);
                }

                let mut session =
                    RowMajorBlockSession::try_begin(cursor, column_types, descs, batch_size)?;
                loop {
                    if cancel_check() {
                        return Err(OdbcError::Cancelled);
                    }
                    row_buffer.rows.clear();
                    let fetched = session.fetch_next_batch(&mut row_buffer)?;
                    if fetched == 0 {
                        if first_batch {
                            emit_row_buffer_batch(
                                &mut row_buffer,
                                result_encoding,
                                on_batch,
                                next_frame_tag,
                            )?;
                        }
                        cursor = session.into_cursor()?;
                        break;
                    }
                    emit_row_buffer_batch(
                        &mut row_buffer,
                        result_encoding,
                        on_batch,
                        next_frame_tag,
                    )?;
                    first_batch = false;
                }
                return Ok(cursor);
            }
        }
    }

    let mut drain = LegacyBatchDrain {
        column_types: &column_types,
        batch_size,
        result_encoding,
        on_batch,
        next_frame_tag,
        row_buffer: &mut row_buffer,
        first_batch,
    };
    legacy_drain_cursor_in_batches(cursor, &mut drain, cancel_check)
}

struct LegacyBatchDrain<'a, F, T> {
    column_types: &'a [crate::protocol::OdbcType],
    batch_size: usize,
    result_encoding: ResultEncoding,
    on_batch: &'a mut F,
    next_frame_tag: &'a mut T,
    row_buffer: &'a mut RowBuffer,
    first_batch: bool,
}

fn legacy_drain_cursor_in_batches<C, F, T>(
    mut cursor: C,
    drain: &mut LegacyBatchDrain<'_, F, T>,
    cancel_check: impl Fn() -> bool,
) -> Result<C>
where
    C: Cursor,
    F: FnMut(Vec<u8>) -> Result<()>,
    T: FnMut() -> Option<u8>,
{
    loop {
        if cancel_check() {
            return Err(OdbcError::Cancelled);
        }

        drain.row_buffer.rows.clear();
        let _fetched = crate::engine::fetch::fetch_batch_into_row_buffer(
            &mut cursor,
            drain.column_types,
            drain.batch_size,
            drain.row_buffer,
        )?;

        if drain.row_buffer.row_count() == 0 {
            if drain.first_batch {
                emit_row_buffer_batch(
                    drain.row_buffer,
                    drain.result_encoding,
                    drain.on_batch,
                    drain.next_frame_tag,
                )?;
            }
            break;
        }

        emit_row_buffer_batch(
            drain.row_buffer,
            drain.result_encoding,
            drain.on_batch,
            drain.next_frame_tag,
        )?;
        drain.first_batch = false;
    }

    Ok(cursor)
}

const MULTI_FRAME_PREFIX_SIZE: usize = 5;

pub(crate) fn begin_batch_output(frame_tag: Option<u8>) -> Vec<u8> {
    match frame_tag {
        Some(_) => vec![0; MULTI_FRAME_PREFIX_SIZE],
        None => Vec::new(),
    }
}

pub(crate) fn finish_batch_frame(output: &mut [u8], frame_tag: Option<u8>) -> Result<()> {
    let Some(tag) = frame_tag else {
        return Ok(());
    };
    let payload_len = output
        .len()
        .checked_sub(MULTI_FRAME_PREFIX_SIZE)
        .ok_or_else(|| OdbcError::InternalError("missing MULT frame prefix".to_string()))?;
    let payload_len: u32 = payload_len.try_into().map_err(|_| {
        OdbcError::ResourceLimitReached(format!(
            "multi-result stream item payload exceeds u32: {payload_len}"
        ))
    })?;
    output[0] = tag;
    output[1..MULTI_FRAME_PREFIX_SIZE].copy_from_slice(&payload_len.to_le_bytes());
    Ok(())
}

fn emit_row_buffer_batch<F, T>(
    row_buffer: &mut RowBuffer,
    result_encoding: ResultEncoding,
    on_batch: &mut F,
    next_frame_tag: &mut T,
) -> Result<()>
where
    F: FnMut(Vec<u8>) -> Result<()>,
    T: FnMut() -> Option<u8>,
{
    let frame_tag = next_frame_tag();
    let mut encoded = begin_batch_output(frame_tag);
    encode_row_buffer_with_encoding_into(row_buffer, result_encoding, &mut encoded)?;
    finish_batch_frame(&mut encoded, frame_tag)?;
    on_batch(encoded)
}
