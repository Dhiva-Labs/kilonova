import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../../src/rust/api/price.dart';

/// The optional XMR price in the user's currency. Off by default; while off
/// nothing is fetched. Refreshed at most every [maxAge], when sync reports.
class PriceFeed extends ChangeNotifier {
  PriceFeed({
    this.maxAge = const Duration(minutes: 10),
    Future<double?> Function()? fetch,
  }) : _fetch = fetch ?? fetchXmrPrice;

  final Duration maxAge;
  final Future<double?> Function() _fetch;

  String? _currency;
  double? _price;
  DateTime? _fetched;
  bool _loading = false;

  /// Lower-case ISO 4217 code, or null while prices are off.
  String? get currency => _currency;

  /// Price of 1 XMR, once fetched.
  double? get price => _price;

  /// Reads the setting and fetches a fresh price if it is on.
  Future<void> reload() async {
    _currency = await priceCurrency();
    _price = null;
    _fetched = null;
    notifyListeners();
    await refreshIfStale();
  }

  Future<void> refreshIfStale() async {
    final fetched = _fetched;
    if (_currency == null ||
        _loading ||
        (fetched != null && DateTime.now().difference(fetched) < maxAge)) {
      return;
    }
    _loading = true;
    try {
      _price = await _fetch();
      _fetched = DateTime.now();
      notifyListeners();
    } on Object {
      // A missing price is shown as nothing; it is retried later.
    } finally {
      _loading = false;
    }
  }

  /// `atomic` XMR in the chosen currency, formatted, or null. Uses the
  /// currency's symbol where it has one (`$428,151.17`); otherwise the code
  /// follows the number (`428,151.17 INR`) rather than being glued to it.
  String? format(BigInt atomic) {
    final price = _price;
    final currency = _currency;
    if (price == null || currency == null) return null;
    final value = atomic.toDouble() / 1e12 * price;
    final code = currency.toUpperCase();
    final withSymbol = NumberFormat.simpleCurrency(
      name: code,
      decimalDigits: 2,
    );
    if (withSymbol.currencySymbol != code) return withSymbol.format(value);
    return '${NumberFormat.decimalPatternDigits(decimalDigits: 2).format(value)} $code';
  }
}
