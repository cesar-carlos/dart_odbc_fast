use super::MariaDbPlugin;
use crate::protocol::types::OdbcType;

use super::super::capabilities::TypeCatalog;
use super::super::driver_plugin::DriverPlugin;

impl TypeCatalog for MariaDbPlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "json" | "longtext" if lower.contains("json") => return OdbcType::Json,
                "json" => return OdbcType::Json,
                "tinyint(1)" | "boolean" | "bool" => return OdbcType::Boolean,
                "uuid" => return OdbcType::Uuid, // MariaDB 10.7+
                "double" | "double precision" | "real" => return OdbcType::Double,
                "blob" | "tinyblob" | "mediumblob" | "longblob" | "varbinary" => {
                    return OdbcType::Binary
                }
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}
