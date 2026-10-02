import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';

/// A labelled text input: the label above, the field, then a line below
/// holding the helper or error text on the left and [trailing] actions on
/// the right. Actions sit outside the field so the value has room.
///
/// With a [validator] it takes part in the enclosing [Form]; the validator
/// message is shown like [error].
class KnField extends StatelessWidget {
  const KnField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.error,
    this.helper,
    this.mono = false,
    this.suffix,
    this.trailing = const [],
    this.obscure = false,
    this.multiline = false,
    this.autofocus = false,
    this.enabled = true,
    this.readOnly = false,
    this.onSubmitted,
    this.onChanged,
    this.validator,
    this.focusNode,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.autofillHints,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;

  /// Replaces [helper] and turns the border to `error`.
  final String? error;
  final String? helper;

  /// Sets the value in IBM Plex Mono, for amounts, addresses and keys.
  final bool mono;

  /// A short unit shown at the end of the field, such as "XMR".
  final String? suffix;

  /// Up to three [KnIconButton]s, right-aligned below the field.
  final List<Widget> trailing;
  final bool obscure;

  /// Wraps and grows with the value instead of scrolling one line.
  final bool multiline;
  final bool autofocus;
  final bool enabled;
  final bool readOnly;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FormFieldValidator<String>? validator;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) {
    final validator = this.validator;
    if (validator == null) return _build(context, error);
    return FormField<String>(
      validator: (_) => validator(controller?.text ?? ''),
      builder: (state) => _build(context, state.errorText ?? error),
    );
  }

  Widget _build(BuildContext context, String? error) {
    final c = context.kn;
    final text = Theme.of(context).textTheme;
    final hasError = error != null;
    final note = error ?? helper;

    OutlineInputBorder? outline(double width) => hasError
        ? OutlineInputBorder(
            borderRadius: BorderRadius.circular(KnRadius.sm),
            borderSide: BorderSide(color: c.error, width: width),
          )
        : null;

    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      enabled: enabled,
      readOnly: readOnly,
      obscureText: obscure,
      enableSuggestions: !obscure,
      autocorrect: !obscure && !mono,
      keyboardType:
          keyboardType ?? (multiline ? TextInputType.multiline : null),
      textInputAction: textInputAction,
      inputFormatters: inputFormatters,
      autofillHints: autofillHints,
      minLines: multiline ? 2 : 1,
      maxLines: multiline && !obscure ? null : 1,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: mono
          ? monoStyle(context, color: enabled ? c.text : c.textSecondary)
          : text.bodyLarge!.copyWith(color: enabled ? c.text : c.textSecondary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: mono ? monoStyle(context, color: c.textSecondary) : null,
        suffixText: suffix,
        suffixStyle: mono ? monoStyle(context, color: c.textSecondary) : null,
        enabledBorder: outline(1),
        focusedBorder: outline(2),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Merged so screen readers announce the label with the field.
        MergeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label != null) ...[
                Text(label!, style: text.labelMedium),
                const SizedBox(height: 6),
              ],
              field,
            ],
          ),
        ),
        if (note != null || trailing.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: note == null
                      ? const SizedBox.shrink()
                      : Text(
                          note,
                          style: text.bodySmall!.copyWith(
                            color: hasError ? c.error : null,
                          ),
                        ),
                ),
                ...trailing,
              ],
            ),
          ),
      ],
    );
  }
}
