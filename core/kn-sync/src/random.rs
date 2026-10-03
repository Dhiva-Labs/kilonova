//! Uniform random choices from the system's generator.

use ring::rand::{SecureRandom as _, SystemRandom};

/// A uniformly random number below `bound` (which must be above zero).
pub(crate) fn uniform(bound: u64) -> u64 {
    let rng = SystemRandom::new();
    // Rejection sampling keeps every value equally likely.
    let zone = u64::MAX - u64::MAX % bound;
    loop {
        let mut bytes = [0u8; 8];
        rng.fill(&mut bytes)
            .expect("the system random number generator works");
        let value = u64::from_le_bytes(bytes);
        if value < zone {
            return value % bound;
        }
    }
}

/// A uniformly random index below `len` (which must be above zero).
pub(crate) fn index(len: usize) -> usize {
    let bound = u64::try_from(len).unwrap_or(u64::MAX);
    usize::try_from(uniform(bound)).expect("below a usize bound")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uniform_stays_below_its_bound() {
        let mut seen = [false; 8];
        for _ in 0..1_000 {
            seen[index(8)] = true;
        }
        assert!(seen.iter().all(|s| *s));
    }
}
