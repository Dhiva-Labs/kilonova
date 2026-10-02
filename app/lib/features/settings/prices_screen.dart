import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/price.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/kn_card.dart';
import 'price_feed.dart';

/// Turn the fiat price on in a currency, or off.
class PricesScreen extends StatefulWidget {
  const PricesScreen({super.key, required this.feed});

  final PriceFeed feed;

  @override
  State<PricesScreen> createState() => _PricesScreenState();
}

class _PricesScreenState extends State<PricesScreen> {
  String? _currency;

  @override
  void initState() {
    super.initState();
    _currency = widget.feed.currency;
  }

  Future<void> _choose(String? currency) async {
    setState(() => _currency = currency);
    await setPriceCurrency(currency: currency);
    await widget.feed.reload();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final phone = context.isPhoneWidth;

    Widget radioRow(String? value, String title) => KnRow(
      onTap: () => _choose(value),
      leading: Radio<String?>(value: value),
      title: Text(title),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l.pricesTitle)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            children: [
              Text(
                l.pricesHelp(Uri.parse(priceSource()).host),
                style: text.bodyMedium,
              ),
              const SizedBox(height: KnSpace.lg),
              RadioGroup<String?>(
                groupValue: _currency,
                onChanged: _choose,
                child: KnCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: withDividers([
                      radioRow(null, l.pricesOff),
                      for (final c in priceCurrencies())
                        radioRow(c, c.toUpperCase()),
                    ]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
