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
}
