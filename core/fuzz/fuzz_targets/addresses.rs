//! Node, server and proxy addresses as a user (or a pasted link) gives them.
#![no_main]

libfuzzer_sys::fuzz_target!(|data: &[u8]| {
    if let Ok(text) = std::str::from_utf8(data) {
        if let Ok(url) = kn_sync::NodeUrl::parse(text) {
            let _ = url.is_onion();
        }
        let _ = kn_sync::ProxyUrl::parse(text);
    }
});
