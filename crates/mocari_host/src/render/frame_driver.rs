//! Independent-thread frame loop that drives `Live2dRenderer::render_to_texture`
//! at ~60Hz and emits frame events.
//!
//! The `FrameDriver` is the Rust side of the Phase 2 frame pipeline:
//!   * A dedicated worker thread ticks at the configured rate, locks the
//!     renderer, runs `render_to_texture`, and publishes a fresh
//!     `FrameEvent::Updated` carrying the shared NT handle + dimensions.
//!   * `resize` and `set_window_size` propagate to the renderer through the
//!     lock; the next tick picks up the new offscreen size.
//!   * `stop` flips an atomic; the worker thread notices and exits. The
//!     `JoinHandle` is joined on drop to make the shutdown synchronous and
//!     panic-free from the caller's perspective.
//!
//! The driver deliberately does *not* own the renderer — it is shared via
//! `Arc<Mutex<Live2dRenderer>>` so the FRB control surface (`RendererHandle`)
//! can keep issuing tap/zoom/pan/load commands while the loop runs.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::error::{HostError, RenderErrorKind};
use crate::render::renderer::Live2dRenderer;
use crate::render::texture_export::SharedTextureHandle;

/// Target frame interval for a 60Hz loop. The worker thread sleeps for
/// the remainder of this interval after each tick, so the actual rate
/// may be slightly lower when `render_to_texture` is slow.
// 60Hz exactly. The earlier `from_millis(16)` produced a 62.5Hz tick
// rate which beat against the 60Hz Flutter display refresh, surfacing
// as a low-frequency visible flicker (the classic "slightly faster
// than the display" beat pattern). 16_666µs is 1/60s rounded to the
// microsecond, so the loop stays phase-locked with a 60Hz vsync.
const TARGET_FRAME_INTERVAL: Duration = Duration::from_micros(16_666);

/// Frames emitted by the [`FrameDriver`] worker thread.
///
/// The Dart side subscribes to these via the FRB `StreamSink` and reacts
/// accordingly:
///   * `Initial` is emitted once when the loop starts (before the first
///     `render_to_texture` call) so Dart can pre-register a texture of
///     the right dimensions if it wants to.
///   * `Updated` is emitted on every successful frame. The
///     `SharedTextureHandle` carries the same NT handle across ticks
///     unless the offscreen size changed (in which case the
///     `SharedOffscreenTexture` was rebuilt and the handle is new).
///   * `Failed` is emitted when `render_to_texture` returns an error.
///     The loop keeps running — Dart can choose to stop the loop or
///     surface a banner. Subsequent successful frames will emit
///     `Updated` again.
///   * `Idle` is emitted when `render_to_surface` returns `NoModel` —
///     the surface is attached but the Stage was cleared (Android
///     device swap, mid-reload). Skip the tick silently so Dart does
///     not see `Failed` at 60Hz for what is really "wait for
///     `loadModel`".
#[derive(Clone, Debug)]
pub enum FrameEvent {
    /// Emitted once at loop start with the initial offscreen dimensions.
    /// `handle` is `None` until the first `render_to_texture` succeeds.
    Initial { width: u32, height: u32 },
    /// Emitted on every successful frame. `handle` carries the fresh
    /// shared NT handle + dimensions.
    Updated(SharedTextureHandle),
    /// Emitted when `render_to_texture` returns an error. The loop
    /// keeps running so transient failures (e.g. device lost during
    /// a brief GPU stall) can self-recover.
    Failed(String),
    /// Emitted when `render_to_surface` returns `NoModel`: surface is
    /// configured but no model is loaded. The loop continues ticking;
    /// Dart treats this as a no-op (no banner, no error).
    Idle,
}

/// Independent-thread 60Hz frame loop.
///
/// Construct with [`FrameDriver::new`], then call [`FrameDriver::start`] to
/// spawn the worker thread. The driver can be stopped either by calling
/// [`FrameDriver::stop`] or by dropping the driver (which joins the worker
/// thread).
///
/// **Current status:** `FrameDriver` has no production call site. The
/// production frame loop lives in
/// [`RendererHandle::start_frame_loop`](crate::frb_api::RendererHandle::start_frame_loop),
/// which uses its own `frame_loop_stop`/`frame_loop_thread` pair and does
/// NOT go through `FrameDriver`. This module is kept for the unit tests
/// under `#[cfg(test)]` below and as a reusable abstraction if a future
/// non-FRB host wants an independent frame loop. See the note in the
/// 2026-07-23 code review about the `FrameDriver`/`RendererHandle` dual
/// implementation being technical debt.
pub struct FrameDriver {
    renderer: Arc<Mutex<Live2dRenderer>>,
    stop_flag: Arc<AtomicBool>,
    join_handle: Option<JoinHandle<()>>,
}

impl FrameDriver {
    /// Create a new frame driver wrapping the given renderer.
    ///
    /// The renderer is shared via `Arc<Mutex<...>>` so the FRB control
    /// surface (`RendererHandle`) can keep issuing commands while the
    /// loop runs.
    pub fn new(renderer: Arc<Mutex<Live2dRenderer>>) -> Self {
        Self {
            renderer,
            stop_flag: Arc::new(AtomicBool::new(false)),
            join_handle: None,
        }
    }

    /// Spawn the worker thread and start ticking.
    ///
    /// `sink` is called with a fresh `FrameEvent` on every tick. The
    /// closure is `FnMut` so it can capture mutable state (e.g. a
    /// counter). The closure runs on the worker thread.
    ///
    /// # Panics
    ///
    /// Panics if the driver has already been started.
    pub fn start<F>(&mut self, mut sink: F)
    where
        F: FnMut(FrameEvent) + Send + 'static,
    {
        assert!(
            self.join_handle.is_none(),
            "FrameDriver::start called twice on the same driver"
        );

        let renderer = self.renderer.clone();
        let stop_flag = self.stop_flag.clone();

        let handle = thread::spawn(move || {
            // Emit Initial once so Dart knows the starting dimensions.
            // We read them from the renderer's offscreen_size field (or
            // surface_config) so Dart can pre-allocate the texture if
            // it wants to.
            let (init_w, init_h) = {
                let r = renderer.lock().expect("renderer mutex poisoned");
                r.offscreen_size
                    .or_else(|| r.surface_config.as_ref().map(|c| (c.width, c.height)))
                    .unwrap_or((512, 512))
            };
            sink(FrameEvent::Initial {
                width: init_w,
                height: init_h,
            });

            while !stop_flag.load(Ordering::Relaxed) {
                let tick_start = Instant::now();

                let event = {
                    let mut r = match renderer.lock() {
                        Ok(guard) => guard,
                        Err(_) => {
                            // Mutex poisoned — the renderer is in an
                            // unrecoverable state. Emit a Failed event
                            // and keep looping; the next lock attempt
                            // will either succeed or fail the same way.
                            sink(FrameEvent::Failed("renderer mutex poisoned".into()));
                            Self::sleep_remaining(tick_start, TARGET_FRAME_INTERVAL);
                            continue;
                        }
                    };
                    match r.render_to_texture() {
                        Ok(()) => {
                            let offscreen = r.offscreen_texture.as_ref();
                            match offscreen {
                                Some(tex) => {
                                    let handle = tex.texture_export_handle();
                                    FrameEvent::Updated(handle)
                                }
                                None => FrameEvent::Failed(
                                    "render_to_texture succeeded but offscreen_texture is None"
                                        .into(),
                                ),
                            }
                        }
                        Err(HostError::Render(RenderErrorKind::Wgpu(msg))) => {
                            FrameEvent::Failed(msg)
                        }
                        Err(other) => FrameEvent::Failed(format!("{other:?}")),
                    }
                };
                sink(event);

                Self::sleep_remaining(tick_start, TARGET_FRAME_INTERVAL);
            }
        });

        self.join_handle = Some(handle);
    }

    /// Signal the worker thread to stop and join it.
    ///
    /// After this returns, the driver can be started again with
    /// [`FrameDriver::start`].
    pub fn stop(&mut self) {
        self.stop_flag.store(true, Ordering::Relaxed);
        if let Some(handle) = self.join_handle.take() {
            let _ = handle.join();
        }
        // Reset the stop flag so the driver can be restarted.
        self.stop_flag.store(false, Ordering::Relaxed);
    }

    /// Sleep for the remainder of the given frame `interval`.
    ///
    /// `interval == Duration::ZERO` means "unlimited" (the FPS cap is off):
    /// the initial `elapsed >= interval` check returns immediately and the
    /// Windows spin loop never runs, so the loop ticks as fast as it can.
    pub(crate) fn sleep_remaining(tick_start: Instant, interval: Duration) {
        let elapsed = tick_start.elapsed();
        if elapsed >= interval {
            return;
        }
        let remaining = interval - elapsed;
        // Hybrid sleep + spin: sleep for the bulk of the remaining
        // budget, then spin-wait the last ~1.5 ms. Even with
        // timeBeginPeriod(1), Windows thread::sleep can overshoot by
        // ~1 ms; spinning the tail eliminates the final jitter and
        // keeps the tick interval close to the 16.67 ms target.
        //
        // Windows-only: on Android the spin burns ~9% of a frame
        // budget of battery/thermal headroom per tick for jitter the
        // compositor absorbs anyway (SurfaceTexture consumers are not
        // vsync-locked to this loop), so sleep the full remainder.
        #[cfg(target_os = "windows")]
        {
            const SPIN_THRESHOLD: Duration = Duration::from_micros(1_500);
            if remaining > SPIN_THRESHOLD {
                thread::sleep(remaining - SPIN_THRESHOLD);
            }
            while tick_start.elapsed() < interval {
                std::hint::spin_loop();
            }
        }
        #[cfg(not(target_os = "windows"))]
        thread::sleep(remaining);
    }
}

impl Drop for FrameDriver {
    fn drop(&mut self) {
        // Best-effort shutdown: signal stop and join the worker thread
        // so we don't leak it. If the thread is already gone (because
        // `stop` was called), this is a no-op.
        self.stop_flag.store(true, Ordering::Relaxed);
        if let Some(handle) = self.join_handle.take() {
            let _ = handle.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::sync::atomic::Ordering::SeqCst;

    /// The driver should emit `Initial` then `Updated` frames at roughly
    /// the target rate, and stop cleanly when `stop` is called.
    ///
    /// We don't assert exact timing (CI clocks are unreliable); instead
    /// we count frames over a short window and check that at least 2
    /// `Updated` events were emitted, which proves the tick loop ran.
    #[test]
    #[ignore = "requires a GPU and L2D_TEST_MODEL"]
    fn frame_driver_drives_frames_at_60hz() {
        let renderer =
            pollster::block_on(Live2dRenderer::new_headless()).expect("headless renderer");
        let model_path = std::env::var_os("L2D_TEST_MODEL")
            .map(std::path::PathBuf::from)
            .expect("set L2D_TEST_MODEL to a .model3.json");
        assert!(
            model_path.is_file(),
            "L2D_TEST_MODEL does not exist: {}",
            model_path.display()
        );
        let renderer = Arc::new(Mutex::new(renderer));
        {
            let mut r = renderer.lock().expect("renderer mutex poisoned");
            r.load_model(&model_path).expect("load_model");
        }

        let frame_count = Arc::new(AtomicUsize::new(0));
        let initial_count = Arc::new(AtomicUsize::new(0));
        let updated_count = Arc::new(AtomicUsize::new(0));
        let failed_count = Arc::new(AtomicUsize::new(0));

        let fc = frame_count.clone();
        let ic = initial_count.clone();
        let uc = updated_count.clone();
        let flc = failed_count.clone();

        let mut driver = FrameDriver::new(renderer);
        driver.start(move |event| {
            fc.fetch_add(1, SeqCst);
            match event {
                FrameEvent::Initial { .. } => {
                    ic.fetch_add(1, SeqCst);
                }
                FrameEvent::Updated(_) => {
                    uc.fetch_add(1, SeqCst);
                }
                FrameEvent::Failed(_) => {
                    flc.fetch_add(1, SeqCst);
                }
                // Idle is emitted by the production loop when no model
                // is loaded; FrameDriver itself never emits it (its test
                // renderer has no Stage path), but the match must be
                // exhaustive after the Idle variant was added.
                FrameEvent::Idle => {}
            }
        });

        // Wait long enough for at least a few ticks. 300 ms absorbs
        // first-tick GPU init overhead (~50–100 ms on some drivers)
        // while still leaving ≥10 frame intervals for the assertion.
        thread::sleep(Duration::from_millis(300));

        driver.stop();

        let total = frame_count.load(SeqCst);
        let initial = initial_count.load(SeqCst);
        let updated = updated_count.load(SeqCst);
        let failed = failed_count.load(SeqCst);

        // Initial is emitted exactly once.
        assert_eq!(
            initial, 1,
            "expected exactly one Initial event, got {initial}"
        );
        // The loop ran for ~120ms (≈7 ticks at 16ms). We require at
        // least 2 Updated events to prove the tick loop executed
        // `render_to_texture` more than once.
        assert!(
            updated >= 2,
            "expected at least 2 Updated events, got {updated} (total={total}, failed={failed})"
        );
        // We don't expect any failures in this happy path, but if the
        // GPU is unavailable the test environment may report errors.
        // We only assert that the loop produced *some* successful frames.
    }

    /// Dropping the driver should stop the worker thread without panicking.
    #[test]
    fn frame_driver_drop_stops_worker() {
        let renderer =
            pollster::block_on(Live2dRenderer::new_headless()).expect("headless renderer");
        let renderer = Arc::new(Mutex::new(renderer));

        let frame_count = Arc::new(AtomicUsize::new(0));
        let fc = frame_count.clone();

        let mut driver = FrameDriver::new(renderer);
        driver.start(move |_event| {
            fc.fetch_add(1, SeqCst);
        });

        // Let it tick a couple of times.
        thread::sleep(Duration::from_millis(50));

        // Drop should stop the worker thread cleanly.
        drop(driver);

        let count_before = frame_count.load(SeqCst);
        // Wait a bit more and check the count hasn't increased.
        thread::sleep(Duration::from_millis(50));
        let count_after = frame_count.load(SeqCst);
        assert_eq!(
            count_before, count_after,
            "worker thread kept ticking after drop"
        );
    }

    /// `stop` should be idempotent — calling it twice shouldn't panic.
    #[test]
    fn frame_driver_stop_is_idempotent() {
        let renderer =
            pollster::block_on(Live2dRenderer::new_headless()).expect("headless renderer");
        let renderer = Arc::new(Mutex::new(renderer));

        let mut driver = FrameDriver::new(renderer);
        driver.start(|_event| {});
        thread::sleep(Duration::from_millis(50));

        driver.stop();
        driver.stop(); // should not panic
    }
}
