import 'package:flutter/material.dart';

/// Adaptive layout helpers.
///
/// The shell has two modes:
///   * **narrow** — phone portrait, small windows. Page-stack
///     navigation; each page is full-width.
///   * **wide** — width >= [compactBreakpoint] (tablet / desktop).
///     Persistent two-pane shell with a left navigation rail plus a
///     right content pane. This matches the historical Windows-desktop
///     threshold so existing users see no behavior change.
///
/// The actual decision is made from the live [BoxConstraints] (from
/// `LayoutBuilder`) rather than [MediaQuery] so resizing a Windows
/// window across a breakpoint degrades gracefully.
class AdaptiveLayout {
  /// Minimum width at which the two-pane shell kicks in.
  ///
  /// Phones in portrait are typically < 720dp wide; tablets and
  /// desktop windows are >= 720dp wide.
  static const double compactBreakpoint = 720;

  /// Preferred width of the left navigation rail in the two-pane shell.
  static const double navRailWidth = 220;

  /// Preferred width of the left functional pane (library / settings /
  /// motions) when the model viewer is on the right.
  static const double sidePaneWidth = 320;

  /// Layout mode chosen from [constraints].
  ///
  /// * width >= [compactBreakpoint] → [LayoutMode.wide] (tablet/desktop).
  /// * otherwise → [LayoutMode.narrow] (phone portrait, narrow Windows
  ///   window).
  static LayoutMode modeFor(BoxConstraints constraints) {
    if (constraints.maxWidth >= compactBreakpoint) return LayoutMode.wide;
    return LayoutMode.narrow;
  }

  /// Whether [constraints] are wide enough to use the two-pane shell.
  static bool isWide(BoxConstraints constraints) =>
      modeFor(constraints) == LayoutMode.wide;

  /// Whether the running platform preferred the two-pane shell by default.
  ///
  /// On Windows the desktop window starts wide enough for the two-pane
  /// layout; on Android the device is typically phone-sized so the
  /// page-stack navigation (narrow) is used. This is a hint only — the
  /// actual decision is made from [isWide] using the live [MediaQuery]
  /// constraints, so resizing a Windows window below the breakpoint
  /// degrades gracefully.
  static bool prefersTwoPane(BuildContext context) {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux;
  }
}

/// Shell layout mode for a given [BoxConstraints].
enum LayoutMode {
  /// Phone portrait — page-stack navigation, full-width pages.
  narrow,

  /// Tablet / desktop — persistent two-pane shell.
  wide,
}
