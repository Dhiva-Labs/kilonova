import assert from 'node:assert/strict';
import { test } from 'node:test';
import { formatHeight, formatXmr, nodeHost, xmrParts } from '../../src/format.ts';

test('formats like the app', () => {
  assert.equal(formatXmr(0n), '0.0');
  assert.equal(formatXmr(1n), '0.000000000001');
  assert.equal(formatXmr(12_500_000_000_000n), '12.5');
  assert.equal(formatXmr(2_607_498_016_962_174n), '2607.498016962174');
});

test('splits for display', () => {
  assert.deepEqual(xmrParts(2_607_498_016_962_174n), { whole: '2,607', head: '4980', tail: '16962174' });
  assert.deepEqual(xmrParts(12_500_000_000_000n), { whole: '12', head: '5', tail: '' });
  assert.deepEqual(xmrParts(0n), { whole: '0', head: '0', tail: '' });
});

test('heights and hosts', () => {
  assert.equal(formatHeight(3412880), '3,412,880');
  assert.equal(formatHeight(999), '999');
  assert.equal(nodeHost('http://node.example.org:18089'), 'node.example.org:18089');
});
