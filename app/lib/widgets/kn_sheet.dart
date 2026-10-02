import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';

/// Title, content and right-aligned actions, laid out the same way in a
/// dialog and in a sheet. Put the primary action last.
class _Body extends StatelessWidget {
  const _Body({
    required this.child,
    this.title,
    this.actions = const [],
    this.scrollChild = false,
  });

  final Widget child;

  /// Scroll the content alone, when the caller bounds the height.
  final bool scrollChild;
  final String? title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) ...[
          Text(title!, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: KnSpace.md),
        ],
        if (scrollChild)
          Flexible(child: SingleChildScrollView(child: child))
        else
          child,
        if (actions.isNotEmpty) ...[
          const SizedBox(height: KnSpace.lg),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: KnSpace.sm,
            runSpacing: KnSpace.sm,
            children: actions,
          ),
        ],
      ],
    );
  }
}

/// A modal bottom sheet: `surface`, top corners rounded, a hairline above,
/// no drag handle, 20px padding. Phone layouts use it in place of dialogs.
Future<T?> showKnSheet<T>(
  BuildContext context,
  Widget child, {
  String? title,
  List<Widget> actions = const [],
}) {
  final c = context.kn;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    backgroundColor: c.surface,
    elevation: 0,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: c.border),
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(KnRadius.md),
      ),
    ),
    builder: (context) => Padding(
      // Keep the content above the on-screen keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: _Body(title: title, actions: actions, child: child),
      ),
    ),
  );
}

/// A dialog at desktop width, [showKnSheet] below it. The dialog is
/// `surface` with a hairline outline, [width] wide at most, 24px padding.
Future<T?> showKnDialog<T>(
  BuildContext context,
  Widget child, {
  String? title,
  List<Widget> actions = const [],
  double width = 480,
}) {
  if (context.isPhoneWidth) {
    return showKnSheet<T>(context, child, title: title, actions: actions);
  }
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Padding(
          padding: const EdgeInsets.all(KnSpace.lg),
          child: _Body(
            title: title,
            actions: actions,
            scrollChild: true,
            child: child,
          ),
        ),
      ),
    ),
  );
}
