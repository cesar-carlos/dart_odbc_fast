//! Shared batched cursor drain for single- and multi-result streaming.

use super::chunk::BatchBufferPool;
#[cfg(not(feature = "block-cursor-fetch"))]
use super::columns::describe_streaming_columns;
use super::columns::encode_row_buffer_with_encoding_into;
use super::columns::FallbackColumnarEncoder;
use crate::engine::query::ResultEncoding;
use crate::error::{OdbcError, Result};
use crate::protocol::RowBuffer;
use odbc_api::{Cursor, ResultSetMetadata};

#[cfg(feature = "block-cursor-fetch")]
use crate::engine::core::block_fetch::{describe_and_plan_columns, RowMajorBlockSession};
#[cfg(feature = "block-cursor-fetch")]
use crate::engine::core::columnar_fetch::ColumnarStreamingSession;
#[cfg(feature = "block-cursor-fetch")]
use crate::protocol::columnar::ColumnMetadata;
#[cfg(feature = "block-cursor-fetch")]
use crate::protocol::columnar_encoder::ColumnarCompressionWorkspace;
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
    buffer_pool: Option<&BatchBufferPool>,
) -> Result<C>
where
    C: Cursor + ResultSetMetadata,
    F: FnMut(Vec<u8>) -> Result<()>,
    T: FnMut() -> Option<u8>,
{
    let batch_size = fetch_size.max(1);
    let mut row_buffer = RowBuffer::new();
    #[cfg(feature = "block-cursor-fetch")]
    let (column_types, buffer_descs) =
        describe_and_plan_columns(&mut cursor, &mut row_buffer, None)?;
    #[cfg(not(feature = "block-cursor-fetch"))]
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
            if let Some(descs) = buffer_descs {
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
                    let mut compression_workspace = ColumnarCompressionWorkspace::new();
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
                                        buffer_pool,
                                    )?;
                                }
                                cursor = session.into_cursor()?;
                                break;
                            }
                            Some(v2) => {
                                let frame_tag = next_frame_tag();
                                let mut encoded = begin_batch_output(frame_tag, buffer_pool);
                                ColumnarEncoder::encode_into_with_workspace(
                                    &mut encoded,
                                    v2,
                                    compress,
                                    &mut compression_workspace,
                                )?;
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
                    let fetched = session.fetch_next_batch(&mut row_buffer)?;
                    if fetched == 0 {
                        if first_batch {
                            emit_row_buffer_batch(
                                &mut row_buffer,
                                result_encoding,
                                on_batch,
                                next_frame_tag,
                                buffer_pool,
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
                        buffer_pool,
                    )?;
                    first_batch = false;
                }
                return Ok(cursor);
            }
        }
    }

    let fallback_columnar = matches!(
        result_encoding,
        ResultEncoding::Columnar | ResultEncoding::ColumnarCompressed
    )
    .then(|| FallbackColumnarEncoder::new(&row_buffer));
    let mut drain = LegacyBatchDrain {
        column_types: &column_types,
        batch_size,
        result_encoding,
        on_batch,
        next_frame_tag,
        row_buffer: &mut row_buffer,
        fallback_columnar,
        recycled_rows: Vec::new(),
        buffer_pool,
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
    fallback_columnar: Option<FallbackColumnarEncoder>,
    recycled_rows: Vec<Vec<Option<crate::protocol::CellBytes>>>,
    buffer_pool: Option<&'a BatchBufferPool>,
    first_batch: bool,
}

impl<F, T> LegacyBatchDrain<'_, F, T>
where
    F: FnMut(Vec<u8>) -> Result<()>,
    T: FnMut() -> Option<u8>,
{
    fn emit_batch(&mut self) -> Result<()> {
        let frame_tag = (self.next_frame_tag)();
        let mut encoded = begin_batch_output(frame_tag, self.buffer_pool);
        if let Some(columnar) = &mut self.fallback_columnar {
            columnar.encode_into(
                self.row_buffer,
                matches!(self.result_encoding, ResultEncoding::ColumnarCompressed),
                &mut encoded,
            )?;
        } else {
            encode_row_buffer_with_encoding_into(
                self.row_buffer,
                self.result_encoding,
                &mut encoded,
            )?;
        }
        finish_batch_frame(&mut encoded, frame_tag)?;
        (self.on_batch)(encoded)
    }
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

        for mut row in drain.row_buffer.rows.drain(..) {
            row.clear();
            if drain.recycled_rows.len() < drain.batch_size {
                drain.recycled_rows.push(row);
            }
        }
        let _fetched = crate::engine::fetch::fetch_batch_into_row_buffer(
            &mut cursor,
            drain.column_types,
            drain.batch_size,
            drain.row_buffer,
            &mut drain.recycled_rows,
        )?;

        if drain.row_buffer.row_count() == 0 {
            if drain.first_batch {
                drain.emit_batch()?;
            }
            break;
        }

        drain.emit_batch()?;
        drain.first_batch = false;
    }

    Ok(cursor)
}

const MULTI_FRAME_PREFIX_SIZE: usize = 5;

pub(crate) fn begin_batch_output(frame_tag: Option<u8>, pool: Option<&BatchBufferPool>) -> Vec<u8> {
    let mut output = pool.map(BatchBufferPool::take).unwrap_or_default();
    output.clear();
    if frame_tag.is_some() {
        output.resize(MULTI_FRAME_PREFIX_SIZE, 0);
    }
    output
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

#[cfg(feature = "block-cursor-fetch")]
fn emit_row_buffer_batch<F, T>(
    row_buffer: &mut RowBuffer,
    result_encoding: ResultEncoding,
    on_batch: &mut F,
    next_frame_tag: &mut T,
    buffer_pool: Option<&BatchBufferPool>,
) -> Result<()>
where
    F: FnMut(Vec<u8>) -> Result<()>,
    T: FnMut() -> Option<u8>,
{
    let frame_tag = next_frame_tag();
    let mut encoded = begin_batch_output(frame_tag, buffer_pool);
    encode_row_buffer_with_encoding_into(row_buffer, result_encoding, &mut encoded)?;
    finish_batch_frame(&mut encoded, frame_tag)?;
    on_batch(encoded)
}
