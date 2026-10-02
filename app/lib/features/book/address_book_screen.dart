import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/book.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pick ? l.bookPickTitle : l.bookTitle),
        actions: [
          TextButton(onPressed: _edit, child: Text(l.bookAddAction)),
          const SizedBox(width: KnSpace.sm),
        ],
      ),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _contacts.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(KnSpace.lg),
                  child: Text(l.bookEmpty, style: text.bodyMedium),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: KnSpace.sm),
                  itemCount: _contacts.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, i) {
                    final contact = _contacts[i];
                    return ListTile(
                      title: Text(contact.name),
                      subtitle: Text(
                        contact.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          context,
                          size: 12,
                          color: context.kn.textSecondary,
                        ),
                      ),
                      onTap: widget.pick
                          ? () => Navigator.of(context).pop(contact.address)
                          : () => _edit(contact),
                      trailing: widget.pick
                          ? null
                          : PopupMenuButton<String>(
                              tooltip: l.bookContactMenu,
                              onSelected: (action) {
                                switch (action) {
                                  case 'copy':
                                    Clipboard.setData(
                                      ClipboardData(text: contact.address),
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
                    );
                  },
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
  return await showDialog<bool>(
        context: context,
        builder: (_) =>
            _ContactDialog(wallet: wallet, name: name, address: address),
      ) ??
      false;
}

class _ContactDialog extends StatefulWidget {
  const _ContactDialog({required this.wallet, this.name, this.address});

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
    return AlertDialog(
      title: Text(widget.name == null ? l.bookAddTitle : l.bookEditTitle),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.name == null,
              decoration: InputDecoration(labelText: l.bookNameField),
            ),
            const SizedBox(height: KnSpace.sm),
            TextField(
              controller: _address,
              minLines: 1,
              maxLines: 3,
              style: monoStyle(context, size: 13),
              decoration: InputDecoration(
                labelText: l.sendAddressField,
                errorText: _error,
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.cancelAction),
        ),
        TextButton(onPressed: _save, child: Text(l.bookSaveAction)),
      ],
    );
  }
}
