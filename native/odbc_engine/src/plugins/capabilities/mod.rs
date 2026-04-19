//! Driver-specific capabilities exposed as **opt-in traits** (v3.0.0).
//!
//! `DriverPlugin` defines the *contract every plugin must satisfy* (name, type
//! mapping, query optimisation). Anything beyond that — native bulk loaders,
//! UPSERT, RETURNING, dialect-aware quoting, schema introspection, session
//! initialization — is grouped here as **separate traits** that a plugin may
//! implement when (and only when) it makes sense for that engine.
//!
//! ## Discovery
//!
//! Plugins implement these traits **in addition to** `DriverPlugin`. The
//! [`PluginRegistry`](crate::plugins::PluginRegistry) exposes lookup helpers
//! such as [`PluginRegistry::bulk_loader_for`] etc. that resolve a plugin by
//! engine id and downcast it to the requested capability.
//!
//! ## SOLID rationale
//!
//! - **Interface segregation**: a plugin is not forced to implement methods it
//!   does not support.
//! - **Open/closed**: new capabilities can be added without changing
//!   `DriverPlugin` or any existing plugin.
//! - **Dependency inversion**: callers depend on capability traits, not on
//!   concrete plugin types.

pub mod bulk_loader;
pub mod catalog_provider;
pub mod quoter;
pub mod returning;
pub mod session_init;
pub mod type_catalog;
pub mod upsert;

pub use bulk_loader::{BulkLoadOptions, BulkLoader};
pub use catalog_provider::{CatalogProvider, CatalogQuery};
pub use quoter::IdentifierQuoter;
pub use returning::Returnable;
pub use session_init::{SessionInitializer, SessionOptions};
pub use type_catalog::TypeCatalog;
pub use upsert::Upsertable;

/// Convenience enum naming the seven capabilities exposed in v3.0.0.
/// Used by introspection endpoints (`odbc_get_plugin_capabilities`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum CapabilityKind {
    BulkLoader,
    Upsertable,
    Returnable,
    TypeCatalog,
    IdentifierQuoter,
    CatalogProvider,
    SessionInitializer,
}

impl CapabilityKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            CapabilityKind::BulkLoader => "bulk_loader",
            CapabilityKind::Upsertable => "upsertable",
            CapabilityKind::Returnable => "returnable",
            CapabilityKind::TypeCatalog => "type_catalog",
            CapabilityKind::IdentifierQuoter => "identifier_quoter",
            CapabilityKind::CatalogProvider => "catalog_provider",
            CapabilityKind::SessionInitializer => "session_initializer",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capability_kind_strings_are_stable() {
        assert_eq!(CapabilityKind::BulkLoader.as_str(), "bulk_loader");
        assert_eq!(CapabilityKind::Upsertable.as_str(), "upsertable");
        assert_eq!(CapabilityKind::Returnable.as_str(), "returnable");
        assert_eq!(CapabilityKind::TypeCatalog.as_str(), "type_catalog");
        assert_eq!(
            CapabilityKind::IdentifierQuoter.as_str(),
            "identifier_quoter"
        );
        assert_eq!(CapabilityKind::CatalogProvider.as_str(), "catalog_provider");
        assert_eq!(
            CapabilityKind::SessionInitializer.as_str(),
            "session_initializer"
        );
    }

    #[test]
    fn capability_kind_is_hashable_and_eq() {
        let a = CapabilityKind::BulkLoader;
        let b = CapabilityKind::BulkLoader;
        assert_eq!(a, b);
    }
}
