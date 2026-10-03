import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/settings/backup_files.dart';
import 'package:kilonova/features/settings/price_feed.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
import 'package:kilonova/src/rust/api/backup.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../../helpers/rust.dart';

/// Saves into and opens from a temporary directory instead of showing the
/// system's file dialogs.
class FakeBackupFiles extends BackupFiles {
  FakeBackupFiles(this.dir);

  final Directory dir;

  /// The path `open` returns; null means the user cancelled.
  String? toOpen;

  /// Every path a backup was saved to.
  final saved = <String>[];

  @override
  Future<String?> save(
    String suggestedName,
    Future<void> Function(String path) write,
  ) async {
    final path = '${dir.path}/$suggestedName';
    await write(path);
    saved.add(path);
    return suggestedName;
  }

  @override
  Future<({String path, String name})?> open() async {
    final path = toOpen;
    if (path == null) return null;
    return (path: path, name: path.split('/').last);
  }
}

const _passphrase = 'a long backup passphrase';

Future<String> _createWallet(String name) async {
  final seed = await generateSeed(format: SeedFormat.polyseed);
  final wallet = await createWalletFromSeed(
    name: name,
    network: Network.mainnet,
    mode: SyncMode.full,
    words: seed.words.join(' '),
    password: 'wallet pw',
    restoreHeight: BigInt.zero,
    createdHere: true,
  );
  final id = wallet.summary().id;
  wallet.lock();
  return id;
}

void main() {
  setUpAll(initRustForTests);

  late Directory dir;
  late FakeBackupFiles files;
  late WalletRegistry registry;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kilonova-backup-test-');
    files = FakeBackupFiles(dir);
    registry = WalletRegistry(
      backupFiles: files,
      price: PriceFeed(fetch: () async => null),
    );
  });

  testWidgets('back up every wallet to a file', (tester) async {
    useDesktopWindow(tester);
    await tester.runAsync(() async {
      await _createWallet('Spending');
      await _createWallet('Savings');
    });
    await tester.pumpWidget(await testAppWithRegistry(tester, registry));
    await openSettings(tester);
    await tester.tap(find.text('Backup'));
    await tester.pumpAndSettle();

    // Every wallet is chosen to start with.
    expect(find.text('Spending'), findsOneWidget);
    expect(find.text('Savings'), findsOneWidget);
    final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox));
    expect(boxes.length, registry.all.length);
    expect(boxes.every((b) => b.value == true), isTrue);

    await tester.enterText(fieldWithLabel('Backup passphrase'), 'too short');
    await tester.enterText(fieldWithLabel('Repeat the passphrase'), 'x');
    await tester.tap(find.text('Save backup'));
    await tester.pump();
    expect(find.text('Use at least 12 characters.'), findsOneWidget);
    expect(find.text('The passphrases do not match.'), findsOneWidget);
    expect(files.saved, isEmpty);

    await tester.enterText(fieldWithLabel('Backup passphrase'), _passphrase);
    await tester.enterText(
      fieldWithLabel('Repeat the passphrase'),
      _passphrase,
    );
    await tester.tap(find.text('Save backup'));
    await pumpUntilFound(tester, find.textContaining('Saved kilonova-backup-'));
    expect(find.textContaining('KB.'), findsOneWidget);
    expect(files.saved, hasLength(1));
    expect(File(files.saved.single).existsSync(), isTrue);

    // The file holds both wallets and opens only with the passphrase.
    final summary = await tester.runAsync(
      () =>
          readBackupSummary(path: files.saved.single, passphrase: _passphrase),
    );
    expect(summary!.count, registry.all.length);
    expect(
      summary.wallets.map((w) => w.name),
      containsAll(['Spending', 'Savings']),
    );
  });

  testWidgets('restore from a backup, next to the wallets already here', (
    tester,
  ) async {
    useDesktopWindow(tester);
    final path = '${dir.path}/one.knbackup';
    await tester.runAsync(() async {
      final id = await _createWallet('Travel');
      await exportBackup(walletIds: [id], passphrase: _passphrase, path: path);
    });
    await tester.pumpWidget(await testAppWithRegistry(tester, registry));
    await openSettings(tester);
    await tester.tap(find.text('Restore from backup'));
    await tester.pumpAndSettle();
    expect(find.text('No file chosen yet.'), findsOneWidget);

    files.toOpen = path;
    await tester.tap(find.text('Choose file'));
    await pumpUntilFound(tester, find.text('File: one.knbackup'));

    await tester.enterText(
      fieldWithLabel('Backup passphrase'),
      'not the passphrase',
    );
    await tester.tap(find.text('Open backup'));
    await pumpUntilFound(
      tester,
      find.text('Wrong passphrase, or the backup is damaged.'),
    );

    await tester.enterText(fieldWithLabel('Backup passphrase'), _passphrase);
    await tester.tap(find.text('Open backup'));
    await pumpUntilFound(tester, find.text('This backup holds 1 wallet.'));
    expect(find.text('Travel'), findsOneWidget);

    await tester.tap(find.text('Restore these wallets'));
    await pumpUntilFound(
      tester,
      find.text('Restored 1 wallet. Unlock it with its own password.'),
    );
    expect(
      find.text(
        'You already had Travel, so the restored copy is called '
        'Travel (restored).',
      ),
      findsOneWidget,
    );
    expect(registry.all.map((w) => w.name), contains('Travel (restored)'));

    // Back on the wallet list, the restored wallet is there.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Travel (restored)'), findsOneWidget);
  });
}
