/// Mechanical checks for the rules in docs/DESIGN.md.
///
/// Each check takes a repo-relative path and file contents and returns the
/// violations it finds. `bin/design_lint.dart` walks the repository and
/// applies the checks whose scope matches each file.
library;

class Violation {
  const Violation(this.check, this.path, this.line, this.message);

  final String check;
  final String path;
  final int line;
  final String message;

  @override
  String toString() => '$path:$line: [$check] $message';
}

/// Directories never scanned: build output, generated code, vendored code,
/// and this tool (which has to spell out what it bans).
const excludedPrefixes = [
  '.git/',
  'core/target/',
  'app/build/',
  'app/.dart_tool/',
  'app/lib/src/rust/',
  'app/lib/l10n/generated/',
  'app/rust_builder/cargokit/',
  'tools/design_lint/',
];

bool isExcluded(String path) =>
    excludedPrefixes.any(path.startsWith) ||
    path.contains('/.dart_tool/') ||
    path.contains('/node_modules/') ||
    path.contains('/build/');

const _siteExtensions = [
  '.css',
  '.scss',
  '.html',
  '.js',
  '.jsx',
  '.ts',
  '.tsx',
  '.vue',
  '.svelte',
];

bool _isUiCode(String path) =>
    (path.startsWith('app/lib/') && path.endsWith('.dart')) ||
    (path.startsWith('site/') && _siteExtensions.any(path.endsWith));

bool _isArb(String path) =>
    path.startsWith('app/lib/l10n/') && path.endsWith('.arb');

bool _isSiteCopy(String path) =>
    path.startsWith('site/') &&
    (_siteExtensions.any(path.endsWith) || path.endsWith('.md'));

/// User-facing prose: where em dashes and buzzwords are not allowed.
bool _isCopy(String path) =>
    _isArb(path) ||
    _isSiteCopy(path) ||
    const ['README.md', 'PRIVACY.md'].contains(path);

/// Project docs: where em dashes are also not allowed.
bool _isProjectDoc(String path) =>
    path.endsWith('.md') &&
    (!path.contains('/') ||
        path.startsWith('docs/') ||
        path.startsWith('.github/'));

/// Blanks out fenced code blocks and inline code spans in Markdown, keeping
/// line numbers intact, so docs can name what they ban.
String stripMarkdownCode(String text) {
  final out = StringBuffer();
  var inFence = false;
  for (final line in text.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      out.writeln();
      continue;
    }
    out.writeln(inFence ? '' : line.replaceAll(RegExp(r'`[^`]*`'), ''));
  }
  return out.toString();
}

Iterable<Violation> _matchLines(
  String check,
  String path,
  String text,
  RegExp pattern,
  String Function(Match) message,
) sync* {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    for (final m in pattern.allMatches(lines[i])) {
      yield Violation(check, path, i + 1, message(m));
    }
  }
}

final _gradient = RegExp(
  r'\b(Linear|Radial|Sweep)Gradient\b|\b(repeating-)?(linear|radial|conic)-gradient\(',
);
final _blur = RegExp(
  r'\bBackdropFilter\b|ImageFilter\.blur\b|backdrop-filter|filter:\s*blur\(',
);
final _colorLiteral = RegExp(
  r'\bColor\(0x|\bColor\.from(ARGB|RGBO)\b|\bColors\.(?!transparent\b)\w+',
);
final _interFont = RegExp(
  r'''\bInter\b(?=['"_\-\s,;)]|$)|Inter-|inter\.(ttf|woff2?|otf)''',
);
final _emDash = RegExp(r'\u2014', unicode: true);
final _emoji = RegExp(r'\p{Extended_Pictographic}', unicode: true);
/// Material form widgets that feature code must not build directly; the
/// styled versions live in lib/widgets/ (see docs/design/REDESIGN.md).
final _rawFormWidget = RegExp(
  r'\b(TextField|TextFormField|ListTile|RadioListTile|SwitchListTile|'
  r'SegmentedButton|FilledButton|OutlinedButton|TextButton|Card)\s*(\(|<|\.)',
);

const _bannedPackages = [
  'lucide',
  'google_fonts',
  '@fontsource/inter',
  'aos',
  'scrollreveal',
  'sal.js',
  'wowjs',
  'wow.js',
];

/// Runs every check whose scope covers [path].
List<Violation> lintFile(String path, String text, List<String> buzzwords) {
  final found = <Violation>[];
  final prose = path.endsWith('.md') ? stripMarkdownCode(text) : text;

  if (_isUiCode(path)) {
    found
      ..addAll(
        _matchLines(
          'gradient',
          path,
          text,
          _gradient,
          (m) => 'gradient `${m[0]}`: use a solid surface',
        ),
      )
      ..addAll(
        _matchLines(
          'blur',
          path,
          text,
          _blur,
          (m) => 'blur `${m[0]}`: surfaces are opaque',
        ),
      );
  }

  if (path.startsWith('app/lib/') &&
      path.endsWith('.dart') &&
      !path.startsWith('app/lib/theme/')) {
    found.addAll(
      _matchLines(
        'color',
        path,
        text,
        _colorLiteral,
        (m) => 'color literal `${m[0]}`: use a token from lib/theme/',
      ),
    );
  }

  if (path.startsWith('app/lib/features/') && path.endsWith('.dart')) {
    found.addAll(
      _matchLines(
        'widgets',
        path,
        text,
        _rawFormWidget,
        (m) => 'raw `${m[0]}`: use the Kn widget from lib/widgets/',
      ),
    );
  }

  if (!path.endsWith('.md') && !path.endsWith('.txt')) {
    found.addAll(
      _matchLines(
        'font',
        path,
        text,
        _interFont,
        (m) => 'Inter font reference: use IBM Plex Sans',
      ),
    );
  }

  if (path == 'app/pubspec.yaml' ||
      path.startsWith('site/') && path.endsWith('package.json')) {
    final dep = RegExp(r'''^\s+["']?([@a-z0-9_./\-]+)["']?\s*:''');
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final name = dep.firstMatch(lines[i])?.group(1);
      if (name == null) continue;
      final banned = _bannedPackages.where(
        (b) => b == 'lucide' ? name.contains('lucide') : name == b,
      );
      if (banned.isNotEmpty) {
        found.add(Violation('deps', path, i + 1, 'banned package `$name`'));
      }
    }
  }

  if (_isCopy(path) || _isProjectDoc(path)) {
    found.addAll(
      _matchLines(
        'dash',
        path,
        prose,
        _emDash,
        (_) => 'em dash: use a comma, colon or full stop',
      ),
    );
  }

  if (_isArb(path)) {
    found.addAll(
      _matchLines(
        'emoji',
        path,
        text,
        _emoji,
        (m) => 'emoji `${m[0]}` in a UI string',
      ),
    );
  }
  if (path.endsWith('.md')) {
    final headings = prose
        .split('\n')
        .map((l) => l.startsWith('#') ? l : '')
        .join('\n');
    found.addAll(
      _matchLines(
        'emoji',
        path,
        headings,
        _emoji,
        (m) => 'emoji `${m[0]}` in a heading',
      ),
    );
  }

  if (_isCopy(path) && buzzwords.isNotEmpty) {
    final pattern = RegExp(
      '\\b(${buzzwords.map(RegExp.escape).join('|')})\\b',
      caseSensitive: false,
    );
    found.addAll(
      _matchLines(
        'buzzword',
        path,
        prose,
        pattern,
        (m) => 'buzzword "${m[0]}": say what it does',
      ),
    );
  }

  return found;
}

/// Parses `buzzwords.txt`: one entry per line, `#` starts a comment.
List<String> parseWordList(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#')) line.trim(),
];

/// Parses `allowlist.txt` into `check path` keys.
Set<String> parseAllowlist(String text) => {
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#'))
      line.split('#').first.trim().split(RegExp(r'\s+')).take(2).join(' '),
};
