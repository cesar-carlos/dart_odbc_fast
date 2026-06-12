use crate::protocol::ParamValue;

use super::BatchParam;

pub(crate) fn batch_param_to_param_value(param: &BatchParam) -> ParamValue {
    match param {
        BatchParam::String(s) => ParamValue::String(s.clone()),
        BatchParam::Integer(n) => ParamValue::Integer(*n),
        BatchParam::BigInt(n) => ParamValue::BigInt(*n),
        BatchParam::Null => ParamValue::Null,
    }
}
