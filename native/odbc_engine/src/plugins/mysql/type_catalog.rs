use super::MySqlPlugin;
use crate::protocol::types::OdbcType;

use super::super::capabilities::TypeCatalog;
use super::super::driver_plugin::DriverPlugin;

impl TypeCatalog for MySqlPlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "json" => return OdbcType::Json,
                "tinyint(1)" | "boolean" | "bool" => return OdbcType::Boolean,
                "smallint" | "smallint unsigned" => return OdbcType::SmallInt,
                "float" => return OdbcType::Float,
                "double" | "double precision" | "real" => return OdbcType::Double,
                "blob" | "tinyblob" | "mediumblob" | "longblob" | "varbinary" => {
                    return OdbcType::Binary
                }
                "time" => return OdbcType::Time,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}
