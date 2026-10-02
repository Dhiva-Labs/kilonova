import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _channel = MethodChannel('kilonova/secure_window');

/// Keeps the window out of screenshots, screen recording and screen sharing
/// while [child] is shown. Used on screens that show a seed.
///
/// Android sets `FLAG_SECURE`; Windows 10 2004 and later exclude the window
/// from capture. Linux has no equivalent a window can request.
class SecureWindow extends StatefulWidget {
  const SecureWindow({super.key, required this.child});

  final Widget child;

  @override
  State<SecureWindow> createState() => _SecureWindowState();
}

class _SecureWindowState extends State<SecureWindow> {
  static int _depth = 0;

  @override
  void initState() {
    super.initState();
    if (_depth++ == 0) _set(true);
  }

  @override
  void dispose() {
    if (--_depth == 0) _set(false);
    super.dispose();
  }

  static void _set(bool secure) {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    _channel.invokeMethod<void>('setSecure', secure).ignore();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
