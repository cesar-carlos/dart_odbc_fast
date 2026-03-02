#[derive(Debug, PartialEq, Eq)]
pub struct ProtocolVersion {
    pub major: u16,
    pub minor: u16,
}

impl ProtocolVersion {
    pub fn new(major: u16, minor: u16) -> Self {
        Self { major, minor }
    }

    pub fn current() -> Self {
        Self::new(1, 0)
    }

    pub fn supports(&self, other: &ProtocolVersion) -> bool {
        self.major == other.major && self.minor >= other.minor
    }
}

pub struct ProtocolEngine {
    version: ProtocolVersion,
}

impl ProtocolEngine {
    pub fn new(version: ProtocolVersion) -> Self {
        Self { version }
    }

    pub fn current() -> Self {
        Self::new(ProtocolVersion::current())
    }

    pub fn version(&self) -> &ProtocolVersion {
        &self.version
    }

    pub fn negotiate(&self, client_version: ProtocolVersion) -> Result<ProtocolVersion, String> {
        if self.version.supports(&client_version) {
            Ok(client_version)
        } else if client_version.supports(&self.version) {
            Ok(self.version.clone())
        } else {
            Err(format!(
                "Version mismatch: engine={}.{}, client={}.{}",
                self.version.major, self.version.minor, client_version.major, client_version.minor
            ))
        }
    }
}

impl Clone for ProtocolVersion {
    fn clone(&self) -> Self {
        Self {
            major: self.major,
            minor: self.minor,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_protocol_version_new() {
        let version = ProtocolVersion::new(1, 0);
        assert_eq!(version.major, 1);
        assert_eq!(version.minor, 0);
    }

    #[test]
    fn test_protocol_version_current() {
        let version = ProtocolVersion::current();
        assert_eq!(version.major, 1);
        assert_eq!(version.minor, 0);
    }

    #[test]
    fn test_protocol_version_supports_same_version() {
        let v1 = ProtocolVersion::new(1, 0);
        let v2 = ProtocolVersion::new(1, 0);
        assert!(v1.supports(&v2));
    }

    #[test]
    fn test_protocol_version_supports_newer_minor() {
        let v1 = ProtocolVersion::new(1, 0);
        let v2 = ProtocolVersion::new(1, 1);
        assert!(!v1.supports(&v2));
    }

    #[test]
    fn test_protocol_version_newer_supports_older() {
        let v1 = ProtocolVersion::new(1, 1);
        let v2 = ProtocolVersion::new(1, 0);
        assert!(v1.supports(&v2));
    }

    #[test]
    fn test_protocol_version_supports_older_minor() {
        let v1 = ProtocolVersion::new(1, 1);
        let v2 = ProtocolVersion::new(1, 0);
        assert!(v1.supports(&v2));
    }

    #[test]
    fn test_protocol_version_supports_different_major() {
        let v1 = ProtocolVersion::new(1, 0);
        let v2 = ProtocolVersion::new(2, 0);
        assert!(!v1.supports(&v2));
    }

    #[test]
    fn test_protocol_version_clone() {
        let v1 = ProtocolVersion::new(2, 5);
        let v2 = v1.clone();
        assert_eq!(v1.major, v2.major);
        assert_eq!(v1.minor, v2.minor);
    }

    #[test]
    fn test_protocol_engine_new() {
        let version = ProtocolVersion::new(1, 0);
        let engine = ProtocolEngine::new(version);
        assert_eq!(engine.version().major, 1);
        assert_eq!(engine.version().minor, 0);
    }

    #[test]
    fn test_protocol_engine_current() {
        let engine = ProtocolEngine::current();
        assert_eq!(engine.version().major, 1);
        assert_eq!(engine.version().minor, 0);
    }

    #[test]
    fn test_protocol_engine_version() {
        let version = ProtocolVersion::new(2, 3);
        let engine = ProtocolEngine::new(version);
        let retrieved = engine.version();
        assert_eq!(retrieved.major, 2);
        assert_eq!(retrieved.minor, 3);
    }

    #[test]
    fn test_protocol_engine_negotiate_same_version() {
        let engine = ProtocolEngine::new(ProtocolVersion::new(1, 0));
        let client = ProtocolVersion::new(1, 0);
        let result = engine.negotiate(client.clone());
        assert!(result.is_ok());
        let negotiated = result.unwrap();
        assert_eq!(negotiated.major, 1);
        assert_eq!(negotiated.minor, 0);
    }

    #[test]
    fn test_protocol_engine_negotiate_newer_client_minor() {
        let engine = ProtocolEngine::new(ProtocolVersion::new(1, 0));
        let client = ProtocolVersion::new(1, 1);
        let result = engine.negotiate(client);
        assert!(result.is_ok());
        let negotiated = result.unwrap();
        assert_eq!(negotiated.major, 1);
        assert_eq!(negotiated.minor, 0);
    }

    #[test]
    fn test_protocol_engine_negotiate_older_client_minor() {
        let engine = ProtocolEngine::new(ProtocolVersion::new(1, 2));
        let client = ProtocolVersion::new(1, 0);
        let result = engine.negotiate(client);
        assert!(result.is_ok());
        let negotiated = result.unwrap();
        assert_eq!(negotiated.major, 1);
        assert_eq!(negotiated.minor, 0);
    }

    #[test]
    fn test_protocol_engine_negotiate_client_supports_engine() {
        let engine = ProtocolEngine::new(ProtocolVersion::new(1, 0));
        let client = ProtocolVersion::new(1, 0);
        let result = engine.negotiate(client);
        assert!(result.is_ok());
    }

    #[test]
    fn test_protocol_engine_negotiate_version_mismatch() {
        let engine = ProtocolEngine::new(ProtocolVersion::new(1, 0));
        let client = ProtocolVersion::new(2, 0);
        let result = engine.negotiate(client);
        assert!(result.is_err());
        let error = result.unwrap_err();
        assert!(error.contains("Version mismatch"));
        assert!(error.contains("engine=1.0"));
        assert!(error.contains("client=2.0"));
    }

    #[test]
    fn test_protocol_engine_negotiate_fallback_to_v1() {
        let engine = ProtocolEngine::new(ProtocolVersion::new(2, 0));
        let client = ProtocolVersion::new(1, 0);
        let result = engine.negotiate(client);
        assert!(result.is_err(), "v2 engine should not support v1 client (major mismatch)");
    }

    #[test]
    fn test_protocol_engine_negotiate_v1_engine_with_v2_client() {
        let engine = ProtocolEngine::new(ProtocolVersion::new(1, 0));
        let client = ProtocolVersion::new(2, 0);
        let result = engine.negotiate(client);
        assert!(result.is_err(), "v1 engine should not support v2 client (major mismatch)");
    }

    #[test]
    fn test_protocol_engine_negotiate_v1_engine_with_v1_client() {
        let engine = ProtocolEngine::new(ProtocolVersion::new(1, 0));
        let client = ProtocolVersion::new(1, 0);
        let result = engine.negotiate(client);
        assert!(result.is_ok());
        let negotiated = result.unwrap();
        assert_eq!(negotiated.major, 1);
        assert_eq!(negotiated.minor, 0);
    }

    #[test]
    fn test_protocol_engine_negotiate_minor_version_downgrade() {
        let engine = ProtocolEngine::new(ProtocolVersion::new(1, 5));
        let client = ProtocolVersion::new(1, 3);
        let result = engine.negotiate(client);
        assert!(result.is_ok());
        let negotiated = result.unwrap();
        assert_eq!(negotiated.major, 1);
        assert_eq!(negotiated.minor, 3, "Should negotiate to client's minor version");
    }

    #[test]
    fn test_protocol_engine_negotiate_minor_version_upgrade() {
        let engine = ProtocolEngine::new(ProtocolVersion::new(1, 3));
        let client = ProtocolVersion::new(1, 5);
        let result = engine.negotiate(client);
        assert!(result.is_ok());
        let negotiated = result.unwrap();
        assert_eq!(negotiated.major, 1);
        assert_eq!(negotiated.minor, 3, "Should negotiate to engine's minor version (client too new)");
    }

    #[test]
    fn test_protocol_version_supports_v1_compatibility() {
        let v1_0 = ProtocolVersion::new(1, 0);
        let v1_1 = ProtocolVersion::new(1, 1);
        let v1_5 = ProtocolVersion::new(1, 5);

        assert!(v1_0.supports(&v1_0), "v1.0 should support v1.0");
        assert!(v1_1.supports(&v1_0), "v1.1 should support v1.0 (backward compatible)");
        assert!(v1_5.supports(&v1_0), "v1.5 should support v1.0 (backward compatible)");
        assert!(!v1_0.supports(&v1_1), "v1.0 should not support v1.1 (needs upgrade)");
    }

    #[test]
    fn test_protocol_version_major_mismatch_not_supported() {
        let v1 = ProtocolVersion::new(1, 0);
        let v2 = ProtocolVersion::new(2, 0);
        let v3 = ProtocolVersion::new(3, 0);

        assert!(!v1.supports(&v2), "v1 should not support v2");
        assert!(!v2.supports(&v1), "v2 should not support v1");
        assert!(!v2.supports(&v3), "v2 should not support v3");
    }
}
