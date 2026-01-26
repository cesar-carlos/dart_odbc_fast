#![allow(dead_code)]

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ProtocolVersion {
    pub major: u16,
    pub minor: u16,
}

impl ProtocolVersion {
    pub fn new(major: u16, minor: u16) -> Self {
        Self { major, minor }
    }

    pub fn v1() -> Self {
        Self::new(1, 0)
    }

    pub fn v2() -> Self {
        Self::new(2, 0)
    }

    pub fn current() -> Self {
        Self::v2()
    }

    pub fn is_compatible_with(&self, other: &ProtocolVersion) -> bool {
        self.major == other.major && self.minor >= other.minor
    }

    pub fn is_breaking_change(&self, other: &ProtocolVersion) -> bool {
        self.major != other.major
    }
}

impl fmt::Display for ProtocolVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}", self.major, self.minor)
    }
}

impl Default for ProtocolVersion {
    fn default() -> Self {
        Self::current()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_version_new() {
        let v = ProtocolVersion::new(1, 5);
        assert_eq!(v.major, 1);
        assert_eq!(v.minor, 5);
    }

    #[test]
    fn test_version_v1() {
        let v1 = ProtocolVersion::v1();
        assert_eq!(v1.major, 1);
        assert_eq!(v1.minor, 0);
    }

    #[test]
    fn test_version_v2() {
        let v2 = ProtocolVersion::v2();
        assert_eq!(v2.major, 2);
        assert_eq!(v2.minor, 0);
    }

    #[test]
    fn test_current_is_v2() {
        assert_eq!(ProtocolVersion::current(), ProtocolVersion::v2());
    }

    #[test]
    fn test_default_is_current() {
        assert_eq!(ProtocolVersion::default(), ProtocolVersion::current());
    }

    #[test]
    fn test_is_compatible_same_version() {
        let v = ProtocolVersion::new(1, 0);
        assert!(v.is_compatible_with(&ProtocolVersion::new(1, 0)));
    }

    #[test]
    fn test_is_compatible_newer_minor() {
        let v = ProtocolVersion::new(1, 5);
        assert!(v.is_compatible_with(&ProtocolVersion::new(1, 0)));
        assert!(v.is_compatible_with(&ProtocolVersion::new(1, 3)));
    }

    #[test]
    fn test_is_not_compatible_older_minor() {
        let v = ProtocolVersion::new(1, 0);
        assert!(!v.is_compatible_with(&ProtocolVersion::new(1, 1)));
        assert!(!v.is_compatible_with(&ProtocolVersion::new(1, 5)));
    }

    #[test]
    fn test_is_not_compatible_different_major() {
        let v = ProtocolVersion::new(2, 0);
        assert!(!v.is_compatible_with(&ProtocolVersion::new(1, 0)));
        assert!(!v.is_compatible_with(&ProtocolVersion::new(3, 0)));
    }

    #[test]
    fn test_is_breaking_change_different_major() {
        let v1 = ProtocolVersion::new(1, 0);
        let v2 = ProtocolVersion::new(2, 0);
        assert!(v1.is_breaking_change(&v2));
        assert!(v2.is_breaking_change(&v1));
    }

    #[test]
    fn test_is_not_breaking_change_same_major() {
        let v1 = ProtocolVersion::new(1, 0);
        let v2 = ProtocolVersion::new(1, 5);
        assert!(!v1.is_breaking_change(&v2));
        assert!(!v2.is_breaking_change(&v1));
    }

    #[test]
    fn test_display_format() {
        let v = ProtocolVersion::new(2, 5);
        assert_eq!(v.to_string(), "2.5");
    }

    #[test]
    fn test_equality() {
        let v1 = ProtocolVersion::new(1, 0);
        let v2 = ProtocolVersion::new(1, 0);
        let v3 = ProtocolVersion::new(1, 1);

        assert_eq!(v1, v2);
        assert_ne!(v1, v3);
    }

    #[test]
    fn test_ordering() {
        let v1_0 = ProtocolVersion::new(1, 0);
        let v1_1 = ProtocolVersion::new(1, 1);
        let v2_0 = ProtocolVersion::new(2, 0);

        assert!(v1_0 < v1_1);
        assert!(v1_1 < v2_0);
        assert!(v1_0 < v2_0);
    }

    #[test]
    fn test_clone() {
        let v1 = ProtocolVersion::new(1, 5);
        let v2 = v1;
        assert_eq!(v1, v2);
    }

    #[test]
    fn test_debug_format() {
        let v = ProtocolVersion::new(1, 5);
        let debug_str = format!("{:?}", v);
        assert!(debug_str.contains("ProtocolVersion"));
        assert!(debug_str.contains("1"));
        assert!(debug_str.contains("5"));
    }
}
