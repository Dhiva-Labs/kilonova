import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/theme.dart';
import 'kn_button.dart';
import 'kn_card.dart';
import 'kn_sheet.dart';

/// How long a sensitive value is left on the clipboard before it is
/// cleared, if it is still there.
const copySensitiveClearAfter = Duration(seconds: 60);

/// A labelled value with a copy button: an [Eyebrow] label, the value as
/// selectable text, and a copy [KnIconButton] at the right.
///
/// [sensitive] values (secret keys, the seed) ask for confirmation first,
/// since anyone reading the clipboard could take the funds they protect,
/// and are wiped from the clipboard after [copySensitiveClearAfter] if
/// they are still there.
class CopyValue extends StatefulWidget {
  const CopyValue({
    super.key,
    required this.label,
    required this.value,
    this.mono = true,
    this.sensitive = false,
    this.display,
  });

  final String label;
  final String value;

  /// Sets the value in IBM Plex Mono, for addresses and keys.
  final bool mono;

  /// Asks for confirmation before copying, and clears the clipboard after
  /// [copySensitiveClearAfter].
  final bool sensitive;

  /// Shown instead of [value] (for example, a shortened address). The
  /// copy button still copies the full [value].
  final String? display;

  @override
  State<CopyValue> createState() => _CopyValueState();
}

class _CopyValueState extends State<CopyValue> {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Eyebrow(widget.label),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                widget.display ?? widget.value,
                style: widget.mono
                    ? monoStyle(context, size: 13)
                    : Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            KnIconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: l.copyAction,
              onPressed: () => copyValue(
                context,
                label: widget.label,
                value: widget.value,
                sensitive: widget.sensitive,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Copies [value] to the clipboard, confirming first and clearing it
/// later when [sensitive] is set. Shared by [CopyValue] and standalone
/// "Copy seed" style buttons that use the same sensitive flow without a
/// visible value row.
Future<void> copyValue(
  BuildContext context, {
  required String label,
  required String value,
  bool sensitive = false,
}) async {
  final l = AppLocalizations.of(context);
  if (sensitive) {
    final confirmed = await showKnDialog<bool>(
      context,
      Text(l.copySensitiveWarning),
      actions: [
        Builder(
          builder: (innerContext) => KnButton.text(
            l.cancelAction,
            onPressed: () => Navigator.of(innerContext).pop(false),
          ),
        ),
        Builder(
          builder: (innerContext) => KnButton.primary(
            l.copyAction,
            onPressed: () => Navigator.of(innerContext).pop(true),
          ),
        ),
      ],
    );
    if (confirmed != true || !context.mounted) return;
  }
  await Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) return;
  final notice = sensitive ? l.copiedClearsNotice : l.copiedGeneric(label);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(notice)));
  if (sensitive) _clearClipboardLater(value);
}

/// Clears the clipboard after [copySensitiveClearAfter], but only if it
/// still holds [value]; the user may have copied something else by
/// then. Runs even if the widget that started it is later disposed.
void _clearClipboardLater(String value) {
  Future<void>.delayed(copySensitiveClearAfter, () async {
    final current = await Clipboard.getData(Clipboard.kTextPlain);
    if (current?.text == value) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  });
}

/// A paste [KnIconButton] for a [KnField]'s `trailing` row: reads the
/// clipboard's text and fills [controller] with it, trimmed. Does nothing
/// if the clipboard holds no text.
class PasteButton extends StatelessWidget {
  const PasteButton({super.key, required this.controller, this.onPasted});

  final TextEditingController controller;

  /// Called after the field is filled, for callers that also need to
  /// react (clear an error, re-run validation).
  final VoidCallback? onPasted;

  Future<void> _paste(BuildContext context) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null) return;
    controller.text = text.trim();
    onPasted?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return KnIconButton(
      icon: const Icon(Icons.content_paste_outlined),
      tooltip: l.pasteAction,
      onPressed: () => _paste(context),
    );
  }
}
