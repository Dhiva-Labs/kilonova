import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_linux/flutter_local_notifications_linux.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';

/// Payment notifications, only shown after the owner turns them on in
/// settings.
class Notifier {
  const Notifier();

  static const _android = MethodChannel('kilonova/background');
  static LinuxFlutterLocalNotificationsPlugin? _linux;
  static FlutterLocalNotificationsWindows? _windows;

  Future<void> _ensureDesktop() async {
    if (Platform.isLinux && _linux == null) {
      final plugin = LinuxFlutterLocalNotificationsPlugin();
      await plugin.initialize(
        settings: const LinuxInitializationSettings(defaultActionName: 'Open'),
      );
      _linux = plugin;
    } else if (Platform.isWindows && _windows == null) {
      final plugin = FlutterLocalNotificationsWindows();
      await plugin.initialize(
        settings: const WindowsInitializationSettings(
          appName: 'Kilonova',
          appUserModelId: 'DhivaLabs.Kilonova',
          guid: '6f7b2a1e-3c84-4d5a-9e0f-1b2c3d4e5f60',
        ),
      );
      _windows = plugin;
    }
  }

  /// Asks for permission to notify where the system requires it (Android
  /// 13 and later). Returns whether notifications can be shown.
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    return await _android.invokeMethod<bool>('requestNotifications') ?? false;
  }

  /// Shows a payment notification. [publicTitle] is what a locked phone
  /// shows instead, without the amount.
  Future<void> payment({
    required int id,
    required String title,
    required String body,
    required String publicTitle,
  }) async {
    if (Platform.isAndroid) {
      await _android.invokeMethod<void>('notify', {
        'id': id,
        'title': title,
        'body': body,
        'publicTitle': publicTitle,
      });
      return;
    }
    await _ensureDesktop();
    await _linux?.show(id: id, title: title, body: body);
    await _windows?.show(id: id, title: title, body: body);
  }
}
