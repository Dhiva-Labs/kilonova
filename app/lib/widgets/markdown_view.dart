import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';

/// A block of the small Markdown subset used by the bundled legal documents:
/// headings, paragraphs and bullet lists, with `**bold**` and `` `code` ``
/// inline. Anything else is treated as paragraph text.
///
/// Kept in-tree rather than pulling a Markdown package, so the privacy policy
/// screen adds no third-party code to a wallet.
sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdBullets extends MdBlock {
  const MdBullets(this.items);
  final List<String> items;
}

/// Splits [source] into blocks. Wrapped lines are joined with a space.
List<MdBlock> parseMarkdown(String source) {
  final blocks = <MdBlock>[];
  final paragraph = <String>[];
  final bullets = <String>[];

  void flush() {
    if (paragraph.isNotEmpty) {
      blocks.add(MdParagraph(paragraph.join(' ')));
      paragraph.clear();
    }
    if (bullets.isNotEmpty) {
      blocks.add(MdBullets(List.of(bullets)));
      bullets.clear();
    }
  }

  for (final raw in source.split('\n')) {
    final line = raw.trimRight();
    final heading = RegExp(r'^(#{1,3}) (.+)$').firstMatch(line);
    if (line.isEmpty) {
      flush();
    } else if (heading != null) {
      flush();
      blocks.add(MdHeading(heading.group(1)!.length, heading.group(2)!));
    } else if (line.startsWith('- ')) {
      if (paragraph.isNotEmpty) flush();
      bullets.add(line.substring(2).trim());
    } else if (bullets.isNotEmpty && raw.startsWith('  ')) {
      bullets[bullets.length - 1] = '${bullets.last} ${line.trim()}';
    } else {
      if (bullets.isNotEmpty) flush();
      paragraph.add(line.trim());
    }
  }
  flush();
  return blocks;
}

/// Renders `**bold**` and `` `code` `` spans inside [text].
List<InlineSpan> parseInline(String text, TextStyle base, TextStyle mono) {
  final spans = <InlineSpan>[];
  final pattern = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
  var start = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > start) {
      spans.add(TextSpan(text: text.substring(start, m.start)));
    }
    if (m.group(1) != null) {
      spans.add(
        TextSpan(
          text: m.group(1),
          style: base.copyWith(fontWeight: FontWeight.w500),
        ),
      );
    } else {
      spans.add(TextSpan(text: m.group(2), style: mono));
    }
    start = m.end;
  }
  if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
  return spans;
}

class MarkdownView extends StatelessWidget {
  const MarkdownView({super.key, required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final body = theme.bodyLarge!;
    final mono = monoStyle(context, size: 15);

    Widget rich(String text, TextStyle style) => Text.rich(
      TextSpan(style: style, children: parseInline(text, style, mono)),
    );

    final children = <Widget>[];
    for (final block in parseMarkdown(source)) {
      switch (block) {
        case MdHeading(:final level, :final text):
          final style = switch (level) {
            1 => theme.headlineSmall!,
            2 => theme.titleLarge!,
            _ => theme.titleMedium!,
          };
          children.add(
            Padding(
              padding: EdgeInsets.only(
                top: children.isEmpty ? 0 : KnSpace.lg,
                bottom: KnSpace.sm,
              ),
              child: Semantics(header: true, child: rich(text, style)),
            ),
          );
        case MdParagraph(:final text):
          children.add(
            Padding(
              padding: const EdgeInsets.only(bottom: KnSpace.md),
              child: rich(text, body),
            ),
          );
        case MdBullets(:final items):
          for (final item in items) {
            children.add(
              Padding(
                padding: const EdgeInsets.only(bottom: KnSpace.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: KnSpace.lg,
                      child: Text('•', style: body),
                    ),
                    Expanded(child: rich(item, body)),
                  ],
                ),
              ),
            );
          }
          children.add(const SizedBox(height: KnSpace.sm));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
