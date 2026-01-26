#![allow(dead_code)]

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AbiVersion {
    pub major: u16,
    pub minor: u16,
}

impl AbiVersion {
    pub fn new(major: u16, minor: u16) -> Self {
        Self { major, minor }
    }

    pub fn current() -> Self {
        Self::new(1, 0)
    }

    pub fn is_compatible_with(&self, other: &AbiVersion) -> bool {
        self.major == other.major && self.minor >= other.minor
    }

    pub fn is_breaking_change(&self, other: &AbiVersion) -> bool {
        self.major != other.major
    }
}

impl fmt::Display for AbiVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}", self.major, self.minor)
    }
}

impl Default for AbiVersion {
    fn default() -> Self {
        Self::current()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_abi_version_new() {
        let v = AbiVersion::new(1, 2);
        assert_eq!(v.major, 1);
        assert_eq!(v.minor, 2);
    }

    #[test]
    fn test_abi_version_current() {
        let v = AbiVersion::current();
        assert_eq!(v.major, 1);
        assert_eq!(v.minor, 0);
    }

    #[test]
    fn test_abi_version_default_is_current() {
        assert_eq!(AbiVersion::default(), AbiVersion::current());
    }

    #[test]
    fn test_abi_version_is_compatible_same() {
        let v = AbiVersion::new(1, 0);
        assert!(v.is_compatible_with(&AbiVersion::new(1, 0)));
    }

    #[test]
    fn test_abi_version_is_compatible_newer_minor() {
        let v = AbiVersion::new(1, 2);
        assert!(v.is_compatible_with(&AbiVersion::new(1, 0)));
        assert!(v.is_compatible_with(&AbiVersion::new(1, 1)));
    }

    #[test]
    fn test_abi_version_is_not_compatible_older_minor() {
        let v = AbiVersion::new(1, 0);
        assert!(!v.is_compatible_with(&AbiVersion::new(1, 1)));
    }

    #[test]
    fn test_abi_version_is_not_compatible_different_major() {
        let v = AbiVersion::new(2, 0);
        assert!(!v.is_compatible_with(&AbiVersion::new(1, 0)));
    }

    #[test]
    fn test_abi_version_is_breaking_change_different_major() {
        let v1 = AbiVersion::new(1, 0);
        let v2 = AbiVersion::new(2, 0);
        assert!(v1.is_breaking_change(&v2));
        assert!(v2.is_breaking_change(&v1));
    }

    #[test]
    fn test_abi_version_is_not_breaking_change_same_major() {
        let v1 = AbiVersion::new(1, 0);
        let v2 = AbiVersion::new(1, 5);
        assert!(!v1.is_breaking_change(&v2));
    }

    #[test]
    fn test_abi_version_display() {
        let v = AbiVersion::new(2, 3);
        assert_eq!(v.to_string(), "2.3");
    }

    #[test]
    fn test_abi_version_debug_clone_eq() {
        let v1 = AbiVersion::new(1, 5);
        let v2 = v1;
        assert_eq!(v1, v2);
        assert!(format!("{:?}", v1).contains("AbiVersion"));
    }
}
