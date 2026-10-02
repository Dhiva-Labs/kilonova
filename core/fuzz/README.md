# Fuzzing

Targets for what Kilonova reads from outside: light wallet server answers,
addresses users type or paste, and wallet files on disk. They need nightly
Rust and [cargo-fuzz](https://github.com/rust-fuzz/cargo-fuzz):

```sh
rustup toolchain install nightly
cargo install cargo-fuzz
cd core/fuzz
cargo +nightly fuzz run lws_replies -- -max_total_time=300
cargo +nightly fuzz run addresses -- -max_total_time=300
cargo +nightly fuzz run wallet_files -- -max_total_time=300
```

`corpus/` holds seed inputs. A crash leaves its input in `artifacts/`; add
it to the matching test as a regression case when fixing it. The weekly
`fuzz.yml` workflow runs every target for a few minutes.
