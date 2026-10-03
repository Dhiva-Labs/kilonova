import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../features/wallets/wallet_registry.dart';
import '../l10n/generated/app_localizations.dart';

/// What closing the window does on a desktop.
enum CloseAction {
  /// Wallets lock and the app ends.
  quit,

  /// The window hides; an icon in the system tray brings it back.
  hideToTray,

  /// No tray to hide in: the window is minimized instead, never hidden
  /// with no way back.
  minimize,
}

/// Closing the window quits, unless the owner chose to keep syncing.
CloseAction closeAction({required bool keepSyncing, required bool hasTray}) {
  if (!keepSyncing) return CloseAction.quit;
  return hasTray ? CloseAction.hideToTray : CloseAction.minimize;
}

/// Whether the desktop shows tray icons. Windows always does; on Linux,
/// only a running StatusNotifier host does (GNOME needs an extension).
Future<bool> trayAvailable() async {
  if (Platform.isWindows) return true;
  if (!Platform.isLinux) return false;
  final client = DBusClient.session();
  try {
    const name = 'org.kde.StatusNotifierWatcher';
    if (!await client.nameHasOwner(name)) return false;
    final watcher = DBusRemoteObject(
      client,
      name: name,
      path: DBusObjectPath('/StatusNotifierWatcher'),
    );
    final value = await watcher.getProperty(
      name,
      'IsStatusNotifierHostRegistered',
      signature: DBusSignature('b'),
    );
    return value.asBoolean();
  } on Object {
    return false;
  } finally {
    await client.close();
  }
}

/// The desktop window and its tray icon: closing the window hides it to
/// the tray while the owner keeps wallets syncing (Settings, Background),
/// and quits otherwise.
class DesktopShell with WindowListener, TrayListener {
  DesktopShell(this.registry);

  final WalletRegistry registry;

  /// Whether a tray icon can be shown; checked at start.
  bool hasTray = false;
  bool _inTray = false;

  static bool get supported => Platform.isLinux || Platform.isWindows;

  Future<void> start() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    hasTray = await trayAvailable();
    registry.hasTray = hasTray;
    registry.keepsSyncingHidden = true;
  }

  @override
  Future<void> onWindowClose() async {
    switch (registry.windowClosing(hasTray: hasTray)) {
      case CloseAction.quit:
        await _quit();
      case CloseAction.hideToTray:
        await _showTrayIcon();
        await windowManager.hide();
      case CloseAction.minimize:
        final l = lookupAppLocalizations(const Locale('en'));
        unawaited(
          registry.notifier.payment(
            id: 1,
            title: l.trayMissingTitle,
            body: l.trayMissingBody,
            publicTitle: l.trayMissingTitle,
          ),
        );
        await windowManager.minimize();
    }
  }

  @override
  void onWindowRestore() => registry.windowOpened();

  @override
  void onWindowFocus() => registry.windowOpened();

  Future<void> _showTrayIcon() async {
    if (_inTray) return;
    final l = lookupAppLocalizations(const Locale('en'));
    await trayManager.setIcon(_iconPath());
    if (!Platform.isLinux) await trayManager.setToolTip(l.appTitle);
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'open', label: l.trayOpen),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: l.trayQuit),
        ],
      ),
    );
    trayManager.addListener(this);
    _inTray = true;
  }

  Future<void> _hideTrayIcon() async {
    if (!_inTray) return;
    trayManager.removeListener(this);
    await trayManager.destroy();
    _inTray = false;
  }

  /// The icon file, relative to the bundled assets; inside the snap, by
  /// its absolute path, which the tray host outside can read.
  static String _iconPath() {
    if (Platform.isWindows) return 'assets/icon/kilonova.ico';
    final snap = Platform.environment['SNAP'];
    if (snap != null) {
      return '$snap/usr/share/icons/hicolor/256x256/apps/com.dhivalabs.kilonova.png';
    }
    return 'assets/icon/kilonova-256.png';
  }

  Future<void> _open() async {
    await windowManager.show();
    await windowManager.focus();
    registry.windowOpened();
    await _hideTrayIcon();
  }

  Future<void> _quit() async {
    registry.lockAll();
    await _hideTrayIcon();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onTrayIconMouseDown() => unawaited(_open());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        unawaited(_open());
      case 'quit':
        unawaited(_quit());
    }
  }
}
