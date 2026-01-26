#[repr(u16)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OdbcType {
    Varchar = 1,
    Integer = 2,
    BigInt = 3,
    Decimal = 4,
    Date = 5,
    Timestamp = 6,
    Binary = 7,
}

impl OdbcType {
    pub fn from_odbc_sql_type(sql_type: i16) -> Self {
        match sql_type {
            1 => Self::Varchar,
            4 => Self::Integer,
            -5 => Self::BigInt,
            3 => Self::Decimal,
            9 => Self::Date,
            11 => Self::Timestamp,
            -2 => Self::Binary,
            _ => Self::Varchar,
        }
    }

    pub fn sql_type_code_from_data_type(data_type: &odbc_api::DataType) -> i16 {
        use odbc_api::DataType;

        match data_type {
            DataType::Integer | DataType::SmallInt | DataType::TinyInt | DataType::Bit => 4,
            DataType::BigInt => -5,
            DataType::Numeric { .. } | DataType::Decimal { .. } => 3,
            DataType::Date => 9,
            DataType::Timestamp { .. } => 11,
            DataType::Binary { .. }
            | DataType::Varbinary { .. }
            | DataType::LongVarbinary { .. } => -2,
            _ => 1,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_odbc_type_repr_values() {
        assert_eq!(OdbcType::Varchar as u16, 1);
        assert_eq!(OdbcType::Integer as u16, 2);
        assert_eq!(OdbcType::BigInt as u16, 3);
        assert_eq!(OdbcType::Decimal as u16, 4);
        assert_eq!(OdbcType::Date as u16, 5);
        assert_eq!(OdbcType::Timestamp as u16, 6);
        assert_eq!(OdbcType::Binary as u16, 7);
    }

    #[test]
    fn test_from_odbc_sql_type_varchar() {
        assert_eq!(OdbcType::from_odbc_sql_type(1), OdbcType::Varchar);
    }

    #[test]
    fn test_from_odbc_sql_type_integer() {
        assert_eq!(OdbcType::from_odbc_sql_type(4), OdbcType::Integer);
    }

    #[test]
    fn test_from_odbc_sql_type_bigint() {
        assert_eq!(OdbcType::from_odbc_sql_type(-5), OdbcType::BigInt);
    }

    #[test]
    fn test_from_odbc_sql_type_decimal() {
        assert_eq!(OdbcType::from_odbc_sql_type(3), OdbcType::Decimal);
    }

    #[test]
    fn test_from_odbc_sql_type_date() {
        assert_eq!(OdbcType::from_odbc_sql_type(9), OdbcType::Date);
    }

    #[test]
    fn test_from_odbc_sql_type_timestamp() {
        assert_eq!(OdbcType::from_odbc_sql_type(11), OdbcType::Timestamp);
    }

    #[test]
    fn test_from_odbc_sql_type_binary() {
        assert_eq!(OdbcType::from_odbc_sql_type(-2), OdbcType::Binary);
    }

    #[test]
    fn test_from_odbc_sql_type_unknown_defaults_to_varchar() {
        assert_eq!(OdbcType::from_odbc_sql_type(999), OdbcType::Varchar);
        assert_eq!(OdbcType::from_odbc_sql_type(-999), OdbcType::Varchar);
        assert_eq!(OdbcType::from_odbc_sql_type(0), OdbcType::Varchar);
    }

    #[test]
    fn test_sql_type_code_from_data_type_integer_variants() {
        use odbc_api::DataType;

        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::Integer),
            4
        );
        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::SmallInt),
            4
        );
        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::TinyInt),
            4
        );
        assert_eq!(OdbcType::sql_type_code_from_data_type(&DataType::Bit), 4);
    }

    #[test]
    fn test_sql_type_code_from_data_type_bigint() {
        use odbc_api::DataType;

        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::BigInt),
            -5
        );
    }

    #[test]
    fn test_sql_type_code_from_data_type_decimal_variants() {
        use odbc_api::DataType;

        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::Numeric {
                precision: 10,
                scale: 2
            }),
            3
        );
        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::Decimal {
                precision: 10,
                scale: 2
            }),
            3
        );
    }

    #[test]
    fn test_sql_type_code_from_data_type_date() {
        use odbc_api::DataType;

        assert_eq!(OdbcType::sql_type_code_from_data_type(&DataType::Date), 9);
    }

    #[test]
    fn test_sql_type_code_from_data_type_timestamp() {
        use odbc_api::DataType;

        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::Timestamp { precision: 3 }),
            11
        );
    }

    #[test]
    fn test_sql_type_code_from_data_type_binary_variants() {
        use odbc_api::DataType;
        use std::num::NonZero;

        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::Binary {
                length: NonZero::new(10)
            }),
            -2
        );
        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::Varbinary {
                length: NonZero::new(100)
            }),
            -2
        );
        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::LongVarbinary {
                length: NonZero::new(1000)
            }),
            -2
        );
    }

    #[test]
    fn test_sql_type_code_from_data_type_varchar_default() {
        use odbc_api::DataType;
        use std::num::NonZero;

        // Text types default to varchar (1)
        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::Varchar {
                length: NonZero::new(100)
            }),
            1
        );
        assert_eq!(
            OdbcType::sql_type_code_from_data_type(&DataType::Char {
                length: NonZero::new(10)
            }),
            1
        );
    }

    #[test]
    fn test_odbc_type_roundtrip() {
        // Test that converting from SQL type code and back works
        let types_and_codes = [
            (OdbcType::Varchar, 1),
            (OdbcType::Integer, 4),
            (OdbcType::BigInt, -5),
            (OdbcType::Decimal, 3),
            (OdbcType::Date, 9),
            (OdbcType::Timestamp, 11),
            (OdbcType::Binary, -2),
        ];

        for (odbc_type, sql_code) in types_and_codes {
            let converted = OdbcType::from_odbc_sql_type(sql_code);
            assert_eq!(converted, odbc_type);
        }
    }
}
