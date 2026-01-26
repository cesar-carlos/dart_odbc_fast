#![allow(dead_code)]

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ApiVersion {
    pub major: u16,
    pub minor: u16,
    pub patch: u16,
}

impl ApiVersion {
    pub fn new(major: u16, minor: u16, patch: u16) -> Self {
        Self {
            major,
            minor,
            patch,
        }
    }

    pub fn current() -> Self {
        Self::new(0, 1, 0)
    }

    pub fn is_compatible_with(&self, other: &ApiVersion) -> bool {
        self.major == other.major && self.minor >= other.minor
    }

    pub fn is_breaking_change(&self, other: &ApiVersion) -> bool {
        self.major != other.major
    }
}

impl fmt::Display for ApiVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

impl Default for ApiVersion {
    fn default() -> Self {
        Self::current()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_api_version_new() {
        let v = ApiVersion::new(0, 1, 2);
        assert_eq!(v.major, 0);
        assert_eq!(v.minor, 1);
        assert_eq!(v.patch, 2);
    }

    #[test]
    fn test_api_version_current() {
        let v = ApiVersion::current();
        assert_eq!(v.major, 0);
        assert_eq!(v.minor, 1);
        assert_eq!(v.patch, 0);
    }

    #[test]
    fn test_api_version_default_is_current() {
        assert_eq!(ApiVersion::default(), ApiVersion::current());
    }

    #[test]
    fn test_api_version_is_compatible_same() {
        let v = ApiVersion::new(0, 1, 0);
        assert!(v.is_compatible_with(&ApiVersion::new(0, 1, 0)));
    }

    #[test]
    fn test_api_version_is_compatible_newer_minor() {
        let v = ApiVersion::new(0, 2, 0);
        assert!(v.is_compatible_with(&ApiVersion::new(0, 1, 0)));
    }

    #[test]
    fn test_api_version_is_not_compatible_older_minor() {
        let v = ApiVersion::new(0, 1, 0);
        assert!(!v.is_compatible_with(&ApiVersion::new(0, 2, 0)));
    }

    #[test]
    fn test_api_version_is_not_compatible_different_major() {
        let v = ApiVersion::new(1, 0, 0);
        assert!(!v.is_compatible_with(&ApiVersion::new(0, 1, 0)));
    }

    #[test]
    fn test_api_version_is_breaking_change_different_major() {
        let v1 = ApiVersion::new(1, 0, 0);
        let v2 = ApiVersion::new(2, 0, 0);
        assert!(v1.is_breaking_change(&v2));
        assert!(v2.is_breaking_change(&v1));
    }

    #[test]
    fn test_api_version_is_not_breaking_change_same_major() {
        let v1 = ApiVersion::new(1, 0, 0);
        let v2 = ApiVersion::new(1, 1, 0);
        assert!(!v1.is_breaking_change(&v2));
    }

    #[test]
    fn test_api_version_display() {
        let v = ApiVersion::new(0, 1, 5);
        assert_eq!(v.to_string(), "0.1.5");
    }

    #[test]
    fn test_api_version_ordering() {
        let v1 = ApiVersion::new(0, 1, 0);
        let v2 = ApiVersion::new(0, 1, 1);
        let v3 = ApiVersion::new(0, 2, 0);
        assert!(v1 < v2);
        assert!(v2 < v3);
    }

    #[test]
    fn test_api_version_debug_clone_eq() {
        let v1 = ApiVersion::new(0, 1, 5);
        let v2 = v1;
        assert_eq!(v1, v2);
        assert!(format!("{:?}", v1).contains("ApiVersion"));
    }
}
