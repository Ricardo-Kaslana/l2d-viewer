import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bridge/immersive_channel.dart';
import '../bridge/texture_android_channel.dart';
import '../features/viewer/motion_panel.dart';
import '../data/settings_repo.dart';
import '../providers/model_provider.dart';
import '../providers/renderer_provider.dart';
import '../util/log.dart';
import '../widgets/adaptive_layout.dart';
import '../widgets/app_logo.dart';
import '../widgets/error_banner.dart';

/// Whether the native immersive fullscreen feature is available.
/// True on Windows (borderless fullscreen via MethodChannel).
/// [debugForceFullscreenAvailable] allows tests on non-Windows hosts to
/// exercise the fullscreen UI path.
@visibleForTesting
bool debugForceFullscreenAvailable = false;

bool get _fullscreenAvailable =>
    debugForceFullscreenAvailable || Platform.isWindows;

/// Model viewer page.
///
/// Displays the render surface as a [Texture] widget driven by the Rust
/// frame loop, plus motion triggers and gesture control buttons.
///
/// Two layout modes:
///   * **Wide (Windows desktop):** left functional column with motions
///     and gesture controls, right column hosts the model surface. This
///     is the natural place to put a long motion list — it scrolls
///     vertically without competing with the render area for vertical
///     space.
///   * **Narrow (Android portrait, small windows):** the model surface
///     fills the entire body; gesture controls live in a compact
///     floating bar overlaid at the bottom that auto-hides after a few
///     seconds (tap the surface to bring it back), and motions open in
///     a Material bottom sheet — the Android-native pattern for
///     full-screen media.
///
/// Set `embedded: true` when this page is hosted inside the wide shell
/// (no AppBar, no inner Scaffold) so it can fill the right pane.
///
/// Lifecycle:
///   * On `initState` the page calls `initialize()` + `loadModel()`.
///   * Once a model is loaded it starts the 60Hz frame loop via
///     `RendererNotifier.startFrameLoop()`. The notifier subscribes to
///     the FRB `Stream<FrameEvent>`, registers the shared D3D11 texture
///     with the Windows runner on the first `Updated` event, and pings
///     `markFrameAvailable` on every subsequent frame.
///   * `ViewerPage` watches `RendererState.textureId`. As soon as it is
///     non-null and `>= 0` the placeholder is replaced by
///     `Texture(textureId: textureId)`.
///   * On dispose the frame loop is stopped and the texture unregistered.
class ViewerPage extends ConsumerStatefulWidget {
  const ViewerPage({super.key, this.embedded = false});

  /// When `true`, the page omits the AppBar and inner Scaffold padding
  /// so it can sit flush inside the wide Windows shell's right pane.
  final bool embedded;

  @override
  ConsumerState<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends ConsumerState<ViewerPage>
    with WidgetsBindingObserver {
  RendererNotifier? _rendererNotifier;
  ImmersiveChannel? _immersive;

  /// Visibility of the floating control bar (narrow layout only).
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;

  /// Windows borderless fullscreen state.
  bool _isFullscreen = false;

  /// Whether the overlay control panel is visible (fullscreen mode only).
  bool _panelVisible = false;
  Timer? _panelHideTimer;

  /// Show the controls (if hidden) and re-arm the auto-hide timer.
  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      // Keep the bar visible while the surface is still a placeholder —
      // there is no tap-to-toggle handler before the texture exists.
      if (ref.read(rendererProvider).textureId == null) return;
      setState(() => _controlsVisible = false);
    });
  }

  /// Tap on the live surface toggles the control bar.
  void _toggleControls() {
    _hideControlsTimer?.cancel();
    if (!mounted) return;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  void _toggleFullscreen() {
    if (!_fullscreenAvailable) return;
    setState(() => _isFullscreen = !_isFullscreen);
    if (_isFullscreen) {
      _immersive?.enable().catchError((Object _) {});
    } else {
      _immersive?.disable().catchError((Object _) {});
    }
  }

  void _exitFullscreen() {
    if (!_isFullscreen) return;
    setState(() => _isFullscreen = false);
    _immersive?.disable().catchError((Object _) {});
  }

  void _showOverlayPanel() {
    _panelHideTimer?.cancel();
    if (!_panelVisible && mounted) {
      setState(() => _panelVisible = true);
    }
  }

  void _schedulePanelHide() {
    _panelHideTimer?.cancel();
    _panelHideTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() => _panelVisible = false);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rendererNotifier = ref.read(rendererProvider.notifier);
    if (Platform.isAndroid || _fullscreenAvailable) {
      _immersive = ImmersiveChannel(
        const MethodChannel('live2d_viewer/immersive'),
      );
      if (Platform.isAndroid) {
        _immersive!.enable().catchError((Object _) {});
      }
    }
    Future.microtask(() => _initializeAndLoad());
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _panelHideTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid || (_fullscreenAvailable && _isFullscreen)) {
      _immersive?.disable().catchError((Object _) {});
    }
    _rendererNotifier?.stopFrameLoop().catchError((Object _) {});
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    final notifier = ref.read(rendererProvider.notifier);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        notifier.detachAndroidSurface();
      case AppLifecycleState.resumed:
        notifier.reattachAndroidSurface();
      default:
        break;
    }
  }

  Future<void> _initializeAndLoad() async {
    final renderer = ref.read(rendererProvider.notifier);
    final model = ref.read(modelProvider);
    await renderer.initialize();
    if (!mounted) return;

    var modelPath = model.selectedModelPath;
    debugLog(
      '[viewer] initial selected model: ${modelPath == null ? "<none>" : pathBasename(modelPath)}',
    );
    if (modelPath == null) {
      final settings = ref.read(settingsRepoProvider).valueOrNull;
      final lastPath = settings?.lastSelectedModelPath;
      debugLog(
        '[viewer] last selected model: ${lastPath == null ? "<none>" : pathBasename(lastPath)}',
      );
      if (lastPath != null && lastPath.isNotEmpty) {
        await ref.read(modelProvider.notifier).selectModel(lastPath);
        if (!mounted) return;
        modelPath = ref.read(modelProvider).selectedModelPath;
        debugLog(
          '[viewer] after selectModel: ${modelPath == null ? "<none>" : pathBasename(modelPath)}',
        );
      }
    }

    debugLog(
      '[viewer] final model: ${modelPath == null ? "<none>" : pathBasename(modelPath)}',
    );
    if (modelPath != null) {
      await renderer.loadModel(modelPath);
      if (!mounted) return;
      // Don't spin up the frame loop when the load failed — rendering
      // an unloaded model would just emit Failed events at 60 Hz.
      if (ref.read(rendererProvider).status == RendererStatus.error) {
        debugLog('[viewer] loadModel failed, skipping startFrameLoop');
        return;
      }
      await renderer.startFrameLoop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final renderer = ref.watch(rendererProvider);
    final model = ref.watch(modelProvider);
    final theme = Theme.of(context);
    final body = LayoutBuilder(
      builder: (context, constraints) {
        switch (AdaptiveLayout.modeFor(constraints)) {
          case LayoutMode.wide:
            return _wideLayout(context, renderer, model, theme);
          case LayoutMode.narrow:
            return _narrowLayout(context, renderer, model, theme);
        }
      },
    );

    if (widget.embedded) {
      return _withKeyboardShortcuts(
        Column(
          children: [
            if (_fullscreenAvailable)
              SizedBox(
                height: 40,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 20),
                      tooltip: 'Reload model',
                      onPressed: () => _initializeAndLoad(),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      icon: Icon(
                        _isFullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        size: 20,
                      ),
                      tooltip: _isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
                      onPressed: _toggleFullscreen,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Viewer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload model',
            onPressed: () => _initializeAndLoad(),
          ),
          if (_fullscreenAvailable)
            IconButton(
              icon: Icon(
                _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              ),
              tooltip: _isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
              onPressed: _toggleFullscreen,
            ),
        ],
      ),
      body: _withKeyboardShortcuts(body),
    );
  }

  Widget _withKeyboardShortcuts(Widget child) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final notifier = ref.read(rendererProvider.notifier);
        switch (event.logicalKey) {
          case LogicalKeyboardKey.keyR:
            notifier.resetGesture();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.equal:
          case LogicalKeyboardKey.numpadAdd:
            notifier.zoom(1.1);
            return KeyEventResult.handled;
          case LogicalKeyboardKey.minus:
          case LogicalKeyboardKey.numpadSubtract:
            notifier.zoom(0.9);
            return KeyEventResult.handled;
          case LogicalKeyboardKey.f11:
            if (_fullscreenAvailable) {
              _toggleFullscreen();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          case LogicalKeyboardKey.escape:
            if (_isFullscreen) {
              _exitFullscreen();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          default:
            return KeyEventResult.ignored;
        }
      },
      child: child,
    );
  }

  /// Wide Windows shell layout: functional left column + model right.
  Widget _wideLayout(
    BuildContext context,
    RendererState renderer,
    ModelState model,
    ThemeData theme,
  ) {
    if (_isFullscreen) {
      return _fullscreenLayout(context, renderer, model, theme);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 320,
          child: _controlColumn(
            context: context,
            renderer: renderer,
            theme: theme,
            scrollable: true,
          ),
        ),
        VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: Column(
            children: [
              Expanded(child: _renderArea(context, renderer, model, theme)),
              if (renderer.status == RendererStatus.error)
                ErrorBanner(
                  message: renderer.errorMessage ?? 'unknown error',
                  onRetry: () => _initializeAndLoad(),
                  onDismiss: () =>
                      ref.read(rendererProvider.notifier).clearError(),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Fullscreen layout: render area fills the window; control panel is
  /// hidden and revealed via left-edge hover (20px hot zone).
  Widget _fullscreenLayout(
    BuildContext context,
    RendererState renderer,
    ModelState model,
    ThemeData theme,
  ) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _renderArea(context, renderer, model, theme),
        if (renderer.status == RendererStatus.error)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ErrorBanner(
              message: renderer.errorMessage ?? 'unknown error',
              onRetry: () => _initializeAndLoad(),
              onDismiss: () => ref.read(rendererProvider.notifier).clearError(),
            ),
          ),
        // Left-edge hot zone (20px) to trigger panel reveal.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 20,
          child: MouseRegion(
            onEnter: (_) => _showOverlayPanel(),
            onExit: (_) => _schedulePanelHide(),
            child: const SizedBox.expand(),
          ),
        ),
        // Sliding overlay control panel.
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          left: _panelVisible ? 0 : -320,
          top: 0,
          bottom: 0,
          width: 320,
          child: MouseRegion(
            onEnter: (_) => _showOverlayPanel(),
            onExit: (_) => _schedulePanelHide(),
            child: _panelVisible
                ? AnimatedOpacity(
                    opacity: 1.0,
                    duration: const Duration(milliseconds: 250),
                    child: Material(
                      elevation: 8,
                      color: Colors.black87,
                      child: SafeArea(
                        child: _controlColumn(
                          context: context,
                          renderer: renderer,
                          theme: theme.copyWith(
                            colorScheme: theme.colorScheme.copyWith(
                              surfaceContainerLow: Colors.black87,
                            ),
                          ),
                          scrollable: true,
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  /// Narrow layout (Android portrait): full-bleed render surface with a
  /// floating control bar overlaid at the bottom.
  ///
  /// The model gets the entire body — no fixed 45% control block eating
  /// vertical space. Gesture buttons sit in a compact bar over a gradient
  /// scrim; the bar auto-hides after a few seconds of inactivity and a
  /// tap on the live surface toggles it back. Motions open in a Material
  /// bottom sheet instead of occupying permanent screen real estate.
  Widget _narrowLayout(
    BuildContext context,
    RendererState renderer,
    ModelState model,
    ThemeData theme,
  ) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _renderArea(context, renderer, model, theme, narrow: true),
        if (renderer.status == RendererStatus.error)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ErrorBanner(
              message: renderer.errorMessage ?? 'unknown error',
              onRetry: () => _initializeAndLoad(),
              onDismiss: () => ref.read(rendererProvider.notifier).clearError(),
            ),
          ),
        // Top-right landscape entry. Kept outside the bottom control bar so
        // the bar stays at 5 buttons (5×64dp + padding = ~336dp) and never
        // overflows a narrow portrait viewport (~360dp wide). The button
        // does not auto-hide with the bottom bar — it is the route entry,
        // not a gesture control, and should stay discoverable. It mirrors
        // the landscape viewer's top-left "Exit landscape" button so the
        // hand-off is positionally symmetric.
        Positioned(
          top: MediaQuery.paddingOf(context).top + 8,
          right: 8,
          child: _portraitLandscapeEntry(),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            ignoring: !_controlsVisible,
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              child: _bottomControls(context, renderer),
            ),
          ),
        ),
      ],
    );
  }

  /// Top-right circular icon button on the portrait immersive viewer that
  /// pushes the `_LandscapeImmersiveViewer` route. Always available; the
  /// landscape viewer shows the same render surface (or the placeholder
  /// area if no model is loaded) rotated to the long edge.
  Widget _portraitLandscapeEntry() {
    return SizedBox(
      width: 46,
      height: 46,
      child: Material(
        color: Colors.black.withValues(alpha: 0.4),
        shape: const CircleBorder(),
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 22,
          icon: const Icon(Icons.rotate_right, color: Colors.white),
          tooltip: 'Landscape',
          onPressed: _openLandscapeImmersive,
        ),
      ),
    );
  }

  /// Floating bottom control bar: circular icon buttons over a gradient
  /// scrim, plus a motions button that opens the bottom sheet.
  Widget _bottomControls(BuildContext context, RendererState renderer) {
    final notifier = ref.read(rendererProvider.notifier);
    final hasModel = renderer.isModelLoaded;
    final groups = renderer.motionGroups;
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    void press(VoidCallback action) {
      _scheduleHideControls();
      action();
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0.0, 0.6],
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6)],
        ),
      ),
      padding: EdgeInsets.fromLTRB(8, 36, 8, 10 + bottomPad),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _controlButton(
            icon: Icons.restart_alt,
            label: 'Reset',
            onPressed: hasModel ? () => press(notifier.resetGesture) : null,
          ),
          _controlButton(
            icon: Icons.zoom_out,
            label: 'Out',
            onPressed: hasModel ? () => press(() => notifier.zoom(0.9)) : null,
          ),
          _controlButton(
            icon: Icons.zoom_in,
            label: 'In',
            onPressed: hasModel ? () => press(() => notifier.zoom(1.1)) : null,
          ),
          _controlButton(
            icon: Icons.touch_app,
            label: 'Tap',
            onPressed: hasModel ? () => press(notifier.tap) : null,
          ),
          _controlButton(
            icon: Icons.play_circle_outline,
            label: 'Motions',
            badge: groups.isNotEmpty ? groups.length : null,
            onPressed: groups.isNotEmpty
                ? () => press(() => _showMotionSheet(groups, notifier))
                : null,
          ),
        ],
      ),
    );
  }

  /// Push the phone-landscape immersive viewer route.
  ///
  /// This is the **only** landscape surface in the app. The portrait
  /// viewer (`_narrowLayout`) → landscape viewer hand-off does not reload
  /// the model or restart the frame loop: the landscape route reads the
  /// same `rendererProvider` state and reuses the same `_LiveRenderSurface`
  /// widget family.
  void _openLandscapeImmersive() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        // `fullscreenDialog: false` so Android back gesture pops the
        // route naturally; the in-app Exit button is the primary affordance.
        fullscreenDialog: false,
        builder: (_) => const _LandscapeImmersiveViewer(),
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    int? badge,
  }) {
    final enabled = onPressed != null;
    return SizedBox(
      width: 64,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(
                          alpha: enabled ? 0.14 : 0.05,
                        ),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        icon,
                        size: 22,
                        color: enabled ? Colors.white : Colors.white38,
                      ),
                    ),
                    if (badge != null)
                      Positioned(
                        top: -3,
                        right: -3,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 17),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            '$badge',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: enabled ? Colors.white70 : Colors.white30,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Motion picker as a Material bottom sheet (Android-native pattern).
  void _showMotionSheet(List<String> groups, RendererNotifier notifier) {
    _showMotionBottomSheet(context, groups, notifier);
  }

  Widget _renderArea(
    BuildContext context,
    RendererState renderer,
    ModelState model,
    ThemeData theme, {
    bool narrow = false,
  }) {
    final hasModel = model.selectedModelPath != null;
    final modelName = hasModel
        ? model.selectedModelPath!.split(RegExp(r'[/\\]')).last
        : null;
    final isLoading = renderer.status == RendererStatus.loading;

    // When the frame loop has registered a texture, display the live
    // GPU output via Flutter's Texture widget. The shared D3D12
    // offscreen texture tracks the renderer's `offscreen_size`, so
    // the texture's real aspect ratio is whatever
    // `RendererNotifier.setWindowSize` last requested — almost always
    // a non-square window rectangle. Earlier versions wrapped the
    // Texture in a hard-coded `AspectRatio(1.0)` inside a black
    // `ColoredBox`, which forced the texture into a square on any
    // non-square window and left black bars on both sides (the visual
    // bug the user reported). We now let the texture fill the
    // available space directly with `FittedBox(BoxFit.contain)` and
    // forward the actual layout constraints to the renderer so the
    // offscreen texture is allocated at the correct size and aspect
    // from the start. Pixel aspect ratio is preserved either way
    // because `fit_model_scales` is already aspect-correct on the Rust
    // side.
    final textureId = renderer.textureId;
    if (textureId != null && textureId >= 0) {
      final notifier = ref.read(rendererProvider.notifier);
      final badgeName = _modelBadgeName(model);
      return Stack(
        fit: StackFit.expand,
        children: [
          Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                final factor = event.scrollDelta.dy < 0 ? 1.1 : 0.9;
                notifier.zoom(factor);
              }
            },
            child: _LiveRenderSurface(
              textureId: textureId,
              notifier: notifier,
              onTap: _toggleControls,
            ),
          ),
          if (badgeName != null)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 8,
              child: _ModelNameBadge(name: badgeName),
            ),
          if (renderer.isFrameLoopRunning &&
              ref.watch(settingsRepoProvider).valueOrNull?.showFps == true)
            Positioned(
              // Narrow layout: the top-right corner is occupied by the
              // 46dp landscape entry button, so the badge sits below it.
              top: MediaQuery.paddingOf(context).top + (narrow ? 62 : 8),
              right: 8,
              child: _FpsBadge(fps: renderer.fps),
            ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLowest,
      child: CustomPaint(
        painter: _PlaceholderPainter(color: theme.colorScheme.outlineVariant),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading)
                SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: theme.colorScheme.primary,
                  ),
                )
              else
                AppLogo(
                  size: 64,
                  color: theme.colorScheme.primary.withValues(alpha: 0.5),
                ),
              const SizedBox(height: 12),
              Text(
                _renderAreaText(renderer, hasModel, modelName),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (renderer.isFrameLoopRunning &&
                  textureId == null &&
                  renderer.frameCount == 0) ...[
                const SizedBox(height: 8),
                Text(
                  'Waiting for first frame…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _renderAreaText(
    RendererState renderer,
    bool hasModel,
    String? modelName,
  ) {
    if (!hasModel) return 'No model selected.\nGo to Library to pick one.';
    switch (renderer.status) {
      case RendererStatus.loading:
        return 'Loading $modelName…';
      case RendererStatus.ready:
        return 'Ready: $modelName';
      case RendererStatus.error:
        return 'Failed to load $modelName';
      case RendererStatus.idle:
        return 'Selected: $modelName';
    }
  }

  /// Column with motions + gesture controls (wide layout only).
  ///
  /// The column fills the full left-pane height. The [MotionPanel]
  /// self-manages its own header (with collapse chevron) and bounded
  /// height; gestures sit anchored at the bottom of the column without
  /// scrolling the page. The narrow (Android portrait) layout does not
  /// use this — it overlays a compact floating bar and opens motions in
  /// a bottom sheet instead.
  Widget _controlColumn({
    required BuildContext context,
    required RendererState renderer,
    required ThemeData theme,
    required bool scrollable,
  }) {
    final notifier = ref.read(rendererProvider.notifier);
    final hasModel = renderer.isModelLoaded;

    final motionList = MotionPanel(
      groups: renderer.motionGroups,
      onTap: notifier.triggerMotion,
      scrollable: scrollable,
      expand: scrollable,
    );

    final gestures = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Gestures', style: theme.textTheme.labelLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: hasModel ? notifier.resetGesture : null,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Reset'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: hasModel ? () => notifier.zoom(1.1) : null,
                      icon: const Icon(Icons.zoom_in),
                      label: const Text('Zoom In'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: hasModel ? () => notifier.zoom(0.9) : null,
                      icon: const Icon(Icons.zoom_out),
                      label: const Text('Zoom Out'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: hasModel ? notifier.tap : null,
                      icon: const Icon(Icons.touch_app),
                      label: const Text('Tap'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    return RepaintBoundary(
      child: Container(
        color: theme.colorScheme.surfaceContainerLow,
        child: scrollable
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: motionList),
                  gestures,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [motionList, const Spacer(), gestures],
              ),
      ),
    );
  }
}

/// Phone-landscape immersive viewer.
///
/// Reached only from the portrait immersive viewer's bottom control bar
/// (the "Rotate" button). It is the **only** landscape surface in the app:
/// every other page stays portrait-locked via `main.dart`. Entering pushes
/// a full-screen route that allows `landscapeLeft` (in addition to
/// `portraitUp`) so the user can rotate the phone clockwise to view the
/// model on the long edge. The model render surface fills the entire
/// screen with no AppBar and no padding; gesture controls live in a
/// vertical floating rail `_sideControls` overlaid on the right edge,
/// sharing the portrait viewer's `_controlsVisible` /
/// `_scheduleHideControls` / `_toggleControls` state machine. An
/// "Exit" button at the top-left restores the portrait-only lock and
/// pops back to the portrait viewer.
///
/// The render surface is the same `_LiveRenderSurface` widget family the
/// portrait viewer uses, reading the same `rendererProvider` state — the
/// frame loop and texture registration are already running, so entering
/// landscape does not reload the model or restart the loop. The Android
/// immersive channel stays enabled for the duration of the route.
class _LandscapeImmersiveViewer extends ConsumerStatefulWidget {
  const _LandscapeImmersiveViewer();

  @override
  ConsumerState<_LandscapeImmersiveViewer> createState() =>
      _LandscapeImmersiveViewerState();
}

class _LandscapeImmersiveViewerState
    extends ConsumerState<_LandscapeImmersiveViewer> {
  // Note: no `WidgetsBindingObserver` mixin. The portrait
  // `_ViewerPageState` is a `WidgetsBindingObserver` because it
  // overrides `didChangeAppLifecycleState` to pause / resume the
  // Android surface; the landscape route reuses the same renderer
  // (same `rendererProvider`) so its lifecycle is already covered
  // by the parent state and would just duplicate observer calls.
  /// Visibility of the floating side rail (shared semantics with the
  /// portrait viewer's `_controlsVisible`).
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      if (ref.read(rendererProvider).textureId == null) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    _hideControlsTimer?.cancel();
    if (!mounted) return;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  Future<void> _exit() async {
    _hideControlsTimer?.cancel();
    // Pop first so the route transition starts immediately; the portrait
    // lock restoration is best-effort and must not block the UI pop (in
    // tests `setPreferredOrientations` awaits a platform channel that has
    // no handler, which would otherwise stall the pop until the test pump
    // times out).
    if (mounted) Navigator.of(context).pop();
    // Restore the portrait-only lock shared by every other page.
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
  }

  @override
  void initState() {
    super.initState();
    // Allow the user to rotate the phone clockwise to view the model on
    // the long edge. `portraitUp` is kept so a quick rotate-and-back
    // does not bounce through an intermediate orientation. We exclude
    // `portraitDown` (telephone handset pointing up) to avoid reverse UI
    // and the mid-rotation device-swap renderer rebuild edge case.
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.portraitUp,
    ]);
    _scheduleHideControls();
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    // Best-effort portrait restoration in case the route is popped by
    // the system back button rather than the in-app Exit button. The
    // portrait-only lock is idempotent.
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final renderer = ref.watch(rendererProvider);
    final model = ref.watch(modelProvider);
    final theme = Theme.of(context);
    return Scaffold(
      // No AppBar — the model render surface fills the entire screen
      // with no top/bottom bars, matching the portrait immersive viewer.
      body: SafeArea(
        top: false,
        bottom: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _renderArea(context, renderer, model, theme),
            // Exit button top-left.
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 8,
              child: _exitButton(),
            ),
            if (_modelBadgeName(model) != null)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 8,
                left: 62,
                child: _ModelNameBadge(name: _modelBadgeName(model)!),
              ),
            if (renderer.isFrameLoopRunning &&
                ref.watch(settingsRepoProvider).valueOrNull?.showFps == true)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 8,
                // Clear of the 72dp right-edge control rail.
                right: 80,
                child: _FpsBadge(fps: renderer.fps),
              ),
            // Right-edge vertical floating control rail.
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  child: _sideControls(context, renderer),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _exitButton() {
    return SizedBox(
      width: 46,
      height: 46,
      child: Material(
        color: Colors.black.withValues(alpha: 0.4),
        shape: const CircleBorder(),
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 22,
          icon: const Icon(Icons.rotate_left, color: Colors.white),
          tooltip: 'Exit landscape',
          onPressed: _exit,
        ),
      ),
    );
  }

  /// Right-edge vertical floating control rail: circular icon buttons
  /// stacked top-to-bottom, each with a tooltip on tap. Pure icons (no
  /// text labels) so five buttons fit the ~360dp landscape height
  /// without scrolling.
  Widget _sideControls(BuildContext context, RendererState renderer) {
    final notifier = ref.read(rendererProvider.notifier);
    final hasModel = renderer.isModelLoaded;
    final groups = renderer.motionGroups;
    final topPad = MediaQuery.paddingOf(context).top;

    void press(VoidCallback action) {
      _scheduleHideControls();
      action();
    }

    return Container(
      width: 72,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          stops: const [0.0, 0.6],
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6)],
        ),
      ),
      padding: EdgeInsets.fromLTRB(0, topPad + 8, 0, 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _sideButton(
            context: context,
            icon: Icons.restart_alt,
            tooltip: 'Reset',
            onPressed: hasModel ? () => press(notifier.resetGesture) : null,
          ),
          _sideButton(
            context: context,
            icon: Icons.zoom_out,
            tooltip: 'Zoom Out',
            onPressed: hasModel ? () => press(() => notifier.zoom(0.9)) : null,
          ),
          _sideButton(
            context: context,
            icon: Icons.zoom_in,
            tooltip: 'Zoom In',
            onPressed: hasModel ? () => press(() => notifier.zoom(1.1)) : null,
          ),
          _sideButton(
            context: context,
            icon: Icons.touch_app,
            tooltip: 'Tap',
            onPressed: hasModel ? () => press(notifier.tap) : null,
          ),
          _sideButton(
            context: context,
            icon: Icons.play_circle_outline,
            tooltip: 'Motions',
            badge: groups.isNotEmpty ? groups.length : null,
            onPressed: groups.isNotEmpty
                ? () => press(() => _showMotionSheet(groups, notifier))
                : null,
          ),
        ],
      ),
    );
  }

  Widget _sideButton({
    required BuildContext context,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    int? badge,
  }) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: enabled ? 0.14 : 0.05),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 22,
              icon: Icon(icon, color: enabled ? Colors.white : Colors.white38),
              onPressed: onPressed,
            ),
          ),
          if (badge != null)
            Positioned(
              top: -3,
              right: -3,
              child: Container(
                constraints: const BoxConstraints(minWidth: 17),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '$badge',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _renderArea(
    BuildContext context,
    RendererState renderer,
    ModelState model,
    ThemeData theme,
  ) {
    final textureId = renderer.textureId;
    if (textureId != null && textureId >= 0) {
      final notifier = ref.read(rendererProvider.notifier);
      return Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            final factor = event.scrollDelta.dy < 0 ? 1.1 : 0.9;
            notifier.zoom(factor);
          }
        },
        child: _LiveRenderSurface(
          textureId: textureId,
          notifier: notifier,
          onTap: _toggleControls,
        ),
      );
    }
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLowest,
      child: Center(
        child: AppLogo(
          size: 64,
          color: theme.colorScheme.primary.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  void _showMotionSheet(List<String> groups, RendererNotifier notifier) {
    _showMotionBottomSheet(context, groups, notifier);
  }
}

/// Motion picker bottom sheet shared by the portrait viewer and the
/// landscape immersive viewer (identical content, different hosts).
void _showMotionBottomSheet(
  BuildContext context,
  List<String> groups,
  RendererNotifier notifier,
) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Motions (${groups.length})',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                children: [
                  for (final g in groups)
                    ListTile(
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(g),
                      dense: true,
                      onTap: () {
                        notifier.triggerMotion(g);
                        Navigator.of(sheetContext).pop();
                      },
                    ),
                ],
              ),
            ),
            SizedBox(height: MediaQuery.paddingOf(sheetContext).bottom),
          ],
        ),
      );
    },
  );
}

/// User-facing name of the currently selected model: basename of the
/// selected path with the `.model3.json` suffix stripped.
String? _modelBadgeName(ModelState model) {
  final path = model.selectedModelPath;
  if (path == null) return null;
  var name = path.split(RegExp(r'[/\\]')).last;
  const suffix = '.model3.json';
  if (name.endsWith(suffix)) {
    name = name.substring(0, name.length - suffix.length);
  }
  return name.isEmpty ? null : name;
}

/// Small translucent pill overlaid on the render surface showing the
/// currently playing model's name.
class _ModelNameBadge extends StatelessWidget {
  const _ModelNameBadge({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }
}

class _FpsBadge extends StatelessWidget {
  const _FpsBadge({required this.fps});

  final int fps;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          '$fps FPS',
          style: TextStyle(
            color: fps >= 50
                ? Colors.greenAccent
                : fps >= 30
                ? Colors.amber
                : Colors.redAccent,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// Draws a subtle grid placeholder for the render surface.
class _PlaceholderPainter extends CustomPainter {
  const _PlaceholderPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PlaceholderPainter oldDelegate) =>
      color != oldDelegate.color;
}

/// Live model render surface backed by a registered shared texture.
///
/// The render subtree is cached by [textureId] so that ancestor
/// rebuilds (tooltip overlay insertion, button hover repaints) return
/// the identical widget instance and Flutter skips the element update
/// entirely — the TextureLayer is never re-synthesised. Only a
/// textureId change (D3D12 offscreen reallocation) invalidates the
/// cache and rebuilds the subtree.
class _LiveRenderSurface extends StatefulWidget {
  const _LiveRenderSurface({
    required this.textureId,
    required this.notifier,
    this.onTap,
  });

  final int textureId;
  final RendererNotifier notifier;

  /// Single-tap on the surface (toggles the floating control bar).
  final VoidCallback? onTap;

  @override
  State<_LiveRenderSurface> createState() => _LiveRenderSurfaceState();
}

class _LiveRenderSurfaceState extends State<_LiveRenderSurface> {
  Size? _lastReported;

  // Cache the render subtree keyed by textureId. Ancestor rebuilds
  // that keep the same textureId return the identical widget instance,
  // so Flutter skips the element update and the TextureLayer is never
  // re-synthesised. Only a textureId change (D3D12 reallocation)
  // invalidates the cache.
  Widget? _cachedChild;
  int? _cachedTextureId;

  void _maybeReportSize(double logicalW, double logicalH, double pixelRatio) {
    if (logicalW <= 0 || logicalH <= 0) return;
    var physW = (logicalW * pixelRatio).round();
    var physH = (logicalH * pixelRatio).round();
    if (Platform.isAndroid) {
      // Cap the render buffer resolution on mobile; the compositor
      // upscales to the widget size for free (fragment-bound GPUs).
      (physW, physH) = capRenderSize(physW, physH);
    }
    final next = Size(physW.toDouble(), physH.toDouble());
    if (_lastReported == next) return;
    _lastReported = next;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.notifier.setWindowSize(physW, physH).catchError((Object _) {});
      if (Platform.isAndroid) {
        TextureAndroidChannel.instance
            .resize(physW, physH)
            .catchError((Object _) {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_cachedTextureId != widget.textureId) {
      _cachedTextureId = widget.textureId;
      _cachedChild = RepaintBoundary(
        child: _TextureLeaf(
          textureId: widget.textureId,
          notifier: widget.notifier,
          onLayout: _maybeReportSize,
          onTap: widget.onTap,
        ),
      );
    }
    return _cachedChild!;
  }
}

/// Stable leaf that owns the [Texture] and its gesture handler.
///
/// The [Texture] widget is cached by textureId so the identical
/// instance survives LayoutBuilder re-entries, preventing
/// TextureLayer re-synthesis on ancestor rebuilds.
class _TextureLeaf extends StatefulWidget {
  const _TextureLeaf({
    required this.textureId,
    required this.notifier,
    required this.onLayout,
    this.onTap,
  });

  final int textureId;
  final RendererNotifier notifier;
  final void Function(double w, double h, double pixelRatio) onLayout;

  /// Single-tap on the surface (toggles the floating control bar).
  final VoidCallback? onTap;

  @override
  State<_TextureLeaf> createState() => _TextureLeafState();
}

class _TextureLeafState extends State<_TextureLeaf> {
  Texture? _cachedTexture;
  int? _cachedTextureId;
  double _lastScale = 1.0;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          if (w <= 0 || h <= 0) return const SizedBox.expand();
          final pixelRatio = MediaQuery.devicePixelRatioOf(context);
          widget.onLayout(w, h, pixelRatio);

          if (_cachedTextureId != widget.textureId) {
            _cachedTextureId = widget.textureId;
            _cachedTexture = Texture(
              key: ValueKey('tex-${widget.textureId}'),
              textureId: widget.textureId,
            );
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onScaleStart: (_) {
              _lastScale = 1.0;
              widget.notifier.panStart();
            },
            onScaleUpdate: (details) {
              if (details.scale != 1.0) {
                final incremental = details.scale / _lastScale;
                widget.notifier.zoom(incremental);
                _lastScale = details.scale;
              }
              widget.notifier.panDelta(
                details.focalPointDelta.dx,
                details.focalPointDelta.dy,
                (w * pixelRatio).round(),
                (h * pixelRatio).round(),
              );
            },
            onScaleEnd: (_) => widget.notifier.panEnd(),
            onDoubleTap: () => widget.notifier.resetGesture(),
            child: SizedBox(width: w, height: h, child: _cachedTexture),
          );
        },
      ),
    );
  }
}
