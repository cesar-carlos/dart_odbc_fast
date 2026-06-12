use super::Db2Plugin;
use crate::protocol::types::OdbcType;

use super::super::capabilities::TypeCatalog;
use super::super::driver_plugin::DriverPlugin;

impl TypeCatalog for Db2Plugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "graphic" | "vargraphic" | "long vargraphic" => return OdbcType::NVarchar,
                "clob" | "dbclob" => return OdbcType::Varchar,
                "blob" => return OdbcType::Binary,
                "xml" => return OdbcType::Json,
                "real" => return OdbcType::Float,
                "double" | "double precision" => return OdbcType::Double,
                "smallint" => return OdbcType::SmallInt,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}
