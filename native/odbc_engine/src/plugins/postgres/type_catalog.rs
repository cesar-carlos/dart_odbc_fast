use super::PostgresPlugin;
use crate::protocol::types::OdbcType;

use super::super::capabilities::TypeCatalog;
use super::super::driver_plugin::DriverPlugin;

impl TypeCatalog for PostgresPlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "json" | "jsonb" => return OdbcType::Json,
                "uuid" => return OdbcType::Uuid,
                "timestamptz" | "timestamp with time zone" => return OdbcType::TimestampWithTz,
                "bool" | "boolean" => return OdbcType::Boolean,
                "int2" | "smallint" => return OdbcType::SmallInt,
                "float4" | "real" => return OdbcType::Float,
                "float8" | "double precision" => return OdbcType::Double,
                "bytea" => return OdbcType::Binary,
                "interval" => return OdbcType::Interval,
                "time" | "timetz" => return OdbcType::Time,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}
