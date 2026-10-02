import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/cold.dart';
import '../../theme/tokens.dart';

/// How the app reads and saves cold wallet messages: QR frames by camera on
/// Android, a `.kncold` file on desktop.
class ColdTransport {
  const ColdTransport();

  /// Scans a (possibly multi-frame) cold message, or opens a file on
  /// desktop. Null if the user gave up.
  Future<Uint8List?> receive(BuildContext context, {required String title}) {
    if (Platform.isAndroid) {
      return Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(builder: (_) => _ColdScanScreen(title: title)),
      );
    }
    return _readFile(context);
  }

  Future<Uint8List?> _readFile(BuildContext context) async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Kilonova cold wallet file', extensions: ['kncold']),
      ],
    );
    if (file == null) return null;
    return file.readAsBytes();
  }

  /// Saves `message` as a `.kncold` file, for moving by USB or SD card.
  Future<void> saveFile(BuildContext context, ColdMessage message) async {
    final location = await getSaveLocation(
      suggestedName: 'kilonova-${_slug(message.kind)}.kncold',
    );
    if (location == null) return;
    await File(location.path).writeAsBytes(message.file);
  }

  /// Hook for tests: called whenever an `AnimatedQr` shows a message. The
  /// real transport does nothing with it.
  void shown(ColdMessage message) {}

  static String _slug(ColdKind kind) => switch (kind) {
    ColdKind.pairing => 'pairing',
    ColdKind.syncRequest => 'sync-request',
    ColdKind.syncAnswer => 'sync-answer',
    ColdKind.signRequest => 'sign-request',
    ColdKind.signed => 'signed',
  };
}

/// Full-screen multi-frame scanner: feeds every scanned code into a
/// [FrameReader] and shows progress until the message is complete.
class _ColdScanScreen extends StatefulWidget {
  const _ColdScanScreen({required this.title});

  final String title;

  @override
  State<_ColdScanScreen> createState() => _ColdScanScreenState();
}

class _ColdScanScreenState extends State<_ColdScanScreen> {
  final _reader = FrameReader();
  ScanProgress? _progress;
  bool _done = false;

  void _found(Code code) {
    final text = code.text;
    if (_done || !code.isValid || text == null) return;
    try {
      final progress = _reader.add(frame: text);
      if (!mounted) return;
      setState(() => _progress = progress);
      if (progress.complete) {
        _done = true;
        Navigator.of(context).pop(_reader.message());
      }
    } on ColdFailure {
      // Not part of this message (or a stray code); keep scanning.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final progress = _progress;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Expanded(
            child: ReaderWidget(
              codeFormat: Format.qrCode,
              onScan: _found,
              showToggleCamera: false,
              scanDelay: const Duration(milliseconds: 150),
              scanDelaySuccess: Duration.zero,
              actionButtonsBackgroundColor: KnQr.ink,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(KnSpace.md),
            child: Text(
              progress != null && progress.total > 1
                  ? l.coldFramePartLabel(progress.received, progress.total)
                  : l.scanHelp,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
