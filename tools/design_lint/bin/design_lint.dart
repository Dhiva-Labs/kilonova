import 'dart:io';

import 'package:design_lint/design_lint.dart';

/// Usage: dart run tools/design_lint/bin/design_lint.dart [repo root]
void main(List<String> args) {
  final root = Directory(args.isEmpty ? '.' : args.first).absolute;
  final toolDir = '${root.path}/tools/design_lint';
  final buzzwords = parseWordList(
    File('$toolDir/buzzwords.txt').readAsStringSync(),
  );
  final allowed = parseAllowlist(
    File('$toolDir/allowlist.txt').readAsStringSync(),
  );

  final violations = <Violation>[];
  var scanned = 0;
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final path = entity.path
        .substring(root.path.length + 1)
        .replaceAll(r'\', '/');
    if (isExcluded(path)) continue;

    final String text;
    try {
      text = entity.readAsStringSync();
    } on FileSystemException {
      continue; // Binary file: fonts, images.
    } on FormatException {
      continue;
    }
    scanned++;
    violations.addAll(
      lintFile(
        path,
        text,
        buzzwords,
      ).where((v) => !allowed.contains('${v.check} ${v.path}')),
    );
  }

  violations.forEach(stdout.writeln);
  stdout.writeln(
    violations.isEmpty
        ? 'design lint: $scanned files clean'
        : 'design lint: ${violations.length} violation(s). See docs/DESIGN.md.',
  );
  exitCode = violations.isEmpty ? 0 : 1;
}
