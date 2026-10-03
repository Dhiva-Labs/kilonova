import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _extension = 'knbackup';
const _typeGroup = XTypeGroup(
  label: 'Kilonova backup',
  extensions: [_extension],
);

/// Where backup files are saved and read from: the system's save and open
/// dialogs. Android saves through its document picker, so the app needs no
/// storage permission. A fake in tests.
class BackupFiles {
  const BackupFiles();

  static const _android = MethodChannel('kilonova/files');

  /// Asks where to save a backup named [suggestedName], then calls [write]
  /// with a local path to write it to. Returns the saved file's name, or
  /// null if the user cancelled.
  Future<String?> save(
    String suggestedName,
    Future<void> Function(String path) write,
  ) async {
    if (Platform.isAndroid) {
      // Written to the app's cache first, then copied where the user picks.
      final dir = await getTemporaryDirectory();
      final tmp = File('${dir.path}/$suggestedName');
      try {
        await write(tmp.path);
        return await _android.invokeMethod<String>('saveDocument', {
          'path': tmp.path,
          'name': suggestedName,
        });
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
    }
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [_typeGroup],
    );
    if (location == null) return null;
    var path = location.path;
    if (!path.endsWith('.$_extension')) path = '$path.$_extension';
    await write(path);
    return path.split(Platform.pathSeparator).last;
  }

  /// Asks for a backup file. Returns a local path to read it from and the
  /// name to show, or null if the user cancelled.
  Future<({String path, String name})?> open() async {
    // Android's picker filters by media type, which knows no .knbackup.
    final file = await openFile(
      acceptedTypeGroups: Platform.isAndroid ? const [] : const [_typeGroup],
    );
    if (file == null) return null;
    if (file.path.isNotEmpty && File(file.path).existsSync()) {
      return (path: file.path, name: file.name);
    }
    final dir = await getTemporaryDirectory();
    final copy = File('${dir.path}/restore.$_extension');
    await copy.writeAsBytes(await file.readAsBytes());
    return (path: copy.path, name: file.name);
  }
}
