import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/sync.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/amount.dart';
import '../../widgets/error_line.dart';
import '../../widgets/sync_orbit.dart';
import '../settings/lws_servers_screen.dart';
import '../settings/price_feed.dart';
import 'lws_consent_dialog.dart';

/// Balance and sync status for an open wallet.
class SyncPanel extends StatelessWidget {
  const SyncPanel({
    super.key,
    required this.wallet,
    required this.event,
    required this.onRetry,
    this.prices,
  });

  final OpenWallet wallet;
  final SyncEvent? event;

  /// Shows the balance in the user's currency, if prices are on.
  final PriceFeed? prices;

  /// Starts sync again, after an error or a settings change.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final c = context.kn;
    final balance = wallet.balance();
    final summary = wallet.summary();
    final e = event;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.balanceTitle, style: text.labelMedium),
        const SizedBox(height: KnSpace.xs),
        AmountText(balance.total, size: 28),
        if (prices != null)
          ListenableBuilder(
            listenable: prices!,
            builder: (context, _) {
              final fiat = prices!.format(balance.total);
              return fiat == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: KnSpace.xs),
                      child: Text(
                        l.fiatApprox(fiat),
                        style: monoStyle(
                          context,
                          size: 13,
                          color: c.textSecondary,
                        ),
                      ),
                    );
            },
          ),
        if (balance.unlocked != balance.total) ...[
          const SizedBox(height: KnSpace.xs),
          Text(
            l.spendableAmount(formatXmr(balance.unlocked)),
            style: monoStyle(context, size: 13, color: c.textSecondary),
          ),
        ],
        if (balance.incoming > BigInt.zero) ...[
          const SizedBox(height: KnSpace.xs),
          Text(
            l.incomingAmount(formatXmr(balance.incoming)),
            style: monoStyle(context, size: 13, color: c.received),
          ),
        ],
        if (summary.viewOnly) ...[
          const SizedBox(height: KnSpace.sm),
          Text(l.viewOnlyBalanceNote, style: text.bodySmall),
        ],
        const SizedBox(height: KnSpace.md),
        _SyncStatus(wallet: wallet, event: e, onRetry: onRetry),
        if (e != null && e.rejectedOutputs > 0) ...[
          const SizedBox(height: KnSpace.sm),
          ErrorLine(l.syncLwsRejected(e.rejectedOutputs)),
        ],
        if (e != null && e.importPending) ...[
          const SizedBox(height: KnSpace.sm),
          Text(l.syncLwsImportPending, style: text.bodySmall),
        ],
      ],
    );
  }
}

class _SyncStatus extends StatelessWidget {
  const _SyncStatus({
    required this.wallet,
    required this.event,
    required this.onRetry,
  });

  final OpenWallet wallet;
  final SyncEvent? event;
  final VoidCallback onRetry;

  Future<void> _review(BuildContext context) async {
    final server = await wallet.lwsConsentNeeded();
    if (server == null || !context.mounted) return;
    final agreed = await showLwsConsentDialog(context, server);
    if (!agreed) return;
    await wallet.grantLwsConsent(server: server);
    onRetry();
  }

  Future<void> _setServer(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            LwsServersScreen(initialNetwork: wallet.summary().network),
      ),
    );
    onRetry();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = context.kn;
    final e = event;
    final failure = e?.failure;

    if (e != null && e.phase == SyncPhase.failed && failure != null) {
      return switch (failure) {
        SyncFailure.lwsConsentNeeded => _Action(
          message: l.syncLwsConsentNeeded(_host(e.node ?? '')),
          action: l.syncLwsReview,
          onPressed: () => _review(context),
          error: false,
        ),
        SyncFailure.lwsServerNotSet => _Action(
          message: l.syncLwsServerNotSet,
          action: l.syncLwsSetServer,
          onPressed: () => _setServer(context),
          error: false,
        ),
        SyncFailure.nodeUnreachable => ErrorLine(l.syncNodeUnreachable),
        SyncFailure.wrongNetwork => _Action(
          message: l.syncWrongNetwork,
          action: l.syncRetry,
          onPressed: onRetry,
        ),
        SyncFailure.badNode => _Action(
          message: l.syncBadNode,
          action: l.syncRetry,
          onPressed: onRetry,
        ),
        SyncFailure.lwsDenied => _Action(
          message: l.syncLwsDenied,
          action: l.syncRetry,
          onPressed: onRetry,
        ),
        SyncFailure.needsTor => ErrorLine(l.syncNeedsTor),
        SyncFailure.insecureLws => _Action(
          message: l.syncInsecureLws,
          action: l.syncLwsSetServer,
          onPressed: () => _setServer(context),
        ),
        SyncFailure.lwsCreationRefused => _Action(
          message: l.syncLwsCreationRefused,
          action: l.syncLwsSetServer,
          onPressed: () => _setServer(context),
        ),
      };
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

/// A message with one action. Errors get the error icon; prompts for the
/// user to do something do not.
class _Action extends StatelessWidget {
  const _Action({
    required this.message,
    required this.action,
    required this.onPressed,
    this.error = true,
  });

  final String message;
  final String action;
  final VoidCallback onPressed;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (error)
          ErrorLine(message)
        else
          Text(message, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: KnSpace.xs),
        TextButton(onPressed: onPressed, child: Text(action)),
      ],
    );
  }
}

/// 3412880 -> 3,412,880.
String _group(BigInt n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
