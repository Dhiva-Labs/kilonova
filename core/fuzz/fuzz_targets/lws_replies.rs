//! Answers a light wallet server could send, through the code that decides
//! what to believe.
#![no_main]

libfuzzer_sys::fuzz_target!(|data: &[u8]| {
    kn_sync::fuzzing::lws_replies(data);
    kn_sync::fuzzing::cache(data);
});
