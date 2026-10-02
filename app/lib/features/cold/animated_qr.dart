import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/cold.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/kn_button.dart';
import '../wallets/wallet_registry.dart';

/// Shows a cold message's QR frames in turn, with a save-to-file fallback.
/// Static when there is only one frame.
class AnimatedQr extends StatefulWidget {
  const AnimatedQr({super.key, required this.message, required this.registry});

  final ColdMessage message;
  final WalletRegistry registry;

  @override
  State<AnimatedQr> createState() => _AnimatedQrState();
}

class _AnimatedQrState extends State<AnimatedQr> {
  Timer? _timer;
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    widget.registry.cold.shown(widget.message);
    if (widget.message.frames.length > 1) {
      _timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        if (!mounted) return;
        setState(() => _frame = (_frame + 1) % widget.message.frames.length);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final frames = widget.message.frames;
    final data = frames.isEmpty ? '' : frames[_frame];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ColoredBox(
          color: KnQr.paper,
          child: Padding(
            // A quiet zone of about four modules, as scanners expect.
            padding: const EdgeInsets.all(KnSpace.lg),
            child: QrImageView(
              data: data,
              size: 280,
              padding: EdgeInsets.zero,
              backgroundColor: KnQr.paper,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: KnQr.ink,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: KnQr.ink,
              ),
              semanticsLabel: data,
            ),
          ),
        ),
        if (frames.length > 1) ...[
          const SizedBox(height: KnSpace.sm),
          Text(
            l.coldFramePartLabel(_frame + 1, frames.length),
            style: monoStyle(
              context,
              size: 13,
              color: context.kn.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: KnSpace.md),
        KnButton.text(
          l.coldSaveFileAction,
          onPressed: () =>
              widget.registry.cold.saveFile(context, widget.message),
        ),
      ],
    );
  }
}
