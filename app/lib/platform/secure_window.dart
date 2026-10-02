import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _channel = MethodChannel('kilonova/secure_window');

/// Blocks screenshots and screen recording while [child] is shown, on
/// platforms that support it (Android today). Used on screens that show a
/// seed.
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
    if (!Platform.isAndroid) return;
    _channel.invokeMethod<void>('setSecure', secure).ignore();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
