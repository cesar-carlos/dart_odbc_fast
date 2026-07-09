use crate::error::{OdbcError, Result};
use crate::protocol::compression::CompressionStrategy;
use crate::protocol::param_value::ParamValue;
use crate::protocol::row_buffer::RowBuffer;
use std::io::Write;
use thiserror::Error;

pub(crate) const MAGIC: u32 = 0x4F444243;
pub(crate) const VERSION: u16 = 1;
const HEADER_SIZE: usize = 16;

/// Appended after the v1 row-major message when a query used `OUT` / `INOUT` parameters.
pub const OUTPUT_FOOTER_MAGIC: [u8; 4] = *b"OUT1";

/// After `OUT1`, optional materialized Oracle / `SYS_REFCURSOR` result sets: `RC1` + NUL
/// padding to 4 bytes (same style as `OUT1`), then `u32` count, then repeated
/// (`u32` len + full v1 `RowBufferEncoder` message per cursor).
pub const REF_CURSOR_FOOTER_MAGIC: [u8; 4] = [b'R', b'C', b'1', 0];

pub struct RowBufferEncoder;

#[derive(Clone, Copy)]
struct EncodedShape {
    column_count: u16,
    row_count: u32,
    payload_size: u32,
    total_len: usize,
}

#[derive(Debug, Error)]
pub enum EncodeError {
    #[error("{field} value {value} exceeds {target}")]
    LengthTooLarge {
        field: &'static str,
        value: usize,
        target: &'static str,
    },

    #[error("payload size overflow while adding {context}")]
    PayloadSizeOverflow { context: &'static str },

    #[error("writer error: {0}")]
    Io(#[from] std::io::Error),
}

impl RowBufferEncoder {
    fn map_encode_error(e: EncodeError) -> OdbcError {
        OdbcError::ResourceLimitReached(format!("result encoding failed: {e}"))
    }

    /// Production path: returns [`OdbcError::ResourceLimitReached`] instead of panicking.
    pub fn encode_result(buffer: &RowBuffer) -> Result<Vec<u8>> {
        Self::try_encode(buffer).map_err(Self::map_encode_error)
    }

    /// Fallible encoding; identical to [`Self::encode_result`].
    pub fn encode(buffer: &RowBuffer) -> Result<Vec<u8>> {
        Self::encode_result(buffer)
    }

    pub fn try_encode(buffer: &RowBuffer) -> std::result::Result<Vec<u8>, EncodeError> {
        let shape = measure_buffer(buffer)?;
        let mut output = Vec::with_capacity(shape.total_len);
        // Specialize for `Vec`: `extend_from_slice` / `push` avoid the
        // `Write` trait indirection that the spill-to-disk path needs.
        // Lengths were already validated by `measure_buffer` against an
        // immutable borrow, so the hot loop can emit them without
        // re-checking `try_into`.
        Self::encode_to_vec_with_shape(buffer, &mut output, shape);
        debug_assert_eq!(output.len(), shape.total_len);
        Ok(output)
    }

    /// Encode buffer to a writer. Used for spill-to-disk when result exceeds memory threshold.
    pub fn encode_to_writer<W: Write>(
        buffer: &RowBuffer,
        w: &mut W,
    ) -> std::result::Result<(), EncodeError> {
        let shape = measure_buffer(buffer)?;
        Self::encode_to_writer_with_shape(buffer, w, shape)
    }

    /// Like [`Self::encode_to_writer`] but maps failures to [`OdbcError::ResourceLimitReached`].
    pub fn encode_to_writer_result<W: Write>(buffer: &RowBuffer, w: &mut W) -> Result<()> {
        Self::encode_to_writer(buffer, w).map_err(Self::map_encode_error)
    }

    fn encode_to_vec_with_shape(buffer: &RowBuffer, output: &mut Vec<u8>, shape: EncodedShape) {
        output.extend_from_slice(&MAGIC.to_le_bytes());
        output.extend_from_slice(&VERSION.to_le_bytes());
        output.extend_from_slice(&shape.column_count.to_le_bytes());
        output.extend_from_slice(&shape.row_count.to_le_bytes());
        output.extend_from_slice(&shape.payload_size.to_le_bytes());

        for col in &buffer.columns {
            output.extend_from_slice(&(col.odbc_type as u16).to_le_bytes());
            // SAFETY of cast: `measure_buffer` already rejected names that
            // do not fit in `u16`.
            let name_len = col.name.len() as u16;
            output.extend_from_slice(&name_len.to_le_bytes());
            output.extend_from_slice(col.name.as_bytes());
        }

        for row in &buffer.rows {
            for cell in row {
                if let Some(data) = cell {
                    output.push(0);
                    let data_len = data.len() as u32;
                    output.extend_from_slice(&data_len.to_le_bytes());
                    output.extend_from_slice(data);
                } else {
                    output.push(1);
                }
            }
        }
    }

    fn encode_to_writer_with_shape<W: Write>(
        buffer: &RowBuffer,
        w: &mut W,
        shape: EncodedShape,
    ) -> std::result::Result<(), EncodeError> {
        w.write_all(&MAGIC.to_le_bytes())?;
        w.write_all(&VERSION.to_le_bytes())?;
        w.write_all(&shape.column_count.to_le_bytes())?;
        w.write_all(&shape.row_count.to_le_bytes())?;
        w.write_all(&shape.payload_size.to_le_bytes())?;

        for col in &buffer.columns {
            w.write_all(&(col.odbc_type as u16).to_le_bytes())?;
            let name_len = checked_u16_len(col.name.len(), "column name length")?;
            w.write_all(&name_len.to_le_bytes())?;
            w.write_all(col.name.as_bytes())?;
        }

        for row in &buffer.rows {
            for cell in row {
                if let Some(data) = cell {
                    w.write_all(&[0])?;
                    let data_len = checked_u32_len(data.len(), "cell data length")?;
                    w.write_all(&data_len.to_le_bytes())?;
                    w.write_all(data)?;
                } else {
                    w.write_all(&[1])?;
                }
            }
        }

        Ok(())
    }

    /// Convenience wrapper around [`Self::try_append_output_footer`]. Well-formed payloads
    /// within wire limits always succeed. On overflow the error is logged and an empty
    /// buffer is returned instead of panicking; fallible callers should use
    /// [`Self::append_output_footer_result`] or [`Self::try_append_output_footer`] directly.
    pub fn append_output_footer(base: Vec<u8>, outputs: &[ParamValue]) -> Vec<u8> {
        match Self::try_append_output_footer(base, outputs) {
            Ok(buf) => buf,
            Err(e) => {
                log::error!("append_output_footer: {e}");
                Vec::new()
            }
        }
    }

    pub fn append_output_footer_result(base: Vec<u8>, outputs: &[ParamValue]) -> Result<Vec<u8>> {
        Self::try_append_output_footer(base, outputs).map_err(Self::map_encode_error)
    }

    pub fn try_append_output_footer(
        mut base: Vec<u8>,
        outputs: &[ParamValue],
    ) -> std::result::Result<Vec<u8>, EncodeError> {
        if outputs.is_empty() {
            return Ok(base);
        }
        base.extend_from_slice(&OUTPUT_FOOTER_MAGIC);
        let output_count = checked_u32_len(outputs.len(), "output parameter count")?;
        base.extend_from_slice(&output_count.to_le_bytes());
        for p in outputs {
            base.extend(p.serialize());
        }
        Ok(base)
    }

    /// Convenience wrapper around [`Self::try_append_ref_cursor_footer`]. Well-formed payloads
    /// within wire limits always succeed. On overflow the error is logged and an empty
    /// buffer is returned instead of panicking; fallible callers should use
    /// [`Self::append_ref_cursor_footer_result`] or [`Self::try_append_ref_cursor_footer`]
    /// directly.
    pub fn append_ref_cursor_footer(base: Vec<u8>, blobs: &[Vec<u8>]) -> Vec<u8> {
        match Self::try_append_ref_cursor_footer(base, blobs) {
            Ok(buf) => buf,
            Err(e) => {
                log::error!("append_ref_cursor_footer: {e}");
                Vec::new()
            }
        }
    }

    pub fn append_ref_cursor_footer_result(base: Vec<u8>, blobs: &[Vec<u8>]) -> Result<Vec<u8>> {
        Self::try_append_ref_cursor_footer(base, blobs).map_err(Self::map_encode_error)
    }

    pub fn try_append_ref_cursor_footer(
        mut base: Vec<u8>,
        blobs: &[Vec<u8>],
    ) -> std::result::Result<Vec<u8>, EncodeError> {
        if blobs.is_empty() {
            return Ok(base);
        }
        base.extend_from_slice(&REF_CURSOR_FOOTER_MAGIC);
        let blob_count = checked_u32_len(blobs.len(), "ref cursor count")?;
        base.extend_from_slice(&blob_count.to_le_bytes());
        for b in blobs {
            let blob_len = checked_u32_len(b.len(), "ref cursor payload length")?;
            base.extend_from_slice(&blob_len.to_le_bytes());
            base.extend_from_slice(b);
        }
        Ok(base)
    }

    /// Convenience wrapper around [`Self::try_encode_with_compression`]. Well-formed buffers
    /// within wire limits always succeed. On overflow the error is logged and an empty
    /// buffer is returned instead of panicking; fallible callers should use
    /// [`Self::try_encode_with_compression`] directly.
    pub fn encode_with_compression(buffer: &RowBuffer) -> Vec<u8> {
        match Self::try_encode_with_compression(buffer) {
            Ok(buf) => buf,
            Err(e) => {
                log::error!("encode_with_compression: {e}");
                Vec::new()
            }
        }
    }

    pub fn try_encode_with_compression(
        buffer: &RowBuffer,
    ) -> std::result::Result<Vec<u8>, EncodeError> {
        let raw = Self::try_encode(buffer)?;
        let strategy = CompressionStrategy::auto_select(raw.len());
        Ok(match strategy.compress_owned(raw) {
            Ok(compressed) => compressed,
            Err(_) => Self::try_encode(buffer)?,
        })
    }
}

fn measure_buffer(buffer: &RowBuffer) -> std::result::Result<EncodedShape, EncodeError> {
    let column_count = checked_u16_len(buffer.column_count(), "column count")?;
    let row_count = checked_u32_len(buffer.row_count(), "row count")?;
    let mut metadata_size = 0usize;
    for col in &buffer.columns {
        checked_u16_len(col.name.len(), "column name length")?;
        metadata_size = checked_payload_add(metadata_size, 2, "column type")?;
        metadata_size = checked_payload_add(metadata_size, 2, "column name length")?;
        metadata_size = checked_payload_add(metadata_size, col.name.len(), "column name")?;
    }

    let mut payload_size = metadata_size;
    for row in &buffer.rows {
        for cell in row {
            payload_size = checked_payload_add(payload_size, 1, "cell null flag")?;
            if let Some(data) = cell {
                checked_u32_len(data.len(), "cell data length")?;
                payload_size = checked_payload_add(payload_size, 4, "cell data length")?;
                payload_size = checked_payload_add(payload_size, data.len(), "cell data")?;
            }
        }
    }
    let payload_size = checked_u32_len(payload_size, "payload size")?;
    let total_len =
        HEADER_SIZE
            .checked_add(payload_size as usize)
            .ok_or(EncodeError::PayloadSizeOverflow {
                context: "encoded row buffer",
            })?;

    Ok(EncodedShape {
        column_count,
        row_count,
        payload_size,
        total_len,
    })
}

pub(crate) fn checked_u16_len(
    value: usize,
    field: &'static str,
) -> std::result::Result<u16, EncodeError> {
    value.try_into().map_err(|_| EncodeError::LengthTooLarge {
        field,
        value,
        target: "u16",
    })
}

pub(crate) fn checked_u32_len(
    value: usize,
    field: &'static str,
) -> std::result::Result<u32, EncodeError> {
    value.try_into().map_err(|_| EncodeError::LengthTooLarge {
        field,
        value,
        target: "u32",
    })
}

pub(crate) fn checked_payload_add(
    current: usize,
    added: usize,
    context: &'static str,
) -> std::result::Result<usize, EncodeError> {
    current
        .checked_add(added)
        .ok_or(EncodeError::PayloadSizeOverflow { context })
}

#[cfg(test)]
mod tests;
