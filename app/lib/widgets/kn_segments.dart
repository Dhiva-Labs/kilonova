import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';

/// One choice in a [KnSegments].
class KnSegment<T> {
  const KnSegment(this.value, this.label);

  final T value;
  final String label;
}

/// A 32px segmented control for a small set of exclusive choices, such as
/// fee priority. Text only, no icons.
class KnSegments<T> extends StatelessWidget {
  const KnSegments({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.expand = false,
  });

  final List<KnSegment<T>> segments;
  final T selected;

  /// Null disables the control.
  final ValueChanged<T>? onChanged;

  /// Stretch to the available width, sharing it equally.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = context.kn;
    final label = Theme.of(context).textTheme.labelLarge!;
    const radius = BorderRadius.all(Radius.circular(KnRadius.sm));

    Widget segment(int i) {
      final s = segments[i];
      final isSelected = s.value == selected;
      final onChanged = this.onChanged;
      return Semantics(
        button: true,
        selected: isSelected,
        inMutuallyExclusiveGroup: true,
        child: Material(
          color: isSelected ? c.accent : c.surface,
          child: InkWell(
            // The selected segment keeps its gold on hover.
            hoverColor: isSelected ? c.accent : null,
            highlightColor: isSelected ? c.accent : null,
            onTap: onChanged == null || isSelected
                ? null
                : () => onChanged(s.value),
            child: Container(
              height: 30,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : Border(left: BorderSide(color: c.border)),
              ),
              child: Text(
                s.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: label.copyWith(
                  color: isSelected
                      ? c.onAccent
                      : onChanged == null
                      ? c.textSecondary
                      : c.text,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: radius,
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(KnRadius.sm - 1)),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (var i = 0; i < segments.length; i++)
              expand ? Expanded(child: segment(i)) : segment(i),
          ],
        ),
      ),
    );
  }
}
