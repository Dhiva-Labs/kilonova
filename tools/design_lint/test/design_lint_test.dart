import 'package:design_lint/design_lint.dart';
import 'package:test/test.dart';

List<String> checks(
  String path,
  String text, [
  List<String> words = const [],
]) => lintFile(path, text, words).map((v) => v.check).toList();

void main() {
  group('gradient and blur', () {
    test('flags Flutter gradients and blur in app code', () {
      expect(checks('app/lib/a.dart', 'LinearGradient(colors: c)'), [
        'gradient',
      ]);
      expect(checks('app/lib/a.dart', 'BackdropFilter(filter: f)'), ['blur']);
    });
    test('flags CSS gradients and backdrop blur on the site', () {
      expect(checks('site/a.css', 'background: linear-gradient(red, blue);'), [
        'gradient',
      ]);
      expect(checks('site/a.css', 'backdrop-filter: blur(8px);'), ['blur']);
    });
  });

  group('color', () {
    test('rejects literals outside the theme', () {
      expect(checks('app/lib/a.dart', 'Color(0xFF000000)'), ['color']);
      expect(checks('app/lib/a.dart', 'Colors.purple'), ['color']);
    });
    test('allows the theme and Colors.transparent', () {
      expect(checks('app/lib/theme/tokens.dart', 'Color(0xFF000000)'), isEmpty);
      expect(checks('app/lib/a.dart', 'Colors.transparent'), isEmpty);
    });
  });

  test('font: rejects Inter but not words that contain it', () {
    expect(checks('app/pubspec.yaml', "  - family: Inter"), ['font']);
    expect(checks('app/lib/a.dart', 'InteractiveViewer, Interface'), isEmpty);
  });

  test('deps: rejects banned packages', () {
    const pubspec =
        'dependencies:\n  lucide_icons_flutter: ^1.0.0\n  google_fonts: ^6.0.0\n';
    expect(checks('app/pubspec.yaml', pubspec), ['deps', 'deps']);
  });

  group('dash', () {
    test('rejects em dashes in copy and docs', () {
      expect(checks('README.md', 'Fast — private'), ['dash']);
      expect(checks('app/lib/l10n/app_en.arb', '"a": "x — y"'), ['dash']);
      expect(checks('docs/DESIGN.md', 'a — b'), ['dash']);
    });
    test('ignores code spans and fences in Markdown', () {
      expect(checks('README.md', 'Use `—` never.'), isEmpty);
      expect(checks('README.md', '```\n—\n```'), isEmpty);
    });
  });

  test('emoji: rejects emoji in UI strings and headings only', () {
    expect(checks('app/lib/l10n/app_en.arb', '"a": "Send \u{1F680}"'), [
      'emoji',
    ]);
    expect(checks('README.md', '## Install \u{1F680}'), ['emoji']);
    expect(checks('README.md', 'Body text \u{1F680}'), isEmpty);
  });

  test('buzzword: matches whole words, any case', () {
    expect(checks('README.md', 'A Seamless wallet', ['seamless']), [
      'buzzword',
    ]);
    expect(checks('README.md', 'seamlessness', ['seamless']), isEmpty);
    expect(checks('docs/adr/0001.md', 'seamless', ['seamless']), isEmpty);
  });

  test('allowlist and word list parsing skip comments', () {
    expect(parseWordList('# c\nseamless\n\n'), ['seamless']);
    expect(parseAllowlist('# c\ngradient app/lib/a.dart  # reason\n'), {
      'gradient app/lib/a.dart',
    });
  });
}
