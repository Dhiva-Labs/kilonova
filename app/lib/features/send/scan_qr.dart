import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/tokens.dart';

/// Whether this device scans with its camera. Desktops read a QR code from
/// an image file instead.
bool get scansWithCamera => Platform.isAndroid;

/// Reads a QR code and returns its text, or null if the user gave up.
///
/// Decoding runs on the device (zxing-cpp); no image leaves it.
Future<String?> scanQr(BuildContext context) => scansWithCamera
    ? Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const _CameraScanScreen()),
      )
    : _readImageFile(context);

Future<String?> _readImageFile(BuildContext context) async {
  final l = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final file = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(
        label: l.scanImageTypes,
        extensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
      ),
    ],
  );
  if (file == null) return null;
  final code = await zx.readBarcodeImagePath(
    file,
    DecodeParams(format: Format.qrCode, tryHarder: true, maxSize: 1600),
  );
  final text = code.isValid ? code.text : null;
  if (text == null) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.scanNoCode)));
  }
  return text;
}

class _CameraScanScreen extends StatefulWidget {
  const _CameraScanScreen();

  @override
  State<_CameraScanScreen> createState() => _CameraScanScreenState();
}

class _CameraScanScreenState extends State<_CameraScanScreen> {
  bool _done = false;

  void _found(Code code) {
    final text = code.text;
    if (_done || !code.isValid || text == null) return;
    _done = true;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.scanTitle)),
      body: Column(
        children: [
          Expanded(
            child: ReaderWidget(
              codeFormat: Format.qrCode,
              onScan: _found,
              showToggleCamera: false,
              scanDelay: const Duration(milliseconds: 300),
              scanDelaySuccess: Duration.zero,
              actionButtonsBackgroundColor: KnQr.ink,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(KnSpace.md),
            child: Text(
              l.scanHelp,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
