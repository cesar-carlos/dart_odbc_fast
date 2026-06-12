use super::SybasePlugin;
use crate::protocol::types::OdbcType;

use super::super::capabilities::TypeCatalog;
use super::super::driver_plugin::DriverPlugin;

impl TypeCatalog for SybasePlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "money" | "smallmoney" => return OdbcType::Money,
                "bit" => return OdbcType::Boolean,
                "tinyint" | "smallint" => return OdbcType::SmallInt,
                "real" => return OdbcType::Float,
                "float" | "double precision" => return OdbcType::Double,
                "image" | "varbinary" | "binary" => return OdbcType::Binary,
                "nvarchar" | "nchar" | "univarchar" | "unichar" => return OdbcType::NVarchar,
                "time" => return OdbcType::Time,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}
