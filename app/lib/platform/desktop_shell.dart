import 'dart:async';
import 'dart:io';

import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:window_manager/window_manager.dart';

import '../features/wallets/wallet_registry.dart';
import '../l10n/generated/app_localizations.dart';
import 'tray.dart';

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

/// The desktop window and its tray icon: closing the window hides it to
/// the tray while the owner keeps wallets syncing (Settings, Background),
/// and quits otherwise.
class DesktopShell with WindowListener {
  DesktopShell(this.registry, {Tray? tray})
    : tray =
          tray ??
          Tray.forPlatform(
            title: _l.appTitle,
            openLabel: _l.trayOpen,
            quitLabel: _l.trayQuit,
          );

  static final _l = lookupAppLocalizations(const Locale('en'));

  final WalletRegistry registry;

  /// The tray icon; `null` where the platform has none.
  final Tray? tray;

  /// Whether a tray icon can be shown; checked at start.
  bool hasTray = false;
  bool _inTray = false;

  static bool get supported => Platform.isLinux || Platform.isWindows;

  Future<void> start() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    final tray = this.tray;
    hasTray = tray != null && await tray.available();
    if (tray != null) {
      tray.onOpen = () => unawaited(_open());
      tray.onQuit = () => unawaited(_quit());
      if (tray is LinuxTray) tray.pixmaps = await _pixmaps();
    }
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
    await tray?.show();
    _inTray = true;
  }

  Future<void> _hideTrayIcon() async {
    if (!_inTray) return;
    _inTray = false;
    await tray?.hide();
  }

  /// The app icon at the sizes tray hosts ask for most.
  static Future<List<TrayPixmap>> _pixmaps() async {
    final png = await rootBundle.load('assets/icon/kilonova-256.png');
    final out = <TrayPixmap>[];
    for (final size in const [22, 32, 64]) {
      final codec = await ui.instantiateImageCodec(
        png.buffer.asUint8List(),
        targetWidth: size,
        targetHeight: size,
      );
      final image = (await codec.getNextFrame()).image;
      final rgba = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (rgba != null) {
        out.add(TrayPixmap.fromRgba(size, size, rgba.buffer.asUint8List()));
      }
      image.dispose();
      codec.dispose();
    }
    return out;
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
}
