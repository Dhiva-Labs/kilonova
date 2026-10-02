import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/book.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/kn_sheet.dart';
import '../../widgets/wallet_error_text.dart';

/// Saved recipients of one wallet. With [pick], tapping a contact returns
/// its address.
class AddressBookScreen extends StatefulWidget {
  const AddressBookScreen({super.key, required this.wallet, this.pick = false});

  final OpenWallet wallet;
  final bool pick;

  @override
  State<AddressBookScreen> createState() => _AddressBookScreenState();
}

class _AddressBookScreenState extends State<AddressBookScreen> {
  late List<ContactRow> _contacts = widget.wallet.contacts();

  Future<void> _edit([ContactRow? existing]) async {
    final saved = await showContactDialog(
      context,
      wallet: widget.wallet,
      name: existing?.name,
      address: existing?.address,
    );
    if (saved && mounted) {
      setState(() => _contacts = widget.wallet.contacts());
    }
  }

  Future<void> _delete(ContactRow contact) async {
    await widget.wallet.deleteContact(address: contact.address);
    if (mounted) setState(() => _contacts = widget.wallet.contacts());
  }

  /// Shortens a long address to its first and last 12 characters.
  static String _shorten(String address) => address.length <= 26
      ? address
      : '${address.substring(0, 12)}…${address.substring(address.length - 12)}';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final c = context.kn;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pick ? l.bookPickTitle : l.bookTitle),
        actions: [
          KnButton.text(l.bookAddAction, onPressed: () => _edit()),
          const SizedBox(width: KnSpace.sm),
        ],
      ),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(KnSpace.lg),
            child: _contacts.isEmpty
                ? Text(l.bookEmpty, style: text.bodyMedium)
                : KnCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: withDividers([
                        for (final contact in _contacts)
                          KnRow(
                            title: Text(contact.name),
                            subtitle: Text(
                              _shorten(contact.address),
                              style: monoStyle(
                                context,
                                size: 13,
                                color: c.textSecondary,
                              ),
                            ),
                            onTap: widget.pick
                                ? () =>
                                      Navigator.of(context).pop(contact.address)
                                : () => _edit(contact),
                            trailing: widget.pick
                                ? null
                                : PopupMenuButton<String>(
                                    tooltip: l.bookContactMenu,
                                    onSelected: (action) {
                                      switch (action) {
                                        case 'copy':
                                          Clipboard.setData(
                                            ClipboardData(
                                              text: contact.address,
                                            ),
                                          );
                                        case 'delete':
                                          _delete(contact);
                                      }
                                    },
                                    itemBuilder: (_) => [
                                      PopupMenuItem(
                                        value: 'copy',
                                        child: Text(l.copyAction),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text(l.bookDeleteAction),
                                      ),
                                    ],
                                  ),
                          ),
                      ]),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Adds or edits a contact. Returns true if one was saved.
Future<bool> showContactDialog(
  BuildContext context, {
  required OpenWallet wallet,
  String? name,
  String? address,
}) async {
  final l = AppLocalizations.of(context);
  final key = GlobalKey<_ContactDialogState>();
  return await showKnDialog<bool>(
        context,
        _ContactDialog(key: key, wallet: wallet, name: name, address: address),
        title: name == null ? l.bookAddTitle : l.bookEditTitle,
        actions: [
          Builder(
            builder: (innerContext) => KnButton.text(
              l.cancelAction,
              onPressed: () => Navigator.of(innerContext).pop(false),
            ),
          ),
          KnButton.primary(
            l.bookSaveAction,
            onPressed: () => key.currentState?._save(),
          ),
        ],
      ) ??
      false;
}

class _ContactDialog extends StatefulWidget {
  const _ContactDialog({
    super.key,
    required this.wallet,
    this.name,
    this.address,
  });

  final OpenWallet wallet;
  final String? name;
  final String? address;

  @override
  State<_ContactDialog> createState() => _ContactDialogState();
}

class _ContactDialogState extends State<_ContactDialog> {
  late final _name = TextEditingController(text: widget.name);
  late final _address = TextEditingController(text: widget.address);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      // Editing an address replaces the old entry.
      final old = widget.address;
      if (old != null && old != _address.text.trim()) {
        await widget.wallet.deleteContact(address: old);
      }
      await widget.wallet.saveContact(name: _name.text, address: _address.text);
      if (mounted) Navigator.of(context).pop(true);
    } on WalletError catch (e) {
      if (mounted) setState(() => _error = walletErrorMessage(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KnField(
          controller: _name,
          label: l.bookNameField,
          autofocus: widget.name == null,
        ),
        const SizedBox(height: KnSpace.md),
        KnField(
          controller: _address,
          label: l.sendAddressField,
          mono: true,
          multiline: true,
          error: _error,
          onSubmitted: (_) => _save(),
        ),
      ],
    );
  }
}
