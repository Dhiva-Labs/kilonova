import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';

/// An error message with its icon. Errors are never shown by color alone.
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final color = context.kn.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 20, color: color),
        const SizedBox(width: KnSpace.sm),
        Expanded(
          child: Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium!.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
