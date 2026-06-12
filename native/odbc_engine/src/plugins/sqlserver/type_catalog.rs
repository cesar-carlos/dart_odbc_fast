use super::SqlServerPlugin;
use crate::protocol::types::OdbcType;

use super::super::capabilities::TypeCatalog;
use super::super::driver_plugin::DriverPlugin;

impl TypeCatalog for SqlServerPlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "nvarchar" | "nchar" | "ntext" => return OdbcType::NVarchar,
                "datetimeoffset" => return OdbcType::DatetimeOffset,
                "uniqueidentifier" => return OdbcType::Uuid,
                "money" | "smallmoney" => return OdbcType::Money,
                "bit" => return OdbcType::Boolean,
                "smallint" | "tinyint" => return OdbcType::SmallInt,
                "real" => return OdbcType::Float,
                "float" => return OdbcType::Double,
                "varbinary" | "binary" | "image" => return OdbcType::Binary,
                "json" => return OdbcType::Json,
                "time" => return OdbcType::Time,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}
