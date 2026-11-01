import 'package:flutter/material.dart';

/// Motion list with truly equal-width rows and a collapse / expand toggle.
///
/// Each row is rendered as a custom full-width tap target (not an
/// [ActionChip], which sizes to its label and leaves blank space on the
/// right). All rows fill the full available width inside the panel,
/// regardless of the label's text length, so columns line up vertically
/// and the visible row count equals the number of groups (one row per
/// group — matching the old per-chip layout).
///
/// Layout modes:
///   * **scrollable:** wide Windows shell — bounded vertical [ListView]
///     of full-width rows whose internal scroll never exceeds
///     [maxHeight] so sibling controls (Reset / Zoom / Tap) stay
///     anchored on screen.
///   * **wrapping:** narrow phone layout — free-form [Wrap] of equal
///     width row tiles, no height bound.
///
/// Collapse / expand:
///   * The header row shows a chevron button that toggles
///     [MotionPanelState.expanded] via [onExpandToggle]. When
///     collapsed the list shrinks to a single stub line so gestures
///     remain visible. The transition is animated via [AnimatedSize].
class MotionPanel extends StatefulWidget {
  const MotionPanel({
    super.key,
    required this.groups,
    required this.onTap,
    this.scrollable = false,
    this.expand = false,
    this.maxHeight = 220,
    this.initialExpanded = true,
    this.onExpandToggle,
  });

  final List<String> groups;
  final void Function(String groupId) onTap;

  /// When `true`, the rows render inside a height-bounded vertical
  /// [ListView]. When `false`, the rows wrap horizontally.
  final bool scrollable;

  /// When `true` (and [scrollable] is also `true`), the list fills all
  /// available vertical space instead of being capped at [maxHeight].
  /// The widget must be placed inside a [Flex] parent (e.g. via
  /// [Expanded]) so the [ListView] can claim the remaining height.
  final bool expand;

  /// Maximum visible height of the scrollable motion list, in logical
  /// pixels. The list internally scrolls once rows would exceed this
  /// height; the surrounding layout stays fixed.
  final double maxHeight;

  /// Initial expanded state. Controlled externally by callers via
  /// [onExpandToggle] so the choice survives viewer rebuilds if the
  /// host decides to persist it.
  final bool initialExpanded;

  /// Called when the user taps the expand/collapse chevron. Hosts can
  /// pass the new state to a parent controller to keep the choice
  /// across widget rebuilds; the panel itself owns transient state.
  final ValueChanged<bool>? onExpandToggle;

  @override
  State<MotionPanel> createState() => MotionPanelState();
}

class MotionPanelState extends State<MotionPanel> {
  late bool _expanded = widget.initialExpanded;

  /// Whether the motion list is currently expanded.
  bool get expanded => _expanded;

  /// Programmatically toggle the expanded state. Useful for tests.
  void setExpanded(bool value) {
    if (!mounted) {
      _expanded = value;
      return;
    }
    setState(() => _expanded = value);
  }

  /// Build a single equally-sized motion row.
  ///
  /// Implementation note: this used to be an `ActionChip` wrapped in
  /// `SizedBox(width: double.infinity)`. `ActionChip` sizes to its
  /// label, so the chip background only extended over the label width
  /// even though the SizedBox forced the row's outer cell to fill the
  /// panel — adjacent rows of different label lengths ended up looking
  /// uneven. We now render a real Material tap target that fills the
  /// full row width and centers the label horizontally, so every row
  /// has the same visible width and the same hit area.
  Widget _buildRow(BuildContext context, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        width: double.infinity,
        child: Material(
          color: scheme.secondaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => widget.onTap(label),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.groups.isEmpty) {
      return const SizedBox.shrink();
    }

    final rows = widget.groups.map((g) => _buildRow(context, g)).toList();

    final collapsedStub = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Icon(
            Icons.play_circle_outline,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Text(
            'Motions (${widget.groups.length})',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Spacer(),
          Text(
            'Tap to expand',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );

    if (widget.expand && widget.scrollable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          if (_expanded)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ListView(
                  physics: const ClampingScrollPhysics(),
                  padding: EdgeInsets.zero,
                  children: rows,
                ),
              ),
            )
          else
            collapsedStub,
        ],
      );
    }

    final expandedBody = widget.scrollable
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.maxHeight),
              child: ListView(
                shrinkWrap: true,
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.zero,
                children: rows,
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final r in rows)
                  SizedBox(width: double.infinity, child: r),
              ],
            ),
          );

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          if (_expanded) expandedBody else collapsedStub,
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 4),
      child: Row(
        children: [
          const Icon(Icons.play_circle_outline, size: 18),
          const SizedBox(width: 6),
          Text('Motions', style: theme.textTheme.labelLarge),
          const Spacer(),
          Text(
            '${widget.groups.length}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: _expanded ? 'Collapse motion list' : 'Expand motion list',
            icon: AnimatedRotation(
              turns: _expanded ? 0 : -0.25,
              duration: const Duration(milliseconds: 180),
              child: const Icon(Icons.keyboard_arrow_down, size: 22),
            ),
            onPressed: () {
              setState(() => _expanded = !_expanded);
              widget.onExpandToggle?.call(_expanded);
            },
          ),
        ],
      ),
    );
  }
}
