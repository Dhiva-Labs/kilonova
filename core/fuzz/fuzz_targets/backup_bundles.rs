//! Damaged or hostile backup bundles: the header, and the payload as if it
//! had decrypted.
#![no_main]

libfuzzer_sys::fuzz_target!(|data: &[u8]| {
    kn_store::fuzzing::bundle(data);
});
