import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/backup.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_line.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/network_label.dart';
import '../wallets/wallet_registry.dart';

String _errorText(AppLocalizations l, BackupError e, int minLength) =>
    switch (e) {
      BackupError.shortPassphrase => l.backupPassphraseTooShort(minLength),
      BackupError.wrongPassphrase => l.backupWrongPassphrase,
      BackupError.notABackup => l.backupNotABackup,
      BackupError.newerVersion => l.backupNewerVersion,
      BackupError.noWallets => l.backupNoWalletsChosen,
      BackupError.notFound ||
      BackupError.storage ||
      BackupError.notInitialized => l.backupStorageError,
    };

String _size(AppLocalizations l, int bytes) {
  if (bytes < 1024) return l.backupSizeBytes(bytes);
  if (bytes < 1024 * 1024) {
    return l.backupSizeKb((bytes / 1024).toStringAsFixed(1));
  }
  return l.backupSizeMb((bytes / (1024 * 1024)).toStringAsFixed(1));
}

/// The page layout both backup screens share.
class _Page extends StatelessWidget {
  const _Page({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.all(
              context.isPhoneWidth ? KnSpace.md : KnSpace.xl,
            ),
            children: children,
          ),
        ),
      ),
    );
  }
}

/// Saves chosen wallets to one file, encrypted with a passphrase of its
/// own. Wallets do not need to be unlocked: their files are copied as
/// stored.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.registry});

  final WalletRegistry registry;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _form = GlobalKey<FormState>();
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  final int _minLength = backupPassphraseMinLength();
  late final Set<String> _chosen = {for (final w in widget.registry.all) w.id};
  bool _busy = false;
  String? _error;
  String? _saved;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    setState(() {
      _error = null;
      _saved = null;
    });
    if (!_form.currentState!.validate()) return;
    if (_chosen.isEmpty) {
      setState(() => _error = l.backupNoWalletsChosen);
      return;
    }
    // Keep the list order, whatever order the boxes were ticked in.
    final ids = [
      for (final w in widget.registry.all)
        if (_chosen.contains(w.id)) w.id,
    ];
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    setState(() => _busy = true);
    try {
      var size = 0;
      final name = await widget.registry.backupFiles.save(
        'kilonova-backup-$date.knbackup',
        (path) async {
          size = (await exportBackup(
            walletIds: ids,
            passphrase: _passphrase.text,
            path: path,
          )).toInt();
        },
      );
      if (!mounted) return;
      setState(() {
        if (name != null) _saved = l.backupSaved(name, _size(l, size));
      });
    } on BackupError catch (e) {
      if (mounted) setState(() => _error = _errorText(l, e, _minLength));
    } catch (_) {
      if (mounted) setState(() => _error = l.backupStorageError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final wallets = widget.registry.all;
    final saved = _saved;
    final error = _error;
    return _Page(
      title: l.backupTitle,
      children: [
        Text(l.backupHelp, style: text.bodyMedium),
        const SizedBox(height: KnSpace.lg),
        Eyebrow(l.backupWalletsLabel),
        const SizedBox(height: KnSpace.sm),
        KnCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: withDividers([
              for (final w in wallets)
                KnRow(
                  leading: Checkbox(
                    value: _chosen.contains(w.id),
                    onChanged: _busy
                        ? null
                        : (on) => setState(
                            () => on == true
                                ? _chosen.add(w.id)
                                : _chosen.remove(w.id),
                          ),
                  ),
                  title: Text(w.name),
                  subtitle: Text(w.network.label(context)),
                ),
            ]),
          ),
        ),
        const SizedBox(height: KnSpace.lg),
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KnField(
                controller: _passphrase,
                label: l.backupPassphraseLabel,
                helper: l.backupPassphraseHelp(_minLength),
                obscure: true,
                enabled: !_busy,
                validator: (v) => (v ?? '').characters.length < _minLength
                    ? l.backupPassphraseTooShort(_minLength)
                    : null,
              ),
              const SizedBox(height: KnSpace.md),
              KnField(
                controller: _confirm,
                label: l.backupPassphraseConfirmLabel,
                obscure: true,
                enabled: !_busy,
                validator: (v) =>
                    v != _passphrase.text ? l.backupPassphraseMismatch : null,
                onSubmitted: (_) => _save(),
              ),
            ],
          ),
        ),
        const SizedBox(height: KnSpace.md),
        Wrap(
          children: [
            KnButton.primary(
              l.backupSaveAction,
              onPressed: _busy ? null : _save,
            ),
          ],
        ),
        if (_busy) ...[
          const SizedBox(height: KnSpace.sm),
          Text(l.backupSaving, style: text.bodySmall),
        ],
        if (error != null) ...[
          const SizedBox(height: KnSpace.md),
          ErrorLine(error),
        ],
        if (saved != null) ...[
          const SizedBox(height: KnSpace.md),
          Text(saved, style: text.bodyMedium),
        ],
      ],
    );
  }
}

/// Adds wallets from a backup file: choose the file, enter its
/// passphrase, check what it holds, then restore.
class RestoreBackupScreen extends StatefulWidget {
  const RestoreBackupScreen({super.key, required this.registry});

  final WalletRegistry registry;

  @override
  State<RestoreBackupScreen> createState() => _RestoreBackupScreenState();
}

class _RestoreBackupScreenState extends State<RestoreBackupScreen> {
  final _passphrase = TextEditingController();
  ({String path, String name})? _file;
  BackupSummary? _summary;
  List<ImportedWallet>? _imported;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    final file = await widget.registry.backupFiles.open();
    if (file == null || !mounted) return;
    setState(() {
      _file = file;
      _summary = null;
      _imported = null;
      _error = null;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on BackupError catch (e) {
      if (mounted) {
        setState(() => _error = _errorText(l, e, backupPassphraseMinLength()));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() => _run(() async {
    final summary = await readBackupSummary(
      path: _file!.path,
      passphrase: _passphrase.text,
    );
    if (mounted) setState(() => _summary = summary);
  });

  Future<void> _import() => _run(() async {
    final imported = await importBackup(
      path: _file!.path,
      passphrase: _passphrase.text,
    );
    await widget.registry.reload();
    if (mounted) {
      setState(() {
        _imported = imported;
        _summary = null;
        _passphrase.clear();
      });
    }
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final file = _file;
    final summary = _summary;
    final imported = _imported;
    final error = _error;
    return _Page(
      title: l.restoreBackupTitle,
      children: [
        Text(l.restoreBackupHelp, style: text.bodyMedium),
        const SizedBox(height: KnSpace.lg),
        Text(
          file == null ? l.restoreBackupNoFile : l.restoreBackupFile(file.name),
          style: text.bodyMedium,
        ),
        const SizedBox(height: KnSpace.sm),
        Wrap(
          children: [
            KnButton.secondary(
              l.restoreBackupChooseAction,
              onPressed: _busy ? null : _choose,
            ),
          ],
        ),
        if (file != null && imported == null) ...[
          const SizedBox(height: KnSpace.lg),
          KnField(
            controller: _passphrase,
            label: l.backupPassphraseLabel,
            obscure: true,
            enabled: !_busy,
            onSubmitted: (_) => summary == null ? _open() : _import(),
          ),
          const SizedBox(height: KnSpace.md),
          if (summary == null)
            Wrap(
              children: [
                KnButton.primary(
                  l.restoreBackupOpenAction,
                  onPressed: _busy ? null : _open,
                ),
              ],
            ),
        ],
        if (summary != null) ...[
          Text(l.restoreBackupPreview(summary.count), style: text.bodyMedium),
          const SizedBox(height: KnSpace.sm),
          KnCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: withDividers([
                for (final w in summary.wallets)
                  KnRow(
                    title: Text(w.name),
                    subtitle: Text(w.network.label(context)),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: KnSpace.md),
          Wrap(
            children: [
              KnButton.primary(
                l.restoreBackupImportAction,
                onPressed: _busy ? null : _import,
              ),
            ],
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: KnSpace.md),
          ErrorLine(error),
        ],
        if (imported != null) ...[
          const SizedBox(height: KnSpace.lg),
          Text(l.restoreBackupDone(imported.length), style: text.bodyMedium),
          for (final w in imported)
            if (w.name != w.originalName) ...[
              const SizedBox(height: KnSpace.sm),
              Text(
                l.restoreBackupRenamed(w.originalName, w.name),
                style: text.bodySmall,
              ),
            ],
        ],
      ],
    );
  }
}
