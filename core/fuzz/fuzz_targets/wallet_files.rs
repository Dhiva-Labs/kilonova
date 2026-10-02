//! Damaged or hostile wallet files and registries.
#![no_main]

libfuzzer_sys::fuzz_target!(|data: &[u8]| {
    kn_store::fuzzing::wallet_file(data);
    kn_store::fuzzing::contents(data);
});
