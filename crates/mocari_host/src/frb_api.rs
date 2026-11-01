use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Instant;

use crate::error::{HostError, RenderErrorKind};
use crate::frb_generated::StreamSink;
#[cfg(target_os = "android")]
use crate::render::device::RenderContext;
use crate::render::frame_driver::{FrameDriver, FrameEvent};
use crate::render::gesture::GestureSlot;
use crate::render::renderer::{Live2dRenderer, ModelInfo};
use crate::render::texture_export::SharedTextureHandle;

/// Convert an FPS cap into the frame-loop's per-frame interval in
/// microseconds. `fps == 0` maps to `0` ("unlimited" — the worker skips the
/// inter-frame sleep); any other value maps to `1_000_000 / fps`, clamped to
/// at least 1µs so an absurdly high cap never produces a zero interval that
/// would be mistaken for "unlimited".
fn fps_to_frame_micros(fps: u32) -> u32 {
    match 1_000_000u32.checked_div(fps) {
        // `fps == 0` → unlimited: the worker skips the inter-frame sleep.
        None => 0,
        Some(micros) => micros.max(1),
    }
}

/// Thread-safe handle to a [`Live2dRenderer`] intended for the Flutter-Rust
/// bridge control surface.
///
/// All methods take `&self` so the handle can be shared across isolates
/// and wrapped by generated FRB bindings without requiring `&mut` access.
pub struct RendererHandle {
    renderer: Arc<Mutex<Live2dRenderer>>,
    /// Shared gesture slot — the same `Arc<Mutex<GestureSlot>>` stored on
    /// the renderer. Gesture ops (pan/zoom/reset) lock *only* this mutex,
    /// not the renderer mutex, so input doesn't stall behind the 60Hz
    /// `render_to_texture` mutex hold. The render loop reads from this
    /// slot briefly inside `update_composite_transform`.
    gesture: Arc<Mutex<GestureSlot>>,
    /// Stop flag shared with the `start_frame_loop` worker thread.
    /// Cleared by `start_frame_loop`, set by `stop_frame_loop`.
    frame_loop_stop: Arc<AtomicBool>,
    /// JoinHandle for the frame loop worker thread. Stored so
    /// `stop_frame_loop` can join the thread (preventing leaks) and
    /// `start_frame_loop` can join a previous thread before spawning
    /// a new one.
    frame_loop_thread: Mutex<Option<JoinHandle<()>>>,
    /// Target frame interval in microseconds for the `start_frame_loop`
    /// worker. Read once per tick, so `set_target_fps` takes effect on a
    /// running loop without restarting it. `0` means "unlimited" — the
    /// worker skips the inter-frame sleep entirely. Default: 16_666µs
    /// (60fps).
    target_frame_micros: Arc<AtomicU32>,
}

impl RendererHandle {
    pub fn new(renderer: Live2dRenderer) -> Self {
        // Clone the gesture Arc before moving the renderer into its own
        // Arc<Mutex<_>>. Both then point at the same GestureSlot.
        let gesture = renderer.gesture.clone();
        Self {
            renderer: Arc::new(Mutex::new(renderer)),
            gesture,
            frame_loop_stop: Arc::new(AtomicBool::new(false)),
            frame_loop_thread: Mutex::new(None),
            target_frame_micros: Arc::new(AtomicU32::new(16_666)),
        }
    }

    /// Create a new headless renderer (no window/surface) wrapped in a handle.
    pub async fn new_headless() -> Result<Self, HostError> {
        #[cfg(target_os = "android")]
        {
            android_logger::init_once(
                android_logger::Config::default()
                    .with_max_level(log::LevelFilter::Debug)
                    .with_tag("mocari_host"),
            );
        }
        log::info!("[live2d] new_headless: creating headless renderer");
        let renderer = Live2dRenderer::new_headless().await?;
        log::info!("[live2d] new_headless: headless renderer created OK");
        Ok(Self::new(renderer))
    }

    /// Returns `Err(String)` (not `HostError`) deliberately: `HostError`
    /// crosses FRB as an opaque `RustOpaqueInterface` — Dart sees only
    /// `Instance of 'HostErrorImpl'` with no message. Load failures are
    /// user-facing (error banner in the Viewer), so the display string
    /// must survive the bridge.
    pub fn load_model(&self, path: String) -> Result<ModelInfo, String> {
        log::info!("[live2d] load_model called with path: {path}");
        let mut renderer = self.renderer.lock().unwrap_or_else(|e| {
            log::error!("[live2d] load_model: recovering from poisoned mutex");
            e.into_inner()
        });
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            renderer.load_model(Path::new(&path))
        }));
        match result {
            Ok(Ok(info)) => {
                log::info!(
                    "[live2d] load_model succeeded: {} motion groups",
                    info.motion_groups.len()
                );
                Ok(info)
            }
            Ok(Err(e)) => {
                log::error!("[live2d] load_model error: {e}");
                Err(format!("{e}"))
            }
            Err(panic_info) => {
                let msg = if let Some(s) = panic_info.downcast_ref::<String>() {
                    s.clone()
                } else if let Some(s) = panic_info.downcast_ref::<&str>() {
                    s.to_string()
                } else {
                    "unknown panic".into()
                };
                // Per postmortem 2026-07-23 (Android Stage stale): any
                // panic inside `Live2dRenderer::load_model` leaves
                // already-created GPU resources (textures, mesh buffers,
                // clipping resources, mask render target, transform
                // uniform) bound to the current device but unreachable
                // from `self.stage`. They leak until the renderer is
                // dropped. Log explicitly so the leak is visible; the
                // caller should treat this as a fatal renderer error.
                log::error!(
                    "[live2d] load_model PANIC: {msg} — GPU resources \
                     created before the panic may have leaked"
                );
                Err(format!("panic in load_model: {msg}"))
            }
        }
    }

    /// Render the current frame to the off-screen shared D3D12 texture.
    ///
    /// Returns a DTO carrying the NT handle + dimensions suitable for
    /// shipping across the FRB boundary to Dart, which in turn hands
    /// the handle to the Windows `TextureHandler` via
    /// `MethodChannel("live2d_viewer/texture")`. The handle is the
    /// *same cached* NT handle for the lifetime of the offscreen
    /// texture; Rust owns it and closes it when the texture is
    /// rebuilt/dropped. Consumers must `DuplicateHandle` into their own
    /// scope and must never close Rust's original.
    pub fn render_to_texture(&self) -> Result<SharedTextureHandle, HostError> {
        let mut renderer = self.renderer.lock().unwrap_or_else(|e| e.into_inner());
        renderer.render_to_texture()?;
        let offscreen = renderer
            .offscreen_texture
            .as_ref()
            .ok_or(HostError::Render(RenderErrorKind::SurfaceInvalid))?;
        Ok(offscreen.texture_export_handle())
    }

    pub fn tap(&self) -> Result<(), HostError> {
        let mut renderer = self.renderer.lock().unwrap_or_else(|e| e.into_inner());
        renderer.tap();
        Ok(())
    }

    pub fn zoom(&self, factor: f32) -> Result<(), HostError> {
        let mut g = self.gesture.lock().unwrap_or_else(|e| e.into_inner());
        g.zoom(factor);
        Ok(())
    }

    pub fn pan_start(&self) -> Result<(), HostError> {
        let mut g = self.gesture.lock().unwrap_or_else(|e| e.into_inner());
        g.pan_start();
        Ok(())
    }

    pub fn pan_delta(
        &self,
        dx: f32,
        dy: f32,
        surface_w: u32,
        surface_h: u32,
    ) -> Result<(), HostError> {
        let mut g = self.gesture.lock().unwrap_or_else(|e| e.into_inner());
        // GestureSlot caches the fit_scale_x/y refreshed on model load /
        // resize, so we don't need to lock the renderer or read stage
        // fields here — that was what stalled input behind render frames.
        g.pan_delta(dx, dy, surface_w, surface_h);
        Ok(())
    }

    pub fn pan_end(&self) -> Result<(), HostError> {
        let mut g = self.gesture.lock().unwrap_or_else(|e| e.into_inner());
        g.pan_end();
        Ok(())
    }

    pub fn reset_gesture(&self) -> Result<(), HostError> {
        let mut g = self.gesture.lock().unwrap_or_else(|e| e.into_inner());
        g.reset();
        Ok(())
    }

    pub fn get_gesture_state(&self) -> Result<(f32, f32, f32, f32), HostError> {
        let g = self.gesture.lock().unwrap_or_else(|e| e.into_inner());
        Ok((
            g.state.scale_x,
            g.state.scale_y,
            g.state.translate_x,
            g.state.translate_y,
        ))
    }

    pub fn set_gesture_state(
        &self,
        scale_x: f32,
        scale_y: f32,
        translate_x: f32,
        translate_y: f32,
    ) -> Result<(), HostError> {
        let mut g = self.gesture.lock().unwrap_or_else(|e| e.into_inner());
        g.state.scale_x = scale_x;
        g.state.scale_y = scale_y;
        g.state.translate_x = translate_x;
        g.state.translate_y = translate_y;
        Ok(())
    }

    pub fn get_motion_groups(&self) -> Result<Vec<String>, HostError> {
        let renderer = self.renderer.lock().unwrap_or_else(|e| e.into_inner());
        Ok(renderer.get_motion_groups())
    }

    pub fn trigger_motion(&self, group: String) -> Result<(), HostError> {
        let mut renderer = self.renderer.lock().unwrap_or_else(|e| e.into_inner());
        renderer.trigger_motion(&group);
        Ok(())
    }

    pub fn resize(&self, width: u32, height: u32) -> Result<(), HostError> {
        let mut renderer = self.renderer.lock().unwrap_or_else(|e| e.into_inner());
        renderer.resize(width, height);
        Ok(())
    }

    pub fn set_fit_center(&self, center: Option<(f32, f32)>) -> Result<(), HostError> {
        let mut renderer = self.renderer.lock().unwrap_or_else(|e| e.into_inner());
        renderer.set_fit_center(center);
        Ok(())
    }

    /// Set the logical window size for the offscreen render path.
    ///
    /// This is the headless/offscreen equivalent of `resize`: it updates
    /// the renderer's `offscreen_size` so subsequent `render_to_texture`
    /// calls allocate a shared D3D12 texture of the requested dimensions.
    /// Call this once after `load_model` (or whenever the Flutter window
    /// size changes) so the frame loop publishes correctly sized frames.
    pub fn set_window_size(&self, width: u32, height: u32) -> Result<(), HostError> {
        let mut renderer = self.renderer.lock().unwrap_or_else(|e| e.into_inner());
        renderer.set_window_size(width, height);
        Ok(())
    }

    /// Set the background clear color (RGBA, each component 0.0–1.0).
    pub fn set_clear_color(&self, r: f64, g: f64, b: f64, a: f64) -> Result<(), HostError> {
        let mut renderer = self.renderer.lock().unwrap_or_else(|e| e.into_inner());
        renderer.set_clear_color(r, g, b, a);
        Ok(())
    }

    /// Attach an Android rendering surface from a raw ANativeWindow pointer.
    ///
    /// This method is only functional on Android. On other platforms it
    /// returns an error. The signature is unconditional so that FRB codegen
    /// (which parses source, not compiled output) always generates the Dart
    /// binding; the Dart caller is responsible for only invoking it on Android.
    pub async fn attach_surface(
        &self,
        window_ptr: u64,
        width: u32,
        height: u32,
    ) -> Result<(), HostError> {
        #[cfg(target_os = "android")]
        {
            log::info!("[live2d] attach_surface: window_ptr={window_ptr:#x} {width}x{height}");
            // Do all async work (instance + adapter + device + surface
            // creation) OUTSIDE the renderer lock. `std::sync::MutexGuard`
            // is not `Send`, so holding the lock across `.await` breaks
            // FRB's `wrap_async` bound. We build the full bundle here,
            // then briefly lock the renderer to install it.
            let (ctx, surface, config, format) =
                RenderContext::new_with_android_window(window_ptr, width, height).await?;
            log::info!("[live2d] attach_surface: RenderContext created, format={format:?}");

            // Poisoned-mutex policy is uniform across all entry points
            // (see frame loop / set_window_size): recover via
            // `into_inner` — the inner renderer value is preserved, and
            // failing the attach here would strand the Dart lifecycle
            // chain with no surface after an unrelated panic.
            let mut renderer = self.renderer.lock().unwrap_or_else(|e| e.into_inner());
            renderer.install_android_surface(ctx, surface, config, format, width, height);
            log::info!("[live2d] attach_surface: installed OK");
            Ok(())
        }
        #[cfg(not(target_os = "android"))]
        {
            let _ = (window_ptr, width, height);
            Err(HostError::Render(RenderErrorKind::Wgpu(
                "attach_surface is only supported on Android".into(),
            )))
        }
    }

    /// Detach the current Android rendering surface.
    ///
    /// This method is only functional on Android. On other platforms it
    /// returns an error. The signature is unconditional so that FRB codegen
    /// (which parses source, not compiled output) always generates the Dart
    /// binding; the Dart caller is responsible for only invoking it on Android.
    pub fn detach_surface(&self) -> Result<(), HostError> {
        #[cfg(target_os = "android")]
        {
            // Same uniform poisoned-mutex recovery as attach_surface:
            // detach runs on the pause path and MUST clear the surface
            // even after a prior lock-holder panic, otherwise the frame
            // loop keeps presenting to a released ANativeWindow.
            let mut renderer = self.renderer.lock().unwrap_or_else(|e| e.into_inner());
            renderer.detach_surface();
            Ok(())
        }
        #[cfg(not(target_os = "android"))]
        {
            Err(HostError::Render(RenderErrorKind::Wgpu(
                "detach_surface is only supported on Android".into(),
            )))
        }
    }

    /// Set the frame-loop FPS cap. `fps == 0` means unlimited (the worker
    /// skips the inter-frame sleep and ticks as fast as it can). Any other
    /// value maps to a per-frame interval of `1_000_000 / fps` microseconds.
    ///
    /// Read once per tick by the `start_frame_loop` worker, so this takes
    /// effect on the next frame of an already-running loop without needing
    /// a restart.
    pub fn set_target_fps(&self, fps: u32) {
        self.target_frame_micros
            .store(fps_to_frame_micros(fps), Ordering::Relaxed);
    }

    /// Start a 60Hz frame loop that pushes [`FrameEvent`]s into `sink`.
    ///
    /// The loop runs on a dedicated worker thread. Each tick locks the
    /// renderer, calls `render_to_texture`, and — on success — emits
    /// `FrameEvent::Updated` carrying the fresh shared NT handle + dimensions.
    /// On error it emits `FrameEvent::Failed` and keeps ticking so transient
    /// GPU failures can self-recover.
    ///
    /// The loop stops when either:
    ///   * Dart cancels the stream (the `sink.add` call returns `Err`),
    ///     in which case the worker thread exits naturally; or
    ///   * `stop_frame_loop` is called, which sets the shared stop flag
    ///     and the worker thread notices on the next tick.
    ///
    /// Calling `start_frame_loop` again on the same handle first stops and
    /// joins the previous worker, then starts a fresh one. The whole
    /// join-old → reset-flag → spawn → store-handle sequence runs inside a
    /// single `frame_loop_thread` critical section, so a concurrent
    /// `stop_frame_loop` can never observe the window where a new worker is
    /// running but its `JoinHandle` is not yet stored (which previously let
    /// `stop_frame_loop` return while the worker was still rendering — a
    /// use-after-free risk against a released `ANativeWindow` on Android).
    pub fn start_frame_loop(&self, sink: StreamSink<FrameEvent>) {
        // Hold the lock for the entire sequence; see doc comment above.
        // On poisoning, recover via `into_inner`. The poisoned `Mutex`
        // still owns its `Option<JoinHandle>` — recovery does NOT drop
        // the inner value, so the previous worker (if any) is still
        // joinable and the upcoming `thread_guard.take()` + `join()` will
        // see it. Poisoning only means a previous lock-holder panicked
        // while holding the lock; the data behind the lock is preserved.
        let mut thread_guard = self
            .frame_loop_thread
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        // Join any previous frame loop thread before starting a new one.
        if let Some(prev) = thread_guard.take() {
            self.frame_loop_stop.store(true, Ordering::Relaxed);
            let _ = prev.join();
        }

        // Reset the stop flag in case a previous loop left it set.
        self.frame_loop_stop.store(false, Ordering::Relaxed);

        let renderer = self.renderer.clone();
        let stop_flag = self.frame_loop_stop.clone();
        let frame_micros = self.target_frame_micros.clone();
        let sink = sink;

        let handle = thread::spawn(move || {
            // Emit Initial once so Dart knows the starting dimensions.
            let (init_w, init_h) = {
                let r = match renderer.lock() {
                    Ok(guard) => guard,
                    Err(poisoned) => {
                        log::warn!("[live2d] frame_loop: recovering from poisoned mutex at init");
                        poisoned.into_inner()
                    }
                };
                r.offscreen_size
                    .or_else(|| r.surface_config.as_ref().map(|c| (c.width, c.height)))
                    .unwrap_or((512, 512))
            };
            if sink
                .add(FrameEvent::Initial {
                    width: init_w,
                    height: init_h,
                })
                .is_err()
            {
                // Dart cancelled the stream before we even started.
                return;
            }

            let mut frame_count: u32 = 0;
            let mut consecutive_errors: u32 = 0;
            let mut panicked = false;
            // Failed-event throttle state: the offscreen path can fail
            // identically at 60Hz (e.g. transient wgpu error); without
            // dedup every tick crosses the FRB bridge and rebuilds the
            // Dart error state.
            let mut last_failed: Option<String> = None;
            let mut failed_suppressed: u32 = 0;

            // Elevate the Windows timer resolution from the default
            // 15.6 ms to 1 ms for the lifetime of the frame loop.
            // Without this, thread::sleep(remaining) in sleep_remaining
            // rounds up to the next 15.6 ms tick, capping the frame
            // rate at ~30 fps even when the GPU work finishes in 5 ms.
            #[cfg(target_os = "windows")]
            unsafe {
                winmm::timeBeginPeriod(1);
            }

            while !stop_flag.load(Ordering::Relaxed) {
                let tick_start = Instant::now();

                let (mut event, pending_wait) = {
                    // Poisoned-mutex recovery: the inner renderer value
                    // is preserved by `into_inner`, so the per-tick state
                    // (Stage, offscreen texture, surface) survives a
                    // previous lock-holder panic. The worker simply
                    // keeps ticking — no thread is leaked and the lock
                    // is not dropped.
                    let mut r = match renderer.lock() {
                        Ok(guard) => guard,
                        Err(poisoned) => {
                            log::warn!("[live2d] frame_loop: recovering from poisoned mutex");
                            poisoned.into_inner()
                        }
                    };
                    // A wgpu panic must not silently kill the worker —
                    // Dart would see a frozen picture with no event. Catch
                    // it, surface a Failed event, and stop the loop (the
                    // renderer state after a panic is unknown; retrying at
                    // 60 Hz would just spam panics).
                    let ev = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        if r.surface.is_some() {
                            // Android: render directly to the Vulkan surface.
                            // No out-of-lock GPU wait — present happens
                            // inside render_to_surface.
                            let ev = match r.render_to_surface() {
                                Ok(()) => {
                                    frame_count += 1;
                                    consecutive_errors = 0;
                                    if frame_count <= 3 {
                                        log::info!("[live2d] frame_loop: render_to_surface OK (frame {frame_count})");
                                    }
                                    let (w, h) = r
                                        .surface_config
                                        .as_ref()
                                        .map(|c| (c.width, c.height))
                                        .unwrap_or((512, 512));
                                    FrameEvent::Updated(SharedTextureHandle {
                                        width: w,
                                        height: h,
                                        native_handle: 0,
                                    })
                                }
                                Err(e) => {
                                    consecutive_errors += 1;
                                    if consecutive_errors <= 5
                                        || consecutive_errors.is_multiple_of(100)
                                    {
                                        log::error!("[live2d] frame_loop: render_to_surface FAILED ({consecutive_errors} consecutive): {e:?}");
                                    }
                                    match e {
                                        HostError::Render(RenderErrorKind::SurfaceInvalid) => {
                                            FrameEvent::Failed("surface lost".into())
                                        }
                                        // `NoModel` is the expected state
                                        // between `install_android_surface`
                                        // (Stage cleared) and Dart's
                                        // `loadModel` reload. The worker
                                        // would otherwise spam `Failed`
                                        // events at 60Hz for what is
                                        // really "no model yet, wait for
                                        // reload". Skip the tick silently
                                        // so Dart sees no error banner.
                                        HostError::Render(RenderErrorKind::NoModel) => {
                                            FrameEvent::Idle
                                        }
                                        HostError::Render(RenderErrorKind::Wgpu(msg)) => {
                                            FrameEvent::Failed(msg)
                                        }
                                        other => FrameEvent::Failed(format!("{other:?}")),
                                    }
                                }
                            };
                            (ev, None)
                        } else {
                            // Windows / headless: render to the offscreen
                            // shared texture. Submit only — the blocking
                            // wait for this submission happens below,
                            // AFTER the renderer mutex is released, so
                            // control-plane calls (gestures, motions,
                            // resize) are no longer blocked behind the
                            // GPU wait. The wait still completes before
                            // `FrameEvent::Updated` is emitted (hover-
                            // flicker red line).
                            match r.render_to_texture_submit() {
                                Ok(idx) => match r.offscreen_texture.as_ref() {
                                    Some(tex) => {
                                        let handle = tex.texture_export_handle();
                                        (
                                            FrameEvent::Updated(handle),
                                            Some((r.device.clone(), idx)),
                                        )
                                    }
                                    None => (
                                        FrameEvent::Failed(
                                            "render_to_texture succeeded but offscreen_texture is None"
                                                .into(),
                                        ),
                                        None,
                                    ),
                                },
                                Err(HostError::Render(RenderErrorKind::NoModel)) => {
                                    // Same semantics as the Android branch:
                                    // the loop can start before Dart's
                                    // `loadModel` lands. Skip the tick
                                    // silently instead of spamming Failed
                                    // (→ error banner) at 60Hz.
                                    (FrameEvent::Idle, None)
                                }
                                Err(HostError::Render(RenderErrorKind::Wgpu(msg))) => {
                                    (FrameEvent::Failed(msg), None)
                                }
                                Err(other) => {
                                    (FrameEvent::Failed(format!("{other:?}")), None)
                                }
                            }
                        }
                    })) {
                        Ok(ev) => ev,
                        Err(payload) => {
                            panicked = true;
                            let msg = if let Some(s) = payload.downcast_ref::<&str>() {
                                (*s).to_string()
                            } else if let Some(s) = payload.downcast_ref::<String>() {
                                s.clone()
                            } else {
                                "unknown panic".into()
                            };
                            log::error!("[live2d] frame_loop PANIC: {msg} — stopping frame loop");
                            (
                                FrameEvent::Failed(format!("panic in frame loop: {msg}")),
                                None,
                            )
                        }
                    };
                    ev
                };

                // Out-of-lock GPU wait (Windows offscreen path only).
                // The renderer mutex is released here, so control-plane
                // calls proceed while we block on the GPU. Red-line
                // invariant: `FrameEvent::Updated` must not be emitted
                // until this frame's copy_to_shared has retired — a
                // failed or panicking wait downgrades the event to
                // `Failed` instead of letting Updated through.
                if let Some((device, idx)) = pending_wait {
                    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        // Bounded wait: an unbounded `timeout: None` would
                        // hang this worker forever if the GPU is lost mid-
                        // frame (driver TDR/reset) — and `stop_frame_loop`
                        // joins this thread, so the hang would propagate
                        // into app teardown. 2s is ~120 frame budgets; a
                        // timeout downgrades the event to `Failed`, which
                        // keeps the Updated red line intact.
                        device.poll(wgpu::PollType::Wait {
                            submission_index: Some(idx),
                            timeout: Some(std::time::Duration::from_secs(2)),
                        })
                    })) {
                        Ok(Ok(_)) => {}
                        Ok(Err(e)) => {
                            log::error!("[live2d] frame_loop: GPU wait failed: {e:?}");
                            event = FrameEvent::Failed(format!("gpu wait failed: {e:?}"));
                        }
                        Err(payload) => {
                            panicked = true;
                            let msg = if let Some(s) = payload.downcast_ref::<&str>() {
                                (*s).to_string()
                            } else if let Some(s) = payload.downcast_ref::<String>() {
                                s.clone()
                            } else {
                                "unknown panic".into()
                            };
                            log::error!(
                                "[live2d] frame_loop PANIC in GPU wait: {msg} — stopping frame loop"
                            );
                            event = FrameEvent::Failed(format!("panic in gpu wait: {msg}"));
                        }
                    }
                }

                // Throttle repeated identical Failed events: emit the
                // first occurrence immediately, then one every 60 ticks
                // (with the suppressed count logged). Any non-Failed
                // event resets the throttle so recovery → new failure is
                // reported immediately. A panic Failed always goes out —
                // it is the loop's final event.
                let emit = match &event {
                    FrameEvent::Failed(msg) if !panicked => {
                        let suppressed_before = failed_suppressed;
                        let e = should_emit_failed(&mut last_failed, &mut failed_suppressed, msg);
                        if e && suppressed_before > 0 {
                            log::debug!(
                                "[live2d] frame_loop: re-emitting repeated Failed after \
                                 suppressing {suppressed_before} duplicates: {msg}"
                            );
                        }
                        e
                    }
                    _ => {
                        last_failed = None;
                        failed_suppressed = 0;
                        true
                    }
                };
                if emit && sink.add(event).is_err() {
                    // Dart cancelled the stream — stop the worker.
                    break;
                }
                if panicked {
                    break;
                }

                let interval =
                    std::time::Duration::from_micros(frame_micros.load(Ordering::Relaxed) as u64);
                FrameDriver::sleep_remaining(tick_start, interval);
            }

            #[cfg(target_os = "windows")]
            unsafe {
                winmm::timeEndPeriod(1);
            }
        });

        *thread_guard = Some(handle);
    }

    /// Stop a previously started frame loop.
    ///
    /// Sets the shared stop flag and joins the worker thread so it is
    /// fully terminated before this returns. Subsequent `start_frame_loop`
    /// calls will work after this. Serialized against `start_frame_loop`
    /// via the `frame_loop_thread` lock, so this always joins the worker
    /// spawned by the most recent start.
    pub fn stop_frame_loop(&self) {
        // Same recovery contract as `start_frame_loop` above: a poisoned
        // lock does not destroy the inner `Option<JoinHandle>`, so the
        // worker (if any) is still joinable after `into_inner`. The lock
        // itself is not dropped; we just lose the panic-vs-clean invariant.
        let mut thread_guard = self
            .frame_loop_thread
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.frame_loop_stop.store(true, Ordering::Relaxed);
        if let Some(handle) = thread_guard.take() {
            let _ = handle.join();
        }
    }
}

/// Decide whether a `FrameEvent::Failed` with message `msg` should be
/// emitted to Dart.
///
/// Dedup contract (frame loop, 60Hz):
///   * message differs from the last emitted one → emit immediately and
///     reset the suppression counter;
///   * same message → suppress, but re-emit every 60th duplicate so a
///     persistent failure stays observable without flooding the bridge.
///
/// `suppressed` counts duplicates withheld since the last emission and
/// is reset to 0 on every emission.
fn should_emit_failed(last: &mut Option<String>, suppressed: &mut u32, msg: &str) -> bool {
    if last.as_deref() == Some(msg) {
        *suppressed += 1;
        if *suppressed >= 60 {
            *suppressed = 0;
            true
        } else {
            false
        }
    } else {
        *last = Some(msg.to_string());
        *suppressed = 0;
        true
    }
}

impl Drop for RendererHandle {
    /// Drop the handle. If a frame loop worker is still running, signal it
    /// to stop and join so the GPU worker does not outlive the renderer
    /// resources it accesses.
    ///
    /// Without this `Drop` impl, dropping the last `RendererHandle` clone
    /// (the common path on Flutter isolate teardown) leaked the worker
    /// thread: the `JoinHandle` was stored on `self` and got dropped with
    /// the value, but `stop_flag` was never set, so the worker kept
    /// ticking on a renderer that no Dart side could ever observe.
    ///
    /// `stop_frame_loop` requires only `&self`; here we have `&mut self`
    /// in `Drop`, which is fine — the lock does not care about
    /// `mut`/`not mut`. We deliberately do NOT touch `self.renderer` in
    /// `Drop` because the worker may be holding its lock; setting
    /// `frame_loop_stop` causes the worker to exit its loop on the next
    /// tick, release the lock, and let the join complete.
    fn drop(&mut self) {
        self.stop_frame_loop();
    }
}

/// Minimal FFI bindings to `winmm.dll` for elevating the Windows
/// timer resolution during the frame loop. Without `timeBeginPeriod(1)`,
/// `thread::sleep` granularity defaults to 15.6 ms, capping the frame
/// rate at ~30 fps regardless of GPU speed.
#[cfg(target_os = "windows")]
mod winmm {
    #[link(name = "winmm")]
    extern "system" {
        pub(super) fn timeBeginPeriod(uPeriod: u32) -> u32;
        pub(super) fn timeEndPeriod(uPeriod: u32) -> u32;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: build a headless renderer and wrap it in a [`RendererHandle`].
    /// This needs a GPU; on CI without one the helper returns `None` and the
    /// test prints a skip message.
    fn try_new_handle() -> Option<RendererHandle> {
        let renderer = pollster::block_on(Live2dRenderer::new_headless()).ok()?;
        Some(RendererHandle::new(renderer))
    }

    fn test_model_path() -> std::path::PathBuf {
        let path = std::env::var_os("L2D_TEST_MODEL")
            .map(std::path::PathBuf::from)
            .expect("set L2D_TEST_MODEL to a .model3.json before running this test");
        assert!(
            path.is_file(),
            "L2D_TEST_MODEL does not exist: {}",
            path.display()
        );
        path
    }

    #[test]
    fn fps_to_frame_micros_maps_supported_caps() {
        assert_eq!(
            fps_to_frame_micros(0),
            0,
            "0 fps means unlimited (no sleep)"
        );
        assert_eq!(fps_to_frame_micros(30), 33_333);
        assert_eq!(fps_to_frame_micros(60), 16_666);
        assert_eq!(fps_to_frame_micros(120), 8_333);
        // An absurdly high cap must never collapse to 0 (which would read
        // as "unlimited"); it clamps to at least 1µs.
        assert_eq!(fps_to_frame_micros(2_000_000), 1);
    }

    #[test]
    fn handle_get_motion_groups_empty_without_model() {
        let Some(handle) = try_new_handle() else {
            eprintln!("skip: no GPU available for headless renderer");
            return;
        };
        let groups = handle.get_motion_groups().unwrap();
        assert!(groups.is_empty());
    }

    #[test]
    fn handle_tap_does_not_panic_without_model() {
        let Some(handle) = try_new_handle() else {
            eprintln!("skip: no GPU available for headless renderer");
            return;
        };
        handle.tap().unwrap();
    }

    #[test]
    fn handle_zoom_does_not_panic_without_model() {
        let Some(handle) = try_new_handle() else {
            eprintln!("skip: no GPU available for headless renderer");
            return;
        };
        handle.zoom(1.5).unwrap();
    }

    #[test]
    fn handle_pan_cycle_does_not_panic_without_model() {
        let Some(handle) = try_new_handle() else {
            eprintln!("skip: no GPU available for headless renderer");
            return;
        };
        handle.pan_start().unwrap();
        handle.pan_delta(10.0, 20.0, 800, 600).unwrap();
        handle.pan_end().unwrap();
    }

    #[test]
    fn handle_reset_gesture_does_not_panic_without_model() {
        let Some(handle) = try_new_handle() else {
            eprintln!("skip: no GPU available for headless renderer");
            return;
        };
        handle.reset_gesture().unwrap();
    }

    #[test]
    fn handle_resize_does_not_panic_without_model() {
        let Some(handle) = try_new_handle() else {
            eprintln!("skip: no GPU available for headless renderer");
            return;
        };
        handle.resize(1024, 768).unwrap();
    }

    #[test]
    fn handle_set_fit_center_does_not_panic_without_model() {
        let Some(handle) = try_new_handle() else {
            eprintln!("skip: no GPU available for headless renderer");
            return;
        };
        handle.set_fit_center(Some((0.5, 0.5))).unwrap();
    }

    #[test]
    fn handle_render_to_texture_without_model_fails() {
        let Some(handle) = try_new_handle() else {
            eprintln!("skip: no GPU available for headless renderer");
            return;
        };
        let result = handle.render_to_texture();
        assert!(
            result.is_err(),
            "render_to_texture should fail when no model is loaded"
        );
    }

    #[test]
    fn should_emit_failed_emits_first_and_every_60th_duplicate() {
        let mut last = None;
        let mut suppressed = 0;
        assert!(should_emit_failed(&mut last, &mut suppressed, "boom"));
        let mut emitted = 0;
        for _ in 0..120 {
            if should_emit_failed(&mut last, &mut suppressed, "boom") {
                emitted += 1;
            }
        }
        assert_eq!(emitted, 2, "120 duplicates should re-emit exactly twice");
    }

    #[test]
    fn should_emit_failed_emits_immediately_on_message_change() {
        let mut last = None;
        let mut suppressed = 0;
        assert!(should_emit_failed(&mut last, &mut suppressed, "a"));
        assert!(!should_emit_failed(&mut last, &mut suppressed, "a"));
        assert!(should_emit_failed(&mut last, &mut suppressed, "b"));
        // Counter resets on change: next duplicate of "b" is suppressed.
        assert!(!should_emit_failed(&mut last, &mut suppressed, "b"));
    }

    /// Regression guard for the out-of-lock GPU wait refactor: emulate
    /// the frame loop's submit → unlock → `Wait { submission_index }`
    /// pattern on a worker thread while the main thread hammers
    /// control-plane calls (`resize` / `trigger_motion`) through the
    /// same renderer mutex. Asserts no panic on either side and that
    /// frames keep completing (the equivalent of `FrameEvent::Updated`
    /// continuing to flow).
    #[test]
    #[ignore = "requires a GPU and L2D_TEST_MODEL"]
    fn out_of_lock_wait_survives_concurrent_control_calls() {
        let Some(handle) = try_new_handle() else {
            panic!("this test needs a GPU adapter");
        };
        let model_path = test_model_path();
        handle
            .load_model(model_path.to_string_lossy().to_string())
            .unwrap();
        let groups = handle.get_motion_groups().unwrap();

        let renderer = handle.renderer.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let stop_worker = stop.clone();
        let worker = thread::spawn(move || {
            let mut completed = 0u32;
            while !stop_worker.load(Ordering::Relaxed) {
                // Same sequence as the production frame loop: submit
                // inside the lock, wait on the submission outside it.
                let pending = {
                    let mut r = renderer.lock().unwrap();
                    match r.render_to_texture_submit() {
                        Ok(idx) => Some((r.device.clone(), idx)),
                        Err(_) => None,
                    }
                };
                if let Some((device, idx)) = pending {
                    device
                        .poll(wgpu::PollType::Wait {
                            submission_index: Some(idx),
                            timeout: None,
                        })
                        .expect("out-of-lock GPU wait must succeed");
                    completed += 1;
                }
            }
            completed
        });

        for i in 0..60u32 {
            let (w, h) = if i % 2 == 0 { (640, 480) } else { (800, 600) };
            handle.resize(w, h).unwrap();
            if let Some(group) = groups.first() {
                let _ = handle.trigger_motion(group.clone());
            }
            thread::sleep(std::time::Duration::from_millis(1));
        }
        stop.store(true, Ordering::Relaxed);
        let completed = worker.join().expect("frame worker must not panic");
        assert!(
            completed > 0,
            "frames must keep completing while control calls run concurrently"
        );
    }

    /// Regression guard for the Windows process crash in D3D12Core.dll
    /// (WER 2026-07-30: c0000005 / c000041d @ D3D12Core.dll+0x5308e) that
    /// fired at renderer teardown once a `SharedOffscreenTexture` had been
    /// created and used.
    ///
    /// Root cause: `SharedOffscreenTexture` creates its `ID3D12Resource`
    /// directly on the raw D3D12 device, bypassing wgpu's resource
    /// tracker. When the renderer dropped, wgpu's own textures released
    /// their device references and wgpu destroyed the `ID3D12Device`
    /// *before* the manual COM `raw_resource` released — the trailing
    /// `Release` then dereferenced a freed device and aborted the whole
    /// process. Holding a `wgpu::Device` clone in `SharedOffscreenTexture`
    /// (dropped after `raw_resource`) fixes it.
    ///
    /// This drives the exact production concurrency: a frame-loop worker
    /// submits inside the renderer lock and waits out-of-lock, while the
    /// main thread cycles `set_window_size` (rebuilds the shared texture)
    /// and `load_model` (rebuilds the whole `Stage`). Everything drops at
    /// the end. Because the crash was a teardown abort, a clean process
    /// exit *is* the assertion — before the fix this test aborted with
    /// 0xC0000005 after printing "stress OK".
    ///
    /// Ignored by default (needs a GPU + real models). Point it at models
    /// with:
    ///   L2D_STRESS_MODELS="a.model3.json;b.model3.json" \
    ///   L2D_STRESS_ITERS=500 \
    ///   cargo test -p mocari_host --release stress_load_model_during_frame_loop -- --ignored --nocapture
    #[test]
    #[ignore = "requires a GPU and L2D_STRESS_MODELS or L2D_TEST_MODEL"]
    fn stress_load_model_during_frame_loop() {
        let Some(handle) = try_new_handle() else {
            eprintln!("skip: no GPU available for headless renderer");
            return;
        };
        let handle = Arc::new(handle);

        let models: Vec<String> = std::env::var("L2D_STRESS_MODELS")
            .or_else(|_| std::env::var("L2D_TEST_MODEL"))
            .expect("set L2D_STRESS_MODELS or L2D_TEST_MODEL")
            .split(';')
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty())
            .collect();
        assert!(!models.is_empty(), "no test models configured");
        for m in &models {
            if !Path::new(m).exists() {
                eprintln!("skip: model not found: {m}");
                return;
            }
        }
        let iters: u32 = std::env::var("L2D_STRESS_ITERS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(500);

        // Prime with the first model so the worker has something to render.
        handle.load_model(models[0].clone()).unwrap();

        let renderer = handle.renderer.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let stop_worker = stop.clone();
        let worker = thread::spawn(move || {
            let mut completed = 0u32;
            while !stop_worker.load(Ordering::Relaxed) {
                // Mirror the production frame loop: submit inside the lock,
                // wait on the submission outside it, and catch any wgpu
                // panic (transient VRAM pressure under this churn can make
                // buffer creation panic) so the worker downgrades to
                // stopping instead of aborting the process — exactly what
                // `start_frame_loop` does.
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    let pending = {
                        let mut r = renderer.lock().unwrap_or_else(|p| p.into_inner());
                        match r.render_to_texture_submit() {
                            Ok(idx) => Some((r.device.clone(), idx)),
                            Err(_) => None,
                        }
                    };
                    if let Some((device, idx)) = pending {
                        device
                            .poll(wgpu::PollType::Wait {
                                submission_index: Some(idx),
                                timeout: None,
                            })
                            .is_ok()
                    } else {
                        false
                    }
                }));
                match result {
                    Ok(true) => completed += 1,
                    Ok(false) => {}
                    // Panic caught: renderer state is unknown; stop the loop
                    // just like the production worker does on a caught panic.
                    Err(_) => break,
                }
            }
            completed
        });

        let sizes = [(512u32, 512u32), (1181, 783), (800, 600), (1920, 1080)];
        let mut loaded = 0u32;
        for i in 0..iters {
            let (w, h) = sizes[(i as usize) % sizes.len()];
            let _ = handle.set_window_size(w, h);
            let model = &models[(i as usize) % models.len()];
            // Tolerate transient load failures: under this synthetic churn
            // wgpu buffer creation can hit VRAM pressure and `load_model`
            // returns Err (via its `catch_unwind`) — exactly the recoverable
            // error the Dart side handles in production. The teardown-AV
            // guard does not depend on every load succeeding.
            if handle.load_model(model.clone()).is_ok() {
                loaded += 1;
            }
            let _ = handle.trigger_motion("idle".to_string());
        }

        stop.store(true, Ordering::Relaxed);
        let completed = worker.join().expect("frame worker must not panic");
        assert!(completed > 0, "frames must keep completing during reloads");
        assert!(loaded > 0, "at least one model reload must succeed");
        // Reaching a clean process exit after dropping `handle` is the
        // real assertion: the teardown abort happened here before the fix.
    }
}
