import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/sync.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/amount.dart';

/// Transactions, newest first.
class HistoryList extends StatelessWidget {
  const HistoryList({super.key, required this.items, this.onOpen});

  final List<HistoryItem> items;

  /// Opens a transaction's details.
  final ValueChanged<HistoryItem>? onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: KnSpace.md),
        child: Text(l.historyEmpty, style: text.bodyMedium),
      );
    }
    return Column(
      children: [
        for (final item in items) ...[
          _HistoryTile(
            item: item,
            onOpen: onOpen == null ? null : () => onOpen!(item),
          ),
          const Divider(),
        ],
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.item, this.onOpen});

  final HistoryItem item;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = context.kn;
    final text = Theme.of(context).textTheme;
    final color = item.incoming ? c.received : c.text;
    final kind = item.miner
        ? l.historyMined
        : item.incoming
        ? l.historyReceived
        : l.historySent;
    final tags = [
      kind,
      if (item.locked) l.historyLocked,
      if (item.pending)
        l.historyPending
      else
        l.historyBlock(item.height.toString()),
    ].join(' · ');
    final sentTo = item.sentTo;
    final detail =
        item.note ?? (sentTo == null ? null : l.historyTo(_short(sentTo)));

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: KnSpace.sm),
        child: Row(
          children: [
            Icon(
              item.incoming ? Icons.south_west : Icons.north_east,
              size: 20,
              color: color,
              semanticLabel: kind,
            ),
            const SizedBox(width: KnSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AmountText(
                    item.amount,
                    prefix: item.incoming ? '+' : '-',
                    color: color,
                  ),
                  const SizedBox(height: 2),
                  Text(tags, style: text.bodySmall),
                  if (detail != null)
                    Text(
                      detail,
                      style: text.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: l.historyCopyTx,
              icon: const Icon(Icons.copy_outlined, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: item.txHash));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text(l.txCopiedNotice)));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// A long address shortened to its ends; contact names stay whole.
  static String _short(String s) =>
      s.length > 24 ? '${s.substring(0, 8)}…${s.substring(s.length - 8)}' : s;
}
