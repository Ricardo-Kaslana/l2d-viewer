//! Bridge layer between Mocari (moc3 runtime) and the Flutter shell.
//! Public API is exposed via flutter_rust_bridge; see `frb_api.rs` (Phase 2+).

mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */

pub mod error;
pub mod frb_api;
pub mod hit;
pub mod manifest;
pub mod model;
pub mod render;

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_set() {
        assert!(!version().is_empty());
    }
}
