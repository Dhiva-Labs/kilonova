/// Facts about the Rust core the app was built against.
pub struct CoreInfo {
    /// Version of the core crates, from `Cargo.toml`.
    pub version: String,
}

/// Returns build information for the About screen.
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn core_info() -> CoreInfo {
    CoreInfo {
        version: env!("CARGO_PKG_VERSION").to_owned(),
    }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn core_info_reports_crate_version() {
        assert_eq!(core_info().version, env!("CARGO_PKG_VERSION"));
    }
}
