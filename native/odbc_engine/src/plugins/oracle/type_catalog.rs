use super::OraclePlugin;
use crate::protocol::types::OdbcType;

use super::super::capabilities::TypeCatalog;
use super::super::driver_plugin::DriverPlugin;

impl TypeCatalog for OraclePlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "timestamp with time zone" | "timestamp with local time zone" => {
                    return OdbcType::TimestampWithTz;
                }
                "interval day to second" | "interval year to month" => return OdbcType::Interval,
                "raw" | "long raw" | "blob" => return OdbcType::Binary,
                "clob" | "nclob" => return OdbcType::Varchar,
                "nvarchar2" | "nchar" => return OdbcType::NVarchar,
                "binary_float" => return OdbcType::Float,
                "binary_double" => return OdbcType::Double,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}
