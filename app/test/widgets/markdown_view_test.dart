import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/widgets/markdown_view.dart';

void main() {
  test('parses headings, paragraphs and wrapped bullets', () {
    final blocks = parseMarkdown('''
# Title

First line
second line.

## Section

- one
  continued
- two
After list.
''');

    expect(blocks, hasLength(5));
    expect((blocks[0] as MdHeading).level, 1);
    expect((blocks[1] as MdParagraph).text, 'First line second line.');
    expect((blocks[2] as MdHeading).text, 'Section');
    expect((blocks[3] as MdBullets).items, ['one continued', 'two']);
    expect((blocks[4] as MdParagraph).text, 'After list.');
  });

  test('renders bold and code spans', () {
    const base = TextStyle();
    const mono = TextStyle(fontFamily: 'mono');
    final spans = parseInline('a **b** and `c`.', base, mono).cast<TextSpan>();

    expect(spans.map((s) => s.text), ['a ', 'b', ' and ', 'c', '.']);
    expect(spans[1].style!.fontWeight, FontWeight.w500);
    expect(spans[3].style, mono);
  });
}
