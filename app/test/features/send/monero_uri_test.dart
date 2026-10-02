import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/send/monero_uri.dart';
import 'package:kilonova/widgets/amount.dart';

const _a =
    '44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A';
const _b =
    '888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H';

void main() {
  group('parseXmr', () {
    test('reads whole and fractional amounts', () {
      expect(parseXmr('1'), BigInt.parse('1000000000000'));
      expect(parseXmr('1.5'), BigInt.parse('1500000000000'));
      expect(parseXmr('.25'), BigInt.parse('250000000000'));
      expect(parseXmr(' 0.000000000001 '), BigInt.one);
      expect(
        parseXmr('18446744.073709551616'),
        BigInt.parse('18446744073709551616'),
      );
    });

    test('rejects anything else', () {
      for (final bad in [
        '',
        '.',
        '1.2.3',
        '-1',
        '1e3',
        '0.0000000000001',
        '1,5',
        'abc',
      ]) {
        expect(parseXmr(bad), isNull, reason: bad);
      }
    });

    test('round-trips with formatXmr', () {
      for (final v in ['0.1', '12.000000000001', '3.0']) {
        expect(formatXmr(parseXmr(v)!), v);
      }
    });
  });

  group('parsePaymentRequest', () {
    test('a bare address', () {
      final r = parsePaymentRequest('  $_a ')!;
      expect(r.payments.single.address, _a);
      expect(r.payments.single.amount, isNull);
    });

    test('a monero: URI with amount, name and description', () {
      final r = parsePaymentRequest(
        'monero:$_a?tx_amount=0.25&recipient_name=Corner%20Shop&tx_description=Coffee',
      )!;
      expect(r.payments.single.address, _a);
      expect(r.payments.single.amount, BigInt.parse('250000000000'));
      expect(r.recipientName, 'Corner Shop');
      expect(r.description, 'Coffee');
    });

    test('several recipients', () {
      final r = parsePaymentRequest('MONERO:$_a;$_b?tx_amount=1;2.5')!;
      expect(r.payments.map((p) => p.address), [_a, _b]);
      expect(r.payments.map((p) => p.amount), [
        BigInt.parse('1000000000000'),
        BigInt.parse('2500000000000'),
      ]);
    });

    test('rejects malformed requests', () {
      for (final bad in [
        'bitcoin:$_a',
        'monero:',
        'monero:$_a?tx_amount=lots',
        'monero:$_a?tx_amount=1;2',
        'monero:$_a;;$_b',
        'hello',
      ]) {
        expect(parsePaymentRequest(bad), isNull, reason: bad);
      }
    });

    test('builds request URIs that read back', () {
      final uri = paymentRequestUri(_a, amount: BigInt.parse('1500000000000'));
      expect(uri, 'monero:$_a?tx_amount=1.5');
      expect(
        parsePaymentRequest(uri)!.payments.single.amount,
        BigInt.parse('1500000000000'),
      );
    });
  });
}
