//! v3.0 — capability traits + per-driver `IdentifierQuoter` / `TypeCatalog`.

use odbc_engine::engine::identifier::IdentifierQuoting;
use odbc_engine::plugins::capabilities::{IdentifierQuoter, TypeCatalog};
use odbc_engine::plugins::{
    db2::Db2Plugin, mariadb::MariaDbPlugin, mysql::MySqlPlugin, oracle::OraclePlugin,
    postgres::PostgresPlugin, snowflake::SnowflakePlugin, sqlite::SqlitePlugin,
    sqlserver::SqlServerPlugin, sybase::SybasePlugin,
};
use odbc_engine::protocol::types::OdbcType;

#[test]
fn quoting_styles_per_driver() {
    assert_eq!(
        PostgresPlugin::new().quoting_style(),
        IdentifierQuoting::DoubleQuote
    );
    assert_eq!(
        OraclePlugin::new().quoting_style(),
        IdentifierQuoting::DoubleQuote
    );
    assert_eq!(
        Db2Plugin::new().quoting_style(),
        IdentifierQuoting::DoubleQuote
    );
    assert_eq!(
        SqlitePlugin::new().quoting_style(),
        IdentifierQuoting::DoubleQuote
    );
    assert_eq!(
        SnowflakePlugin::new().quoting_style(),
        IdentifierQuoting::DoubleQuote
    );
    assert_eq!(
        MySqlPlugin::new().quoting_style(),
        IdentifierQuoting::Backtick
    );
    assert_eq!(
        MariaDbPlugin::new().quoting_style(),
        IdentifierQuoting::Backtick
    );
    assert_eq!(
        SqlServerPlugin::new().quoting_style(),
        IdentifierQuoting::Brackets
    );
    assert_eq!(
        SybasePlugin::new().quoting_style(),
        IdentifierQuoting::Brackets
    );
}

#[test]
fn quoter_quotes_in_dialect_specific_style() {
    assert_eq!(PostgresPlugin::new().quote("t").unwrap(), "\"t\"");
    assert_eq!(MySqlPlugin::new().quote("t").unwrap(), "`t`");
    assert_eq!(SqlServerPlugin::new().quote("t").unwrap(), "[t]");
}

#[test]
fn type_catalog_postgres_recognises_specific_types() {
    let p = PostgresPlugin::new();
    assert_eq!(p.map_type_extended(1, Some("uuid")), OdbcType::Uuid);
    assert_eq!(p.map_type_extended(1, Some("jsonb")), OdbcType::Json);
    assert_eq!(
        p.map_type_extended(1, Some("timestamptz")),
        OdbcType::TimestampWithTz
    );
    assert_eq!(p.map_type_extended(1, Some("bool")), OdbcType::Boolean);
    assert_eq!(p.map_type_extended(1, Some("bytea")), OdbcType::Binary);
}

#[test]
fn type_catalog_sqlserver_recognises_specific_types() {
    let p = SqlServerPlugin::new();
    assert_eq!(p.map_type_extended(1, Some("nvarchar")), OdbcType::NVarchar);
    assert_eq!(
        p.map_type_extended(1, Some("uniqueidentifier")),
        OdbcType::Uuid
    );
    assert_eq!(p.map_type_extended(1, Some("money")), OdbcType::Money);
    assert_eq!(p.map_type_extended(1, Some("bit")), OdbcType::Boolean);
    assert_eq!(
        p.map_type_extended(1, Some("datetimeoffset")),
        OdbcType::DatetimeOffset
    );
}

#[test]
fn type_catalog_oracle_recognises_specific_types() {
    let p = OraclePlugin::new();
    assert_eq!(
        p.map_type_extended(1, Some("TIMESTAMP WITH TIME ZONE")),
        OdbcType::TimestampWithTz
    );
    assert_eq!(p.map_type_extended(1, Some("CLOB")), OdbcType::Varchar);
    assert_eq!(p.map_type_extended(1, Some("BLOB")), OdbcType::Binary);
    assert_eq!(
        p.map_type_extended(1, Some("INTERVAL DAY TO SECOND")),
        OdbcType::Interval
    );
    assert_eq!(
        p.map_type_extended(1, Some("BINARY_DOUBLE")),
        OdbcType::Double
    );
}

#[test]
fn type_catalog_db2_recognises_specific_types() {
    let p = Db2Plugin::new();
    assert_eq!(p.map_type_extended(1, Some("GRAPHIC")), OdbcType::NVarchar);
    assert_eq!(p.map_type_extended(1, Some("XML")), OdbcType::Json);
    assert_eq!(p.map_type_extended(1, Some("BLOB")), OdbcType::Binary);
}

#[test]
fn type_catalog_snowflake_recognises_variant_family() {
    let p = SnowflakePlugin::new();
    assert_eq!(p.map_type_extended(1, Some("VARIANT")), OdbcType::Json);
    assert_eq!(p.map_type_extended(1, Some("OBJECT")), OdbcType::Json);
    assert_eq!(p.map_type_extended(1, Some("ARRAY")), OdbcType::Json);
    assert_eq!(
        p.map_type_extended(1, Some("TIMESTAMP_TZ")),
        OdbcType::TimestampWithTz
    );
}

#[test]
fn odbc_type_protocol_discriminant_round_trip() {
    let all = [
        OdbcType::Varchar,
        OdbcType::Integer,
        OdbcType::BigInt,
        OdbcType::Decimal,
        OdbcType::Date,
        OdbcType::Timestamp,
        OdbcType::Binary,
        OdbcType::NVarchar,
        OdbcType::TimestampWithTz,
        OdbcType::DatetimeOffset,
        OdbcType::Time,
        OdbcType::SmallInt,
        OdbcType::Boolean,
        OdbcType::Float,
        OdbcType::Double,
        OdbcType::Json,
        OdbcType::Uuid,
        OdbcType::Money,
        OdbcType::Interval,
    ];
    for t in all {
        let code = t as u16;
        let back = OdbcType::from_protocol_discriminant(code);
        assert_eq!(back, t, "round-trip failed for {t:?}");
    }
}
