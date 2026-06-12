use super::SnowflakePlugin;
use crate::protocol::types::OdbcType;

use super::super::capabilities::TypeCatalog;
use super::super::driver_plugin::DriverPlugin;

impl TypeCatalog for SnowflakePlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "variant" | "object" | "array" => return OdbcType::Json,
                "timestamp_tz" | "timestamp_ltz" => return OdbcType::TimestampWithTz,
                "timestamp_ntz" => return OdbcType::Timestamp,
                "boolean" => return OdbcType::Boolean,
                "binary" | "varbinary" => return OdbcType::Binary,
                "real" | "float" | "float4" => return OdbcType::Float,
                "double" | "float8" | "float64" => return OdbcType::Double,
                "geography" | "geometry" => return OdbcType::Json,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}
