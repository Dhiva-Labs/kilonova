//! Turning a wallet's creation time into a block height to start scanning
//! from, so restoring a Polyseed wallet does not scan the whole chain.

use kn_keys::Network;

/// `(height, unix time)` of real blocks, read from public nodes on
/// 2026-10-02. Times between points are interpolated; times after the last
/// point are extrapolated at the two-minute block target.
const MAINNET: &[(u64, u64)] = &[
    (1, 1_397_818_193),
    (1_000_000, 1_458_145_453),
    (2_000_000, 1_577_680_194),
    (3_000_000, 1_697_813_342),
    (3_775_251, 1_790_944_626),
];
const STAGENET: &[(u64, u64)] = &[
    (1, 1_518_932_025),
    (1_000_000, 1_641_236_677),
    (2_000_000, 1_764_246_150),
    (2_220_433, 1_790_944_886),
];
const TESTNET: &[(u64, u64)] = &[
    (1, 1_410_295_020),
    (1_000_000, 1_505_675_844),
    (2_000_000, 1_654_880_634),
    (3_000_000, 1_778_444_160),
    (3_101_064, 1_790_944_941),
];

const BLOCK_SECONDS: u64 = 120;

/// Polyseed stores its birthday with about one month of precision, so start
/// a month earlier than the estimate to be sure no payment is missed.
const SAFETY_SECONDS: u64 = 31 * 24 * 60 * 60;

/// A block height at or before the chain reached `unix_time`, minus a month
/// of safety margin. Never past the real height at that time.
#[must_use]
pub fn approximate_height(network: Network, unix_time: u64) -> u64 {
    let points = match network {
        Network::Mainnet => MAINNET,
        Network::Stagenet => STAGENET,
        Network::Testnet => TESTNET,
    };
    let t = unix_time.saturating_sub(SAFETY_SECONDS);
    if t <= points[0].1 {
        return 0;
    }
    for pair in points.windows(2) {
        let ((h0, t0), (h1, t1)) = (pair[0], pair[1]);
        if t <= t1 {
            // Integer interpolation, rounded down.
            return h0 + (h1 - h0) * (t - t0) / (t1 - t0);
        }
    }
    let (h, last) = points[points.len() - 1];
    h + (t - last) / BLOCK_SECONDS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_points_minus_the_margin() {
        // A wallet made right at a known block starts a month earlier.
        let h = approximate_height(Network::Mainnet, 1_790_944_626);
        let month_of_blocks = SAFETY_SECONDS / BLOCK_SECONDS;
        assert!(h <= 3_775_251 - month_of_blocks + 100);
        assert!(h >= 3_775_251 - month_of_blocks - 1_000);
    }

    #[test]
    fn early_times_start_at_genesis() {
        assert_eq!(approximate_height(Network::Mainnet, 0), 0);
        assert_eq!(approximate_height(Network::Stagenet, 1_518_932_025), 0);
    }

    #[test]
    fn future_times_extrapolate_at_two_minutes() {
        let a = approximate_height(Network::Testnet, 1_800_000_000);
        let b = approximate_height(Network::Testnet, 1_800_000_000 + 120 * 1_000);
        assert_eq!(b - a, 1_000);
    }

    #[test]
    fn heights_never_decrease_with_time() {
        for network in [Network::Mainnet, Network::Stagenet, Network::Testnet] {
            let mut last = 0;
            for t in (1_390_000_000..1_800_000_000).step_by(1_000_000) {
                let h = approximate_height(network, t);
                assert!(h >= last);
                last = h;
            }
        }
    }
}
