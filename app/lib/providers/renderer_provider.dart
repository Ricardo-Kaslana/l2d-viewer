import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bridge/texture_android_channel.dart';
import '../bridge/texture_method_channel.dart';
import '../data/settings_repo.dart';
import '../src/rust/frb_api.dart';
import '../src/rust/render/frame_driver.dart';
import '../src/rust/render/texture_export.dart';
import '../util/log.dart';

/// Short, path-free error text for the UI. Other exceptions keep their message
/// so tests and actionable renderer errors remain visible.
String _rendererErrorText(Object error) {
  if (error is FileSystemException) return 'File operation failed';
  return error.toString();
}

/// Status of the renderer state machine.
enum RendererStatus { idle, loading, ready, error }

/// Immutable snapshot of the renderer surface.
class RendererState {
  const RendererState({
    this.isInitialized = false,
    this.isModelLoaded = false,
    this.currentModelPath,
    this.motionGroups = const [],
    this.status = RendererStatus.idle,
    this.errorMessage,
    this.textureId,
    this.frameCount = 0,
    this.isFrameLoopRunning = false,
    this.fps = 0,
  });

  final bool isInitialized;
  final bool isModelLoaded;
  final String? currentModelPath;
  final List<String> motionGroups;
  final RendererStatus status;
  final String? errorMessage;

  /// Flutter texture ID returned by the Windows runner's
  /// `register` MethodChannel call. `null` while no texture is
  /// registered; `-1` if the runner rejected the handle.
  final int? textureId;
  final int frameCount;
  final bool isFrameLoopRunning;

  /// Measured render frames per second (updated once per second).
  final int fps;

  RendererState copyWith({
    bool? isInitialized,
    bool? isModelLoaded,
    String? currentModelPath,
    List<String>? motionGroups,
    RendererStatus? status,
    String? errorMessage,
    bool clearError = false,
    int? textureId,
    bool clearTextureId = false,
    int? frameCount,
    bool? isFrameLoopRunning,
    int? fps,
  }) {
    return RendererState(
      isInitialized: isInitialized ?? this.isInitialized,
      isModelLoaded: isModelLoaded ?? this.isModelLoaded,
      currentModelPath: currentModelPath ?? this.currentModelPath,
      motionGroups: motionGroups ?? this.motionGroups,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      textureId: clearTextureId ? null : (textureId ?? this.textureId),
      frameCount: frameCount ?? this.frameCount,
      isFrameLoopRunning: isFrameLoopRunning ?? this.isFrameLoopRunning,
      fps: fps ?? this.fps,
    );
  }
}

/// Result of loading a model into the renderer.
class ModelLoadResult {
  const ModelLoadResult({required this.motionGroups});
  final List<String> motionGroups;
}

/// Abstract renderer control surface.
abstract class RendererApi {
  Future<void> initialize();
  Future<ModelLoadResult> loadModel(String path);
  Future<void> triggerMotion(String group);
  Future<void> resetGesture();
  Future<void> tap();
  Future<void> zoom(double factor);
  Future<void> panStart();
  Future<void> panDelta(double dx, double dy, int surfaceW, int surfaceH);
  Future<void> panEnd();
  Future<void> resize(int width, int height);
  Future<List<String>> getMotionGroups();

  /// Set the logical window size for the offscreen render path.
  Future<void> setWindowSize(int width, int height);

  /// Set the frame-loop FPS cap (0 = unlimited). Takes effect on the next
  /// tick of a running loop.
  Future<void> setTargetFps(int fps);

  /// Start a 60Hz frame loop. Returns a Stream of [FrameEvent]s.
  Stream<FrameEvent> startFrameLoop();

  /// Stop a previously started frame loop.
  Future<void> stopFrameLoop();

  /// Returns (scaleX, scaleY, translateX, translateY).
  Future<(double, double, double, double)> getGestureState();

  /// Restore a previously saved gesture state.
  Future<void> setGestureState(
    double scaleX,
    double scaleY,
    double translateX,
    double translateY,
  );

  /// Attach an Android rendering surface from a raw ANativeWindow pointer.
  Future<void> attachSurface(int nativeWindow, int width, int height);

  /// Detach the current Android rendering surface.
  Future<void> detachSurface();
}

/// Real renderer API backed by FRB-generated bindings.
class FrbRendererApi implements RendererApi {
  RendererHandle? _handle;
  Future<RendererHandle>? _handleFuture;

  /// Caches the in-flight Future (not just the result): with
  /// `_handle ??= await ...` two concurrent callers both observe null
  /// and each create a native renderer, leaking one undisposed wgpu
  /// device. A failed creation clears the cache so the next call
  /// retries.
  Future<RendererHandle> _getHandle() {
    return _handleFuture ??= RendererHandle.newHeadless().then(
      (h) {
        _handle = h;
        return h;
      },
      onError: (Object e, StackTrace st) {
        _handleFuture = null;
        Error.throwWithStackTrace(e, st);
      },
    );
  }

  @override
  Future<void> initialize() async {
    await _getHandle();
  }

  @override
  Future<ModelLoadResult> loadModel(String path) async {
    final handle = await _getHandle();
    try {
      final info = await handle.loadModel(path: path);
      return ModelLoadResult(motionGroups: info.motionGroups);
    } catch (e) {
      debugLog('[renderer] native loadModel failed: ${e.runtimeType}');
      throw 'Failed to load model';
    }
  }

  @override
  Future<void> triggerMotion(String group) async {
    final handle = await _getHandle();
    await handle.triggerMotion(group: group);
  }

  @override
  Future<void> resetGesture() async {
    final handle = await _getHandle();
    await handle.resetGesture();
  }

  @override
  Future<void> tap() async {
    final handle = await _getHandle();
    await handle.tap();
  }

  @override
  Future<void> zoom(double factor) async {
    final handle = await _getHandle();
    await handle.zoom(factor: factor);
  }

  @override
  Future<void> panStart() async {
    final handle = await _getHandle();
    await handle.panStart();
  }

  @override
  Future<void> panDelta(
    double dx,
    double dy,
    int surfaceW,
    int surfaceH,
  ) async {
    final handle = await _getHandle();
    await handle.panDelta(
      dx: dx,
      dy: dy,
      surfaceW: surfaceW,
      surfaceH: surfaceH,
    );
  }

  @override
  Future<void> panEnd() async {
    final handle = await _getHandle();
    await handle.panEnd();
  }

  @override
  Future<void> resize(int width, int height) async {
    final handle = await _getHandle();
    await handle.resize(width: width, height: height);
  }

  @override
  Future<List<String>> getMotionGroups() async {
    final handle = await _getHandle();
    return await handle.getMotionGroups();
  }

  @override
  Future<void> setWindowSize(int width, int height) async {
    final handle = await _getHandle();
    await handle.setWindowSize(width: width, height: height);
  }

  @override
  Future<void> setTargetFps(int fps) async {
    final handle = await _getHandle();
    await handle.setTargetFps(fps: fps);
  }

  @override
  Stream<FrameEvent> startFrameLoop() {
    // The FRB-generated binding returns Stream<FrameEvent> directly.
    // We capture the handle lazily via a stream transformer so callers
    // don't need to await initialize() first.
    //
    // `onCancel` propagates listener cancellation back to the Rust frame
    // loop: without it, the worker thread keeps ticking and pushing
    // events into the (now-closed) controller after every ViewerPage
    // dispose, which `isClosed` guards silently swallow but leaves the
    // native handle / GPU resources alive until the renderer itself is
    // dropped. Cancel the FRB subscription so the Rust worker sees its
    // `await for` end and exits cleanly.
    final controller = StreamController<FrameEvent>();
    StreamSubscription<FrameEvent>? subscription;
    controller.onCancel = () async {
      await subscription?.cancel();
      subscription = null;
    };
    () async {
      try {
        final handle = await _getHandle();
        final stream = handle.startFrameLoop();
        subscription = stream.listen(
          (event) {
            if (!controller.isClosed) {
              controller.add(event);
            }
          },
          onError: (Object e, StackTrace _) {
            if (!controller.isClosed) {
              controller.addError(e);
            }
          },
          cancelOnError: false,
        );
        // Keep the pump alive until the upstream finishes (Dart side
        // cancels the FRB stream) or the controller is closed.
        await subscription!.asFuture<void>();
      } catch (e) {
        if (!controller.isClosed) {
          controller.addError(e);
        }
      } finally {
        await subscription?.cancel();
        subscription = null;
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    }();
    return controller.stream;
  }

  @override
  Future<void> stopFrameLoop() async {
    final handle = _handle;
    if (handle == null) return;
    await handle.stopFrameLoop();
  }

  @override
  Future<(double, double, double, double)> getGestureState() async {
    final handle = await _getHandle();
    final result = await handle.getGestureState();
    return (result.$1, result.$2, result.$3, result.$4);
  }

  @override
  Future<void> setGestureState(
    double scaleX,
    double scaleY,
    double translateX,
    double translateY,
  ) async {
    final handle = await _getHandle();
    await handle.setGestureState(
      scaleX: scaleX,
      scaleY: scaleY,
      translateX: translateX,
      translateY: translateY,
    );
  }

  @override
  Future<void> attachSurface(int nativeWindow, int width, int height) async {
    final handle = await _getHandle();
    await handle.attachSurface(
      windowPtr: BigInt.from(nativeWindow),
      width: width,
      height: height,
    );
  }

  @override
  Future<void> detachSurface() async {
    final handle = _handle;
    if (handle == null) return;
    await handle.detachSurface();
  }
}

/// Provider for the renderer API implementation.
///
/// Defaults to [FrbRendererApi] backed by the real FRB bindings.
/// Override in tests with a test double implementing [RendererApi].
final rendererApiProvider = Provider<RendererApi>((ref) => FrbRendererApi());

/// Longest-edge cap (physical pixels) for the Android render surface.
///
/// Live2D rendering is heavily alpha-blended and fragment-bound on mobile
/// GPUs; rendering at full panel resolution (1080x2400+) wastes bandwidth
/// on low-end devices. The SurfaceTexture buffer is capped to this edge
/// and the compositor upscales for free.
const int kMaxAndroidRenderEdge = 1600;

/// Scale [width]x[height] down (preserving aspect) so the longer edge does
/// not exceed [maxEdge]. Returns the input unchanged when already within
/// the cap. Pure function — callers gate on `Platform.isAndroid`.
(int, int) capRenderSize(
  int width,
  int height, {
  int maxEdge = kMaxAndroidRenderEdge,
}) {
  final longEdge = width > height ? width : height;
  if (longEdge <= maxEdge) return (width, height);
  final scale = maxEdge / longEdge;
  return ((width * scale).round(), (height * scale).round());
}

/// State notifier owning the renderer lifecycle.
class RendererNotifier extends StateNotifier<RendererState> {
  RendererNotifier(this._api, this._ref) : super(const RendererState());

  final RendererApi _api;
  final Ref _ref;
  StreamSubscription<FrameEvent>? _frameSub;

  /// Whether the current frame loop renders to an Android SurfaceTexture
  /// (direct Vulkan surface) rather than the Windows D3D12 shared-texture
  /// offscreen path. When true, `_onFrameUpdated` skips the Windows-only
  /// register/markFrameAvailable logic.
  bool _isAndroidSurface = false;

  /// Last logical surface size reported via [setWindowSize]. Used to size
  /// the Android SurfaceTexture when the frame loop starts before any
  /// layout callback has fired.
  (int, int)? _lastSize;

  // Pan coalescing: onPanUpdate can fire far faster than the 60Hz render
  // loop samples the gesture, and each raw FRB panDelta call contends with
  // the render thread for the renderer mutex. We accumulate deltas and keep
  // only one panDelta call in flight at a time; incoming deltas sum while a
  // call is pending and are flushed together when it completes. Rust applies
  // pan as translate += delta, so summing then sending once is identical to
  // sending each delta separately, but with far less boundary traffic and
  // lock contention.
  double _pendingPanDx = 0;
  double _pendingPanDy = 0;
  int _panSurfaceW = 0;
  int _panSurfaceH = 0;
  bool _panFlushing = false;

  // Zoom coalescing: same scheme as pan, but zoom composes
  // multiplicatively (Rust applies scale *= factor), so pending factors
  // multiply into a product and flush as one call.
  double _pendingZoomFactor = 1.0;
  bool _zoomFlushing = false;

  // FPS measurement: count Updated events per 1-second window and
  // publish the result to state once per second (1 rebuild/s, not 60).
  int _fpsFrames = 0;
  final Stopwatch _fpsClock = Stopwatch();

  // Frame-event coalescing: stream.listen does not await async
  // callbacks, so without a guard, Updated events arriving faster than
  // markFrameAvailable can complete would pile up concurrent platform
  // channel calls and display stale frames (the model lagging behind
  // the finger during drags). We keep only one markFrameAvailable in
  // flight at a time; frames that arrive while one is pending set a
  // flag and are flushed as a single follow-up mark for the latest
  // frame. The first-frame register call is separately guarded so two
  // Updated events can't race a duplicate register.
  bool _frameInFlight = false;
  bool _frameQueued = false;
  bool _registering = false;

  /// Consecutive duplicate Failed frame events since the last state
  /// change; used to throttle the debugPrint to one line per 60
  /// duplicates while `_onFrameEvent` skips redundant state writes.
  int _failedLogCount = 0;

  /// The `nativeHandle` of the [SharedTextureHandle] that is currently
  /// registered with Flutter's [TextureRegistrar]. `null` before the
  /// first frame registers, and after the loop is stopped.
  ///
  /// The Rust offscreen texture is rebuilt whenever `setWindowSize`
  /// changes its dimensions, and each rebuild exports a *new* NT
  /// handle. Without tracking this value we would register only the
  /// first handle and silently keep Flutter pointing at a freed
  /// texture after every resize — see the `0c05356` revert.
  BigInt? _registeredNativeHandle;

  /// Shadow of `state.textureId` for teardown paths that run after
  /// dispose(), where reading `state` is illegal.
  int? _registeredTextureId;

  // Dart-side frame-pacing profiler, gated by the L2D_PROFILE env var.
  // Prints periodic stats via debugPrint so they show in the `flutter run`
  // console (native Rust stderr does not surface there for a GUI process).
  // Measures the interval between successive frames as delivered to Dart
  // (reflecting the Rust frame-loop pacing) and the markFrameAvailable cost.
  static final bool _profile = _readProfileFlag();
  static bool _readProfileFlag() {
    try {
      return (Platform.environment['L2D_PROFILE'] ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  final Stopwatch _profClock = Stopwatch();
  int _profFrames = 0;
  double _profIntervalSum = 0;
  double _profIntervalMax = 0;
  double _profMarkSum = 0;
  double _profMarkMax = 0;
  int? _profLastFrameMicros;

  /// Initialize the renderer. Idempotent.
  Future<void> initialize() async {
    if (state.isInitialized) return;
    debugLog('[renderer] initialize: starting');
    state = state.copyWith(status: RendererStatus.loading, clearError: true);
    try {
      await _api.initialize();
      debugLog('[renderer] initialize: OK');
      state = state.copyWith(isInitialized: true, status: RendererStatus.idle);
    } catch (e) {
      debugLog('[renderer] initialize: FAILED: $e');
      state = state.copyWith(
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    }
  }

  /// Persist the current model's gesture state to disk.
  ///
  /// [flushToDisk] bypasses the debounce so the write completes before
  /// the app exits (used from [dispose]); normal calls stay debounced.
  Future<void> saveCurrentGesture({bool flushToDisk = false}) async {
    final modelPath = state.currentModelPath;
    if (modelPath == null || !state.isModelLoaded) return;
    final SettingsRepo? settings;
    try {
      settings = _ref.read(settingsRepoProvider).valueOrNull;
    } catch (_) {
      return;
    }
    if (settings == null) return;
    try {
      final (sx, sy, tx, ty) = await _api.getGestureState();
      settings.modelGestures[modelPath] = [sx, sy, tx, ty];
      if (flushToDisk) {
        await settings.flush();
      } else {
        await settings.save();
      }
    } catch (e) {
      // Best effort — don't surface persistence errors to the UI, but
      // never swallow them silently either (AGENTS.md: save() failures
      // must be observable).
      debugLog(
        '[renderer] saveCurrentGesture failed for '
        '${pathBasename(modelPath)}: ${e.runtimeType}',
      );
    }
  }

  /// Load a model from [path] and refresh motion groups.
  Future<void> loadModel(String path) async {
    debugLog('[renderer] loadModel: ${pathBasename(path)}');
    await saveCurrentGesture();
    state = state.copyWith(status: RendererStatus.loading, clearError: true);
    try {
      final result = await _api.loadModel(path);
      debugLog(
        '[renderer] loadModel: OK, ${result.motionGroups.length} motion groups',
      );
      state = state.copyWith(
        isModelLoaded: true,
        currentModelPath: path,
        motionGroups: result.motionGroups,
        status: RendererStatus.ready,
        clearError: true,
      );
      await _restoreGesture(path);
    } catch (e) {
      debugLog('[renderer] loadModel: FAILED: ${e.runtimeType}');
      state = state.copyWith(
        isModelLoaded: false,
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    }
  }

  Future<void> _restoreGesture(String path) async {
    try {
      await _api.resetGesture();
    } catch (_) {
      return;
    }
    final settings = _ref.read(settingsRepoProvider).valueOrNull;
    if (settings == null) return;
    final saved = settings.modelGestures[path];
    if (saved == null || saved.length != 4) return;
    try {
      await _api.setGestureState(saved[0], saved[1], saved[2], saved[3]);
    } catch (_) {
      // Best effort.
    }
  }

  /// Trigger a motion by [group] id.
  Future<void> triggerMotion(String group) async {
    try {
      await _api.triggerMotion(group);
    } catch (e) {
      state = state.copyWith(
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    }
  }

  /// Reset pan/zoom gesture state.
  Future<void> resetGesture() async {
    try {
      await _api.resetGesture();
    } catch (e) {
      state = state.copyWith(
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    }
  }

  /// Send a tap at the current pointer.
  Future<void> tap() async {
    try {
      await _api.tap();
    } catch (e) {
      state = state.copyWith(
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    }
  }

  /// Apply a zoom [factor].
  ///
  /// Factors are coalesced like [panDelta]: while one FRB zoom call is
  /// in flight, further factors multiply into a pending product and are
  /// sent as a single call when the in-flight one completes. This caps
  /// boundary crossings to the FRB round-trip rate instead of the
  /// scroll-wheel event rate.
  Future<void> zoom(double factor) async {
    _pendingZoomFactor *= factor;
    if (_zoomFlushing) return;

    _zoomFlushing = true;
    try {
      while (_pendingZoomFactor != 1.0) {
        final flushFactor = _pendingZoomFactor;
        _pendingZoomFactor = 1.0;
        await _api.zoom(flushFactor);
      }
    } catch (e) {
      state = state.copyWith(
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    } finally {
      _zoomFlushing = false;
    }
  }

  /// Begin a pan gesture.
  Future<void> panStart() async {
    _pendingPanDx = 0;
    _pendingPanDy = 0;
    try {
      await _api.panStart();
    } catch (e) {
      state = state.copyWith(
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    }
  }

  /// Apply a pan delta in surface coordinates.
  ///
  /// Deltas are coalesced: while one FRB panDelta call is in flight, any
  /// further deltas accumulate and are sent as a single summed call when
  /// the in-flight one completes. This caps boundary crossings to the FRB
  /// round-trip rate instead of the pointer event rate.
  Future<void> panDelta(
    double dx,
    double dy,
    int surfaceW,
    int surfaceH,
  ) async {
    final sensitivity = Platform.isAndroid ? 2.0 : 1.0;
    _pendingPanDx += dx * sensitivity;
    _pendingPanDy += dy * sensitivity;
    _panSurfaceW = surfaceW;
    _panSurfaceH = surfaceH;
    if (_panFlushing) return;

    _panFlushing = true;
    try {
      while (_pendingPanDx != 0 || _pendingPanDy != 0) {
        final flushDx = _pendingPanDx;
        final flushDy = _pendingPanDy;
        _pendingPanDx = 0;
        _pendingPanDy = 0;
        await _api.panDelta(flushDx, flushDy, _panSurfaceW, _panSurfaceH);
      }
    } catch (e) {
      state = state.copyWith(
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    } finally {
      _panFlushing = false;
    }
  }

  /// End a pan gesture.
  Future<void> panEnd() async {
    try {
      await _api.panEnd();
    } catch (e) {
      state = state.copyWith(
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    }
  }

  /// Notify the renderer of a surface resize.
  Future<void> resize(int width, int height) async {
    try {
      await _api.resize(width, height);
    } catch (e) {
      state = state.copyWith(
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    }
  }

  /// Notify the renderer of a logical window size change for the
  /// offscreen render path.
  Future<void> setWindowSize(int width, int height) async {
    _lastSize = (width, height);
    try {
      await _api.setWindowSize(width, height);
    } catch (e) {
      state = state.copyWith(
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    }
  }

  /// Apply a frame-rate cap (fps, 0 = unlimited) to the render loop.
  ///
  /// Only stores an atomic on the Rust side (read once per tick), so it
  /// takes effect live on a running loop and does not touch the surface /
  /// frame-loop lifecycle — no need to serialize through the lifecycle
  /// chain. Best-effort: a failure here (e.g. renderer not yet initialized)
  /// must not disrupt the viewer, so it is logged rather than surfaced as a
  /// renderer error.
  Future<void> setTargetFps(int fps) async {
    try {
      await _api.setTargetFps(fps);
    } catch (e) {
      debugLog('[renderer] setTargetFps($fps) failed: $e');
    }
  }

  /// Start the 60Hz frame loop.
  ///
  /// On every [FrameEvent.updated] the notifier:
  ///   * registers the new shared texture with the Windows runner via
  ///     [TextureMethodChannel.register] (only on the very first
  ///     Updated event — the texture ID is reused for subsequent frames),
  ///   * calls [TextureMethodChannel.markFrameAvailable] to flush the
  ///     new pixel data to Flutter (this repaints the [Texture] at the
  ///     engine level without a Dart rebuild),
  ///   * sets [RendererState.frameCount] to 1 on the first registered
  ///     frame only — later frames do not mutate state, so the widget
  ///     tree is not rebuilt ~60x/sec.
  ///
  /// On [FrameEvent.failed] the error is surfaced via
  /// [RendererState.errorMessage] but the loop keeps running.
  ///
  /// Serialized with [stopFrameLoop] / [detachAndroidSurface] /
  /// [reattachAndroidSurface] via [_lifecycleChain]: on Android the
  /// surface create path releases the previous ANativeWindow on the
  /// Kotlin side, so it must never interleave with an in-flight
  /// stop/detach that is still presenting to that window (probabilistic
  /// native SIGSEGV in the Vulkan driver).
  Future<void> startFrameLoop() {
    return _enqueueLifecycle(_startFrameLoopInner);
  }

  Future<void> _startFrameLoopInner() async {
    if (!mounted || state.isFrameLoopRunning) return;
    debugLog(
      '[renderer] startFrameLoop: starting, textureId=${state.textureId}, isAndroid=${Platform.isAndroid}',
    );
    // Preserve any errorMessage set by a prior loadModel failure:
    // ViewerPage calls startFrameLoop right after loadModel, and
    // clearing the error here would surface 'unknown error' instead
    // of the real cause in the error banner.
    state = state.copyWith(isFrameLoopRunning: true);

    if (Platform.isAndroid && state.textureId == null) {
      debugLog('[renderer] startFrameLoop: creating Android surface');
      try {
        await _createAndroidSurface();
        // install_android_surface replaces the entire wgpu device,
        // invalidating all GPU resources created during the earlier
        // loadModel call. Reload so textures/meshes are rebuilt on the
        // new device (same pattern as reattachAndroidSurface).
        final modelPath = state.currentModelPath;
        if (modelPath != null) {
          debugLog(
            '[renderer] startFrameLoop: reloading model after surface creation',
          );
          await loadModel(modelPath);
        }
      } catch (e) {
        debugLog(
          '[renderer] startFrameLoop: Android surface creation FAILED: $e',
        );
        state = state.copyWith(
          status: RendererStatus.error,
          errorMessage:
              'Android surface creation failed: ${_rendererErrorText(e)}',
          isFrameLoopRunning: false,
        );
        return;
      }
    }

    debugLog('[renderer] startFrameLoop: subscribing to frame stream');
    // Honor the persisted FPS cap on every loop start (the Rust default is
    // 60fps; a user who picked 30/120/Unlimited must not silently revert on
    // a fresh loop). Read the already-loaded settings synchronously.
    final fps = _ref.read(settingsRepoProvider).valueOrNull?.targetFps ?? 60;
    await _api.setTargetFps(fps);
    final stream = _api.startFrameLoop();
    _frameSub = stream.listen(
      _onFrameEvent,
      onError: (Object e) {
        state = state.copyWith(
          status: RendererStatus.error,
          errorMessage: _rendererErrorText(e),
          isFrameLoopRunning: false,
        );
      },
      onDone: () {
        // Stream closed (Dart cancelled or Rust worker exited).
        state = state.copyWith(isFrameLoopRunning: false);
      },
      cancelOnError: true,
    );
  }

  /// Create the Android SurfaceTexture, attach it to the renderer as a
  /// Vulkan surface, and publish the resulting Flutter texture id.
  Future<void> _createAndroidSurface() async {
    final (rawW, rawH) = _lastSize ?? _defaultScreenSize();
    final (w, h) = capRenderSize(rawW, rawH);
    debugLog('[renderer] _createAndroidSurface: ${w}x$h (raw ${rawW}x$rawH)');
    final result = await TextureAndroidChannel.instance.create(w, h);
    debugLog(
      '[renderer] _createAndroidSurface: textureId=${result.textureId}, nativeWindow=${result.nativeWindow}',
    );
    await _api.attachSurface(result.nativeWindow, w, h);
    debugLog('[renderer] _createAndroidSurface: attachSurface OK');
    _isAndroidSurface = true;
    _registeredTextureId = result.textureId;
    state = state.copyWith(textureId: result.textureId, frameCount: 0);
  }

  (int, int) _defaultScreenSize() {
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final size = view.physicalSize;
      if (size.width > 0 && size.height > 0) {
        return (size.width.round(), size.height.round());
      }
    } catch (_) {}
    return (1080, 1920);
  }

  /// Detach the Android rendering surface when the app is paused or
  /// becomes inactive.
  ///
  /// The frame loop is stopped FIRST so the render thread is not
  /// mid-frame when the surface disappears. Without this ordering the
  /// loop falls into the Windows offscreen path (always fails on
  /// Android) and spams error state until the app resumes.
  ///
  /// Serialized with [reattachAndroidSurface] via [_lifecycleChain]: a
  /// rapid inactive→resumed sequence must never interleave a detach
  /// with an in-flight reattach (device swap mid-operation is the
  /// postmortem-documented Android UB zone).
  Future<void> detachAndroidSurface() {
    return _enqueueLifecycle(_detachAndroidSurfaceInner);
  }

  Future<void> _detachAndroidSurfaceInner() async {
    if (!_isAndroidSurface) return;
    final sub = _frameSub;
    _frameSub = null;
    await sub?.cancel();
    try {
      await _api.stopFrameLoop();
    } catch (_) {}
    try {
      await _api.detachSurface();
    } catch (_) {
      // Best effort — the surface is being torn down by the platform.
    }
    if (mounted) {
      state = state.copyWith(isFrameLoopRunning: false);
    }
  }

  /// Re-create the Android rendering surface after the app resumes.
  ///
  /// `install_android_surface` replaces the entire wgpu device/queue,
  /// invalidating all previously created GPU resources (textures, meshes,
  /// clipping). We must reload the model afterwards so its resources are
  /// recreated on the new device, then restart the frame loop.
  ///
  /// Serialized with [detachAndroidSurface] via [_lifecycleChain].
  Future<void> reattachAndroidSurface() {
    return _enqueueLifecycle(_reattachAndroidSurfaceInner);
  }

  Future<void> _reattachAndroidSurfaceInner() async {
    if (!_isAndroidSurface) return;
    try {
      await _createAndroidSurface();
      final modelPath = state.currentModelPath;
      if (modelPath != null) {
        await loadModel(modelPath);
      }
      // Already inside the lifecycle chain — calling the public
      // startFrameLoop() would enqueue behind ourselves and deadlock.
      await _startFrameLoopInner();
    } catch (_) {
      // Best effort — a subsequent resume/layout pass can retry.
    }
  }

  /// Chain of Android lifecycle operations. Each detach/reattach runs
  /// only after the previous one has fully completed, regardless of how
  /// fast the OS fires lifecycle transitions.
  Future<void> _lifecycleChain = Future<void>.value();

  Future<void> _enqueueLifecycle(Future<void> Function() op) {
    final next = _lifecycleChain.catchError((Object _) {}).then((_) => op());
    _lifecycleChain = next;
    return next;
  }

  /// Stop the frame loop and unregister the texture.
  ///
  /// Serialized with [startFrameLoop] / [detachAndroidSurface] /
  /// [reattachAndroidSurface] via [_lifecycleChain] — see
  /// [startFrameLoop] for the Android ANativeWindow race rationale.
  Future<void> stopFrameLoop() {
    return _enqueueLifecycle(_stopFrameLoopInner);
  }

  Future<void> _stopFrameLoopInner() async {
    // Capture before any await: dispose()-driven teardown continues
    // after the notifier is unmounted, where reading `state` throws.
    final textureId = mounted ? state.textureId : _registeredTextureId;
    final sub = _frameSub;
    _frameSub = null;
    await sub?.cancel();

    // Stop the Rust frame loop BEFORE unregistering the Flutter texture.
    // The Rust worker can still call ObtainDescriptor / present a frame
    // after the Dart FrameEvent subscription is cancelled; if we
    // unregister first, the platform thread tears down the TextureLayer
    // (UnregisterTexture + texture_variant_.reset()) while the raster
    // thread is mid-paint on that same layer — the engine then throws an
    // uncaught std::future_error across a noexcept boundary → terminate
    // → fastfail c0000409 (the probabilistic teardown crash). Stopping
    // the Rust loop first guarantees no new paint races the unregister.
    try {
      await _api.stopFrameLoop();
    } catch (_) {
      // Best effort.
    }

    if (textureId != null && !Platform.isAndroid) {
      try {
        await TextureMethodChannel.instance.unregister(textureId);
      } catch (_) {
        // Best effort — the texture is being torn down anyway.
      }
    }

    if (_isAndroidSurface) {
      try {
        await _api.detachSurface();
      } catch (_) {
        // Best effort — the surface is being torn down anyway.
      }
      try {
        await TextureAndroidChannel.instance.destroy();
      } catch (_) {
        // Best effort.
      }
      _isAndroidSurface = false;
    }

    _registeredNativeHandle = null;
    _registeredTextureId = null;
    _fpsFrames = 0;
    _fpsClock.reset();
    if (mounted) {
      state = state.copyWith(
        isFrameLoopRunning: false,
        clearTextureId: true,
        frameCount: 0,
        fps: 0,
      );
    }
  }

  void _onFrameEvent(FrameEvent event) {
    event.when(
      initial: (width, height) {
        debugLog('[renderer] frameEvent: initial ${width}x$height');
      },
      updated: (handle) => _onFrameUpdated(handle),
      failed: (message) {
        // Dedup: the Rust side already throttles identical Failed events,
        // but a re-emit (every ~60 ticks for a persistent failure) must
        // not rebuild the whole page when nothing changed.
        final isDuplicate =
            state.status == RendererStatus.error &&
            state.errorMessage == message;
        _failedLogCount = isDuplicate ? _failedLogCount + 1 : 0;
        if (_failedLogCount % 60 == 0) {
          debugLog(
            '[renderer] frameEvent: FAILED: $message'
            '${_failedLogCount > 0 ? ' (repeated x$_failedLogCount)' : ''}',
          );
        }
        if (isDuplicate) return;
        state = state.copyWith(
          status: RendererStatus.error,
          errorMessage: message,
        );
      },
      // Surface attached but Stage cleared (Android device swap, mid-reload):
      // skip the tick silently instead of surfacing a 60Hz error banner.
      idle: () {},
    );
  }

  Future<void> _onFrameUpdated(SharedTextureHandle handle) async {
    // FPS measurement: count every Updated event; publish once/second.
    if (!_fpsClock.isRunning) _fpsClock.start();
    _fpsFrames++;
    if (_fpsClock.elapsedMilliseconds >= 1000) {
      final fps = _fpsFrames;
      _fpsFrames = 0;
      _fpsClock.reset();
      // Skip the publish when the value is unchanged: at a steady
      // frame rate this would otherwise rebuild every rendererProvider
      // listener once per second for no visible change.
      if (mounted && state.fps != fps) state = state.copyWith(fps: fps);
    }

    // Android renders directly to a SurfaceTexture-backed Vulkan surface;
    // there is no D3D12 shared handle to register or mark. Just flip
    // frameCount once so the Texture widget becomes visible, then skip
    // the Windows-only register/markFrameAvailable path below.
    //
    // Defense in depth: gate on `Platform.isAndroid` in addition to
    // `_isAndroidSurface`. If `_createAndroidSurface` failed midway
    // and left `_isAndroidSurface = false` while the frame loop is
    // already ticking, the Rust side still emits `Updated(handle=0)`
    // for the Android path (see `frb_api.rs` frame_loop Android branch).
    // Without this platform check, `_onFrameUpdated` would fall through
    // to the Windows register path with `native_handle = 0`, silently
    // failing and leaving the model invisible. The platform check is a
    // stable invariant; `_isAndroidSurface` is mutable state that can
    // race with surface creation.
    if (Platform.isAndroid || _isAndroidSurface) {
      if (state.frameCount == 0) {
        state = state.copyWith(frameCount: 1);
      }
      return;
    }

    // The offscreen D3D12 texture is rebuilt whenever `setWindowSize`
    // changes its dimensions, and each rebuild mints a brand-new NT
    // handle (see `SharedOffscreenTexture::new`). The first Updated
    // event registers the handle; subsequent Updated events that
    // carry a *different* `nativeHandle` mean the texture was
    // reallocated, so we unregister the old texture ID and register
    // the new one — otherwise Flutter keeps pointing at the freed
    // texture and the model freezes (the `0c05356` revert cause).
    final incoming = handle.nativeHandle;
    final needsRegister =
        state.textureId == null &&
        !_registering &&
        _registeredNativeHandle == null;
    final needsReregister =
        _registeredNativeHandle != null &&
        incoming != _registeredNativeHandle &&
        !_registering;
    if (needsRegister || needsReregister) {
      _registering = true;
      try {
        // First registration mints the Flutter texture id; a later
        // handle change (resize reallocated the D3D12 texture) swaps the
        // NT handle IN PLACE via `update`, keeping the same texture id.
        // We must never unregister+register on resize: tearing down the
        // TextureLayer on the platform thread while the raster thread
        // paints it makes the engine abort (uncaught std::future_error
        // across a noexcept boundary — the probabilistic resize crash).
        final int id;
        if (needsReregister) {
          id = await TextureMethodChannel.instance.update(handle);
        } else {
          id = await TextureMethodChannel.instance.register(handle);
        }
        if (id < 0) {
          // Leave _registeredNativeHandle unset so the next Updated
          // event retries the registration instead of latching a
          // permanently invalid texture id.
          _registeredTextureId = null;
          state = state.copyWith(
            status: RendererStatus.error,
            errorMessage: 'texture register returned invalid id: $id',
            clearTextureId: true,
          );
          return;
        }
        _registeredNativeHandle = incoming;
        _registeredTextureId = id;
        state = state.copyWith(textureId: id, frameCount: 1);
      } catch (e) {
        state = state.copyWith(
          status: RendererStatus.error,
          errorMessage: 'texture register failed: ${_rendererErrorText(e)}',
        );
        return;
      } finally {
        _registering = false;
      }
    }
    final textureId = state.textureId;
    if (textureId == null || textureId < 0) return;

    // Coalesce markFrameAvailable: only one in flight at a time. If a
    // new frame arrives while one is pending, set _frameQueued and the
    // in-flight call will do one follow-up mark for the latest frame.
    // Without this, drag-time Updated events would queue stale
    // markFrameAvailable calls and the model would lag the finger.
    //
    // Each iteration re-reads state.textureId: a re-register triggered
    // by a later Updated event swaps the id out from under us, and the
    // follow-up mark must target the *new* texture id rather than the
    // stale one captured at function entry.
    if (_frameInFlight) {
      _frameQueued = true;
      return;
    }
    _frameInFlight = true;
    try {
      do {
        _frameQueued = false;
        final currentId = state.textureId;
        if (currentId == null || currentId < 0) break;
        if (_profile) {
          if (!_profClock.isRunning) _profClock.start();
          final nowMicros = _profClock.elapsedMicroseconds;
          final last = _profLastFrameMicros;
          if (last != null) {
            final intervalMs = (nowMicros - last) / 1000.0;
            _profIntervalSum += intervalMs;
            if (intervalMs > _profIntervalMax) _profIntervalMax = intervalMs;
          }
          _profLastFrameMicros = nowMicros;
        }
        final markStart = _profile ? _profClock.elapsedMicroseconds : 0;
        try {
          await TextureMethodChannel.instance.markFrameAvailable(currentId);
        } catch (_) {
          // MarkFrameAvailable failure is transient — next tick retries.
        }
        if (_profile) {
          final markMs = (_profClock.elapsedMicroseconds - markStart) / 1000.0;
          _profMarkSum += markMs;
          if (markMs > _profMarkMax) _profMarkMax = markMs;
          _profFrames++;
          if (_profFrames >= 120) {
            final n = _profFrames;
            debugLog(
              '[L2D_PROFILE] $n frames | delivery interval avg '
              '${(_profIntervalSum / n).toStringAsFixed(2)}ms max '
              '${_profIntervalMax.toStringAsFixed(2)}ms | markFrameAvailable '
              'avg ${(_profMarkSum / n).toStringAsFixed(2)}ms max '
              '${_profMarkMax.toStringAsFixed(2)}ms',
            );
            _profFrames = 0;
            _profIntervalSum = 0;
            _profIntervalMax = 0;
            _profMarkSum = 0;
            _profMarkMax = 0;
          }
        }
      } while (_frameQueued);
    } finally {
      _frameInFlight = false;
    }
  }

  /// Clear the current error and return to the idle/ready state.
  ///
  /// Used by the viewer page's error banner Dismiss action. If a model is
  /// loaded, the status returns to [RendererStatus.ready]; otherwise it
  /// returns to [RendererStatus.idle].
  void clearError() {
    if (state.status != RendererStatus.error) return;
    state = state.copyWith(
      status: state.isModelLoaded ? RendererStatus.ready : RendererStatus.idle,
      clearError: true,
    );
  }

  /// Refresh motion groups from the renderer.
  Future<void> refreshMotionGroups() async {
    try {
      final groups = await _api.getMotionGroups();
      state = state.copyWith(motionGroups: groups);
    } catch (e) {
      state = state.copyWith(
        status: RendererStatus.error,
        errorMessage: _rendererErrorText(e),
      );
    }
  }

  @override
  void dispose() {
    // Fire-and-forget teardown: dispose() must complete synchronously
    // so Riverpod can drop the notifier immediately. The gesture flush
    // and frame-loop stop continue in the background; state writes
    // after this point are blocked by `mounted` guards.
    final teardown = saveCurrentGesture(
      flushToDisk: true,
    ).then((_) => stopFrameLoop());
    unawaited(
      teardown.catchError((Object e) {
        debugLog('[renderer] dispose teardown failed: $e');
      }),
    );
    super.dispose();
  }
}

/// Provider for the renderer state.
final rendererProvider = StateNotifierProvider<RendererNotifier, RendererState>(
  (ref) {
    return RendererNotifier(ref.watch(rendererApiProvider), ref);
  },
);
