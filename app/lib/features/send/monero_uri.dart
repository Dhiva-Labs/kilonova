import '../../widgets/amount.dart';

/// One recipient from a payment request.
class RequestedPayment {
  const RequestedPayment(this.address, [this.amount]);

  final String address;

  /// Atomic units, if the request names an amount.
  final BigInt? amount;
}

/// A `monero:` payment request, or a bare address.
class PaymentRequest {
  const PaymentRequest(this.payments, {this.recipientName, this.description});

  final List<RequestedPayment> payments;
  final String? recipientName;
  final String? description;
}

final _bareAddress = RegExp(
  r'^[1-9A-HJ-NP-Za-km-z]{95}$|^[1-9A-HJ-NP-Za-km-z]{106}$',
);

/// Reads a `monero:` URI as wallets put in QR codes, for example
/// `monero:4...?tx_amount=1.5&recipient_name=Shop`, with several recipients
/// separated by `;`. A bare address is accepted too. Returns null for
/// anything else, including an amount that is not a valid XMR amount.
///
/// Addresses are not checked here; sending checks them for the wallet's
/// network.
PaymentRequest? parsePaymentRequest(String text) {
  final trimmed = text.trim();
  if (_bareAddress.hasMatch(trimmed)) {
    return PaymentRequest([RequestedPayment(trimmed)]);
  }
  const scheme = 'monero:';
  if (!trimmed.toLowerCase().startsWith(scheme)) return null;
  final rest = trimmed.substring(scheme.length);
  final question = rest.indexOf('?');
  final path = question < 0 ? rest : rest.substring(0, question);
  final Map<String, String> query;
  try {
    query = question < 0
        ? const {}
        : Uri.splitQueryString(rest.substring(question + 1));
  } on FormatException {
    return null;
  }
  final addresses = path
      .replaceFirst(RegExp('^//'), '')
      .split(';')
      .map((a) => a.trim())
      .toList();
  if (addresses.any((a) => a.isEmpty)) return null;
  final amounts = query['tx_amount']?.split(';') ?? const <String>[];
  if (amounts.length > addresses.length) return null;
  final payments = <RequestedPayment>[];
  for (var i = 0; i < addresses.length; i++) {
    BigInt? amount;
    if (i < amounts.length && amounts[i].isNotEmpty) {
      amount = parseXmr(amounts[i]);
      if (amount == null) return null;
    }
    payments.add(RequestedPayment(addresses[i], amount));
  }
  String? nonEmpty(String? v) => v == null || v.isEmpty ? null : v;
  return PaymentRequest(
    payments,
    recipientName: nonEmpty(query['recipient_name']),
    description: nonEmpty(query['tx_description']),
  );
}

/// A `monero:` URI asking for a payment to [address].
String paymentRequestUri(String address, {BigInt? amount}) => amount == null
    ? 'monero:$address'
    : 'monero:$address?tx_amount=${formatXmr(amount)}';
