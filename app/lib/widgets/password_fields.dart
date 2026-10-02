import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/tokens.dart';
import 'kn_field.dart';

const minPasswordLength = 8;

/// A new password and its confirmation, validated by the enclosing [Form].
class NewPasswordFields extends StatelessWidget {
  const NewPasswordFields({
    super.key,
    required this.password,
    required this.confirm,
    this.label,
  });

  final TextEditingController password;
  final TextEditingController confirm;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KnField(
          controller: password,
          label: label ?? l.passwordLabel,
          obscure: true,
          validator: (v) =>
              (v ?? '').length < minPasswordLength ? l.passwordTooShort : null,
        ),
        const SizedBox(height: KnSpace.md),
        KnField(
          controller: confirm,
          label: l.passwordConfirmLabel,
          obscure: true,
          validator: (v) => v != password.text ? l.passwordMismatch : null,
        ),
      ],
    );
  }
}

/// A single password entry, for unlocking or confirming.
class PasswordField extends StatelessWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.errorText,
    this.onSubmitted,
    this.label,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String? errorText;
  final ValueChanged<String>? onSubmitted;
  final String? label;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return KnField(
      controller: controller,
      label: label ?? AppLocalizations.of(context).passwordLabel,
      error: errorText,
      obscure: true,
      autofocus: autofocus,
      onSubmitted: onSubmitted,
    );
  }
}
