import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/sync.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/amount.dart';
import '../../widgets/error_line.dart';
import '../../widgets/sync_orbit.dart';

/// Balance and sync status for an open wallet.
class SyncPanel extends StatelessWidget {
  const SyncPanel({
    super.key,
    required this.wallet,
    required this.event,
    required this.onRetry,
  });

  final OpenWallet wallet;
  final SyncEvent? event;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final c = context.kn;
    final balance = wallet.balance();
    final summary = wallet.summary();
    final lwsPending = event?.failure == SyncFailure.lwsNotAvailable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.balanceTitle, style: text.labelMedium),
        const SizedBox(height: KnSpace.xs),
        AmountText(balance.total, size: 28),
        if (balance.unlocked != balance.total) ...[
          const SizedBox(height: KnSpace.xs),
          Text(
            l.spendableAmount(formatXmr(balance.unlocked)),
            style: monoStyle(context, size: 13, color: c.textSecondary),
          ),
        ],
        if (summary.viewOnly) ...[
          const SizedBox(height: KnSpace.sm),
          Text(l.viewOnlyBalanceNote, style: text.bodySmall),
        ],
        const SizedBox(height: KnSpace.md),
        if (lwsPending)
          Text(
            l.syncLwsNotYet,
            style: text.bodyMedium!.copyWith(color: c.textSecondary),
          )
        else
          _SyncStatus(event: event, onRetry: onRetry),
      ],
    );
  }
}

class _SyncStatus extends StatelessWidget {
  const _SyncStatus({required this.event, required this.onRetry});

  final SyncEvent? event;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = context.kn;
    final e = event;
    final failure = e?.failure;

    if (e != null && e.phase == SyncPhase.failed && failure != null) {
      final message = switch (failure) {
        SyncFailure.nodeUnreachable => l.syncNodeUnreachable,
        SyncFailure.wrongNetwork => l.syncWrongNetwork,
        SyncFailure.badNode => l.syncBadNode,
        SyncFailure.lwsNotAvailable => l.syncLwsNotYet,
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ErrorLine(message),
          if (failure != SyncFailure.nodeUnreachable)
            TextButton(onPressed: onRetry, child: Text(l.syncRetry)),
        ],
      );
    }

    final (progress, label) = switch (e?.phase) {
      null => (0.0, l.syncStarting),
      SyncPhase.connecting => (0.0, l.syncConnecting(_host(e!.node))),
      SyncPhase.scanning => (
        e!.tip == BigInt.zero ? 0.0 : e.scanned / e.tip,
        l.syncScanning(_group(e.scanned), _group(e.tip)),
      ),
      SyncPhase.synced => (1.0, l.syncSynced(_group(e!.tip))),
      SyncPhase.stopped || SyncPhase.failed => (0.0, l.syncStopped),
    };
    return Row(
      children: [
        Semantics(
          value: '${(progress * 100).round()}%',
          child: SyncOrbit(progress: progress),
        ),
        const SizedBox(width: KnSpace.sm),
        Expanded(
          child: Text(
            label,
            style: monoStyle(context, size: 13, color: c.textSecondary),
          ),
        ),
        if (e?.phase == SyncPhase.stopped)
          TextButton(onPressed: onRetry, child: Text(l.syncRetry)),
      ],
    );
  }

  static String _host(String? url) =>
      url == null ? '' : Uri.tryParse(url)?.host ?? url;
}

/// 3412880 -> 3,412,880.
String _group(BigInt n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
