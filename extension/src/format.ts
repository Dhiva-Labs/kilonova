// XMR amounts for display, matching app/lib/widgets/amount.dart.

const PICONERO = 1_000_000_000_000n;

/** `12.5`, `0.000123`: whole part, point, significant decimals. */
export function formatXmr(atomic: bigint): string {
  const whole = atomic / PICONERO;
  const fraction = (atomic % PICONERO).toString().padStart(12, '0').replace(/0+$/, '') || '0';
  return `${whole}.${fraction}`;
}

function group(digits: string): string {
  return digits.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

/**
 * An amount split the way AmountText shows it: grouped whole part, the first
 * four decimals, and the remaining significant decimals (shown smaller).
 */
export function xmrParts(atomic: bigint): { whole: string; head: string; tail: string } {
  const plain = formatXmr(atomic);
  const dot = plain.indexOf('.');
  const fraction = plain.slice(dot + 1);
  const split = Math.min(fraction.length, 4);
  return { whole: group(plain.slice(0, dot)), head: fraction.slice(0, split), tail: fraction.slice(split) };
}

/** `3,412,880`. */
export function formatHeight(height: number): string {
  return group(String(Math.trunc(height)));
}

/** The host of a node URL, for short labels. */
export function nodeHost(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}
