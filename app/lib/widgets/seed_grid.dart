import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'kn_card.dart';

/// Seed words, numbered, in reading order down each column.
class SeedGrid extends StatelessWidget {
  const SeedGrid({super.key, required this.words});

  final List<String> words;

  @override
  Widget build(BuildContext context) {
    final c = context.kn;
    final body = Theme.of(context).textTheme.bodyLarge!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 560 ? 4 : 2;
        final rows = (words.length / columns).ceil();
        return KnCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var col = 0; col < columns; col++)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var row = 0; row < rows; row++)
                        if (col * rows + row < words.length)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: KnSpace.xs,
                            ),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${col * rows + row + 1}'.padLeft(2),
                                    style: monoStyle(
                                      context,
                                      color: c.textSecondary,
                                    ),
                                  ),
                                  const TextSpan(text: '  '),
                                  TextSpan(
                                    text: words[col * rows + row],
                                    style: body,
                                  ),
                                ],
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
