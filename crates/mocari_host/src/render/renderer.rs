//! Live2D production renderer extracted from the render PoC.
//!
//! `Live2dRenderer` owns the wgpu device, the Mocari wgpu renderer, an optional
//! surface, and an optional `Stage` (loaded model).  Gesture state is kept
//! separately so pan / zoom / reset work regardless of whether a model is
//! loaded.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use mocari::{
    assets::load_model_runtime,
    core::Matrix44,
    motion::load_motion,
    render::wgpu::{
        WgpuClippingPlan, WgpuClippingResources, WgpuLive2dRenderer, WgpuMaskRenderTarget,
        WgpuMeshBuffers, WgpuTexture, WgpuTransform,
    },
    MotionPlayer,
};

use crate::error::{HostError, LoadErrorKind, RenderErrorKind};
use crate::render::device::{RenderContext, DEFAULT_FORMAT};
use crate::render::fit::{fit_model_matrix, fit_model_scales, model_bounds};
use crate::render::gesture::GestureSlot;
use crate::render::shared_offscreen::SharedOffscreenTexture;

const MASK_SIZE: u32 = 256;

/// Upper bound on the per-frame `dt` passed to `update_frame`.
///
/// Guards against pause/resume jumps (Android backgrounding, debugger
/// break) where `Instant::now().duration_since(last_frame_time)` could
/// be many seconds and break physics integration / motion blending.
/// `0.1s` is ≈6× the 60Hz target frame interval — large enough to
/// recover smoothly after a real stall, small enough to keep physics
/// stable.
const MAX_FRAME_DT: f32 = 0.1;

pub struct Live2dRenderer {
    pub(crate) device: wgpu::Device,
    pub(crate) queue: wgpu::Queue,
    /// Retained for Android surface creation (`attach_surface`).
    #[cfg_attr(not(target_os = "android"), allow(dead_code))]
    pub(crate) instance: wgpu::Instance,
    /// Retained for `Surface::get_capabilities` in `attach_surface`.
    #[cfg_attr(not(target_os = "android"), allow(dead_code))]
    pub(crate) adapter: wgpu::Adapter,
    pub(crate) surface: Option<wgpu::Surface<'static>>,
    pub(crate) surface_config: Option<wgpu::SurfaceConfiguration>,
    pub(crate) renderer: WgpuLive2dRenderer,
    pub(crate) stage: Option<Stage>,
    /// Gesture state + cached fit scalars, shared via `Arc<Mutex<...>>`
    /// with the FRB control surface (`RendererHandle`). The frame loop
    /// only locks this briefly inside `update_composite_transform`; the
    /// handle locks it for `pan_delta`/`zoom`/`reset`. This decouples
    /// gesture updates from the full `render_to_texture` mutex hold that
    /// caused drag input to stall behind every render frame.
    pub(crate) gesture: Arc<Mutex<GestureSlot>>,
    pub(crate) offscreen_texture: Option<SharedOffscreenTexture>,
    /// Explicit offscreen size used by `render_to_texture` when there
    /// is no surface (headless). When `Some`, it takes precedence over
    /// `surface_config`; when `None`, `render_to_texture` falls back to
    /// `surface_config` and finally to `(512, 512)`. Updated by
    /// `resize`/`set_window_size` so callers driving the offscreen path
    /// can control the shared texture dimensions.
    pub(crate) offscreen_size: Option<(u32, u32)>,
    pub(crate) last_frame_time: Option<Instant>,
    /// Background clear color for the model render pass.
    pub(crate) clear_color: wgpu::Color,
    /// Throttle counter for the per-frame `update_meshes` failure warn
    /// in `update_frame` — an abnormal state would otherwise spam the
    /// log at 60Hz.
    update_mesh_warn_count: u32,
    /// Throttle counter for `update_clipping_resources` errors in
    /// `update_frame` (same 60Hz spam concern as above).
    clipping_warn_count: u32,
}

pub struct Stage {
    pub runtime: mocari::ModelRuntime,
    pub textures: Vec<WgpuTexture>,
    pub meshes: WgpuMeshBuffers,
    pub clipping: WgpuClippingResources,
    pub mask: WgpuMaskRenderTarget,
    pub transform: WgpuTransform,
    pub motion_player: Option<MotionPlayer>,
    pub motion_groups: Vec<MotionGroupCache>,
    pub motion_group_index: usize,
    pub fit_scale_x: f32,
    pub fit_scale_y: f32,
    pub fit_tx: f32,
    pub fit_ty: f32,
    pub fit_center: Option<(f32, f32)>,
    /// Rest-pose model bounds `(width, height, center_x, center_y)`,
    /// cached at load time. `recompute_fit` derives the resize fit from
    /// this instead of re-scanning (and cloning) the current — possibly
    /// deformed — meshes, which makes the fit deterministic across
    /// resizes and removes a full mesh copy from the resize path.
    pub rest_bounds: Option<(f32, f32, f32, f32)>,
}

pub struct MotionGroupCache {
    pub name: String,
    pub motions: Vec<mocari::json::Motion3>,
    pub file_index: usize,
}

pub struct ModelInfo {
    pub version: u32,
    pub motion_groups: Vec<String>,
}

impl Live2dRenderer {
    /// Create a headless renderer (no surface).  Suitable for off-screen
    /// rendering or for contexts where the surface will be attached later.
    pub async fn new_headless() -> Result<Self, HostError> {
        let ctx = RenderContext::new_headless().await?;
        let renderer = WgpuLive2dRenderer::new(&ctx.device, DEFAULT_FORMAT);
        Ok(Self {
            device: ctx.device,
            queue: ctx.queue,
            instance: ctx.instance,
            adapter: ctx.adapter,
            surface: None,
            surface_config: None,
            renderer,
            stage: None,
            gesture: Arc::new(Mutex::new(GestureSlot::new())),
            offscreen_texture: None,
            offscreen_size: None,
            last_frame_time: None,
            clear_color: wgpu::Color {
                r: 0.35,
                g: 0.40,
                b: 0.50,
                a: 1.0,
            },
            update_mesh_warn_count: 0,
            clipping_warn_count: 0,
        })
    }

    /// Load a Cubism `*.model3.json` and build the GPU resources for it.
    ///
    /// The fit matrix uses the same three-level size fallback as
    /// `render_to_texture` (offscreen size → surface config → 512×512),
    /// so a headless renderer sized via `set_offscreen_size` gets a
    /// correct fit on first load instead of a degenerate 1×1.
    pub fn load_model(&mut self, path: &Path) -> Result<ModelInfo, HostError> {
        log::info!("[live2d] renderer.load_model: path={}", path.display());
        let (win_w, win_h) = self
            .offscreen_size
            .or_else(|| self.surface_config.as_ref().map(|c| (c.width, c.height)))
            .unwrap_or((512, 512));

        // Guard mocari's parallel texture decode: a corrupt PNG claiming
        // huge IHDR dimensions (or too many 8K textures) would abort the
        // process on allocation failure — catch_unwind cannot intercept
        // that. Validate existence + dimensions before decoding.
        crate::render::preflight::validate_model3_textures(path)?;

        let loaded = load_model_runtime(path).map_err(|e| {
            log::error!("[live2d] load_model_runtime failed: {e}");
            HostError::Load(LoadErrorKind::InvalidManifest(format!(
                "load_model_runtime: {e}"
            )))
        })?;
        log::info!("[live2d] model loaded, creating textures...");
        let rt = loaded.runtime().clone();
        let model_dir = loaded.model_dir().map(|p| p.to_path_buf());
        let meshes = rt.meshes().to_vec();

        let textures: Vec<_> = loaded
            .textures()
            .iter()
            .map(|d| {
                log::debug!("[live2d] creating texture {}x{}", d.width(), d.height());
                self.renderer.create_rgba8_texture(
                    &self.device,
                    &self.queue,
                    d.width(),
                    d.height(),
                    d.rgba(),
                )
            })
            .collect::<Result<_, _>>()
            .map_err(|e| {
                log::error!("[live2d] texture creation failed: {e}");
                HostError::Render(RenderErrorKind::Wgpu(format!("texture: {e}")))
            })?;

        log::info!("[live2d] creating mesh buffers...");
        let mesh = WgpuMeshBuffers::from_drawables(&self.device, &meshes)
            .ok_or_else(|| HostError::Load(LoadErrorKind::MissingFile("no drawables".into())))?;

        log::info!("[live2d] creating clipping resources...");
        let mut cp = WgpuClippingPlan::from_mesh_buffers(&mesh);
        cp.assign_single_texture_layouts().map_err(|e| {
            HostError::Render(RenderErrorKind::Wgpu(format!("clipping layout: {e}")))
        })?;
        cp.prepare_single_texture_masks(&mesh).map_err(|e| {
            HostError::Render(RenderErrorKind::Wgpu(format!("clipping masks: {e}")))
        })?;
        let clip = self
            .renderer
            .create_clipping_resources(&self.device, &cp)
            .map_err(|e| HostError::Render(RenderErrorKind::Wgpu(format!("clipping: {e}"))))?;
        let mask = self
            .renderer
            .create_mask_render_target(&self.device, MASK_SIZE)
            .map_err(|e| HostError::Render(RenderErrorKind::Wgpu(format!("mask: {e}"))))?;

        log::info!("[live2d] computing fit matrix...");
        let fit = fit_model_matrix(&meshes, win_w, win_h);
        let rest_bounds = model_bounds(&meshes);
        let fit_center = rest_bounds.map(|(_, _, cx, cy)| (cx, cy));
        let xform = self.renderer.create_transform(&self.device, &fit);

        let base = model_dir
            .as_deref()
            .unwrap_or_else(|| std::path::Path::new("."));
        let mut motion_groups = Vec::new();
        for (name, motions) in rt.model().motions().iter() {
            let mut files = Vec::new();
            for f in motions {
                let mp = base.join(f.file());
                if let Ok(md) = load_motion(&mp) {
                    files.push(md);
                }
            }
            if !files.is_empty() {
                motion_groups.push(MotionGroupCache {
                    name: name.clone(),
                    motions: files,
                    file_index: 0,
                });
            }
        }

        let motion_group_index = motion_groups
            .iter()
            .position(|g| g.name == "idle")
            .unwrap_or(0);
        let player = motion_groups
            .get(motion_group_index)
            .and_then(|g| g.motions.first().map(|md| MotionPlayer::new(md.clone())));

        let version = rt.model().version();
        let motion_group_names = motion_groups.iter().map(|g| g.name.clone()).collect();

        self.stage = Some(Stage {
            runtime: rt,
            textures,
            meshes: mesh,
            clipping: clip,
            mask,
            transform: xform,
            motion_player: player,
            motion_groups,
            motion_group_index,
            fit_scale_x: fit.scale_x(),
            fit_scale_y: fit.scale_y(),
            fit_tx: fit.as_slice()[12],
            fit_ty: fit.as_slice()[13],
            fit_center,
            rest_bounds,
        });

        // Refresh the shared gesture slot's fit scalars so pan/zoom issued
        // through the FRB handle (which does NOT lock this renderer) see
        // the new model's fit. The lock is held only for the field writes.
        if let Some(ref stage) = self.stage {
            if let Ok(mut g) = self.gesture.lock() {
                g.update_fit(stage.fit_scale_x, stage.fit_scale_y, stage.fit_center);
            }
        }

        Ok(ModelInfo {
            version,
            motion_groups: motion_group_names,
        })
    }

    /// Return the names of every loaded motion group.
    pub fn get_motion_groups(&self) -> Vec<String> {
        self.stage
            .as_ref()
            .map(|s| s.motion_groups.iter().map(|g| g.name.clone()).collect())
            .unwrap_or_default()
    }

    /// Start playing the first motion in the named group, if it exists.
    pub fn trigger_motion(&mut self, group: &str) {
        let Some(stage) = self.stage.as_mut() else {
            return;
        };
        let Some(idx) = stage.motion_groups.iter().position(|g| g.name == group) else {
            return;
        };
        stage.motion_group_index = idx;
        let g = &stage.motion_groups[idx];
        if let Some(md) = g.motions.first() {
            stage.motion_player = Some(MotionPlayer::new(md.clone()));
        }
    }

    /// Cycle to the next motion file / group, exactly like a left-click in the
    /// PoC window.
    pub fn tap(&mut self) {
        let Some(stage) = self.stage.as_mut() else {
            return;
        };
        if stage.motion_groups.is_empty() {
            return;
        }
        let g = &mut stage.motion_groups[stage.motion_group_index];
        g.file_index += 1;
        if g.file_index >= g.motions.len() {
            g.file_index = 0;
            stage.motion_group_index = (stage.motion_group_index + 1) % stage.motion_groups.len();
        }
        let g = &stage.motion_groups[stage.motion_group_index];
        let md = g.motions[g.file_index].clone();
        stage.motion_player = Some(MotionPlayer::new(md));
    }

    // ------------------------------------------------------------------
    // Internal helpers used by a future render loop
    // ------------------------------------------------------------------

    /// Recompute the fit matrix and update the GPU transform.  Call this after
    /// a surface resize or when attaching a new surface.
    ///
    /// Uses the rest-pose bounds cached at load time instead of scanning
    /// the current (possibly deformed) meshes: no mesh clone, no new
    /// uniform buffer — the existing transform is updated in place. The
    /// fit is therefore deterministic for a given surface size regardless
    /// of the animation pose at resize time.
    pub(crate) fn recompute_fit(&mut self, width: u32, height: u32) {
        let Some(stage) = self.stage.as_mut() else {
            return;
        };
        let m = match stage.rest_bounds {
            Some((bw, bh, cx, cy)) => {
                let (sx, sy) = fit_model_scales(bw, bh, width, height);
                let mut m = Matrix44::identity();
                m.scale(sx, sy);
                m.translate(-cx * sx, -cy * sy);
                m
            }
            // Degenerate model bounds: same identity fallback as
            // `fit_model_matrix` on collapsed geometry.
            None => Matrix44::identity(),
        };
        stage.fit_center = stage.rest_bounds.map(|(_, _, cx, cy)| (cx, cy));
        stage.fit_scale_x = m.scale_x();
        stage.fit_scale_y = m.scale_y();
        stage.fit_tx = m.as_slice()[12];
        stage.fit_ty = m.as_slice()[13];
        stage.transform.update_matrix(&self.queue, &m);
        // Keep the shared gesture slot in sync with the new fit so
        // pan/zoom from the FRB handle use the post-resize scalars.
        if let Ok(mut g) = self.gesture.lock() {
            g.update_fit(stage.fit_scale_x, stage.fit_scale_y, stage.fit_center);
        }
    }

    /// Compose `M_fit * gesture` analytically and upload the result to the
    /// GPU transform buffer.  Call this each frame before drawing.
    pub(crate) fn update_composite_transform(&mut self) {
        let Some(stage) = self.stage.as_mut() else {
            return;
        };
        // Snapshot the gesture scalars under the short-lived gesture lock.
        // The lock is uncontended in practice (the FRB handle only holds it
        // for the duration of a pan/zoom math call), so this no longer
        // blocks input behind the full render_to_texture mutex.
        let (g_scale_x, g_scale_y, g_translate_x, g_translate_y) = match self.gesture.lock() {
            Ok(g) => (
                g.state.scale_x,
                g.state.scale_y,
                g.state.translate_x,
                g.state.translate_y,
            ),
            Err(_) => return,
        };
        let sx = stage.fit_scale_x * g_scale_x;
        let sy = stage.fit_scale_y * g_scale_y;
        let tx = stage.fit_scale_x * g_translate_x + stage.fit_tx;
        let ty = stage.fit_scale_y * g_translate_y + stage.fit_ty;
        let mut m = Matrix44::identity();
        m.scale(sx, sy);
        m.translate(tx, ty);
        stage.transform.update_matrix(&self.queue, &m);
    }

    // ------------------------------------------------------------------
    // Frame update + render helpers
    // ------------------------------------------------------------------

    /// Advance motion, physics, and deformable meshes, then update GPU buffers.
    fn update_frame(&mut self, dt: f32) -> Result<(), HostError> {
        let stage = self
            .stage
            .as_mut()
            .ok_or(HostError::Render(RenderErrorKind::NoModel))?;

        // Motion player tick + apply
        if let Some(ref mut player) = stage.motion_player {
            player.tick(dt);
            player.apply(&mut stage.runtime);
        }

        // Pose fade must run after motion (it reads the parameters motion
        // just wrote) so pose3 groups swap variants instead of drawing
        // every member at once.
        stage.runtime.apply_pose(dt);

        // Physics evaluates oscillators over current parameter values.
        stage.runtime.apply_physics(dt);

        // Rebuild deformable meshes after motion/physics wrote parameters.
        if stage.runtime.update_meshes().is_none() {
            self.update_mesh_warn_count += 1;
            if self.update_mesh_warn_count == 1 || self.update_mesh_warn_count.is_multiple_of(300) {
                log::warn!(
                    "[live2d] update_frame: model runtime failed to evaluate meshes \
                     ({} occurrences so far)",
                    self.update_mesh_warn_count
                );
            }
        }

        // Update GPU vertex/index buffers and refresh clipping if bounds changed.
        let meshes = stage.runtime.meshes();
        let up = stage.meshes.update_drawables(&self.queue, meshes);
        if let Ok(ref info) = up {
            if info.bounds_changed() || info.visibility_changed() {
                let mut cp = WgpuClippingPlan::from_mesh_buffers(&stage.meshes);
                if let Err(e) = cp.assign_single_texture_layouts() {
                    log::warn!(
                        "[live2d] update_frame: assign_single_texture_layouts failed: {e:?}"
                    );
                }
                if let Err(e) = cp.prepare_single_texture_masks(&stage.meshes) {
                    log::warn!("[live2d] update_frame: prepare_single_texture_masks failed: {e:?}");
                }
                // Bounds change on virtually every animation frame, so this
                // runs at ~60Hz. Prefer the in-place uniform/bind-group
                // update (zero allocation); it returns `Ok(false)` when the
                // clipping structure no longer matches (mask count / layout
                // changed) — only then pay for a full rebuild.
                let updated = match self.renderer.update_clipping_resources(
                    &self.queue,
                    &mut stage.clipping,
                    &cp,
                ) {
                    Ok(updated) => updated,
                    Err(e) => {
                        self.clipping_warn_count += 1;
                        if self.clipping_warn_count == 1
                            || self.clipping_warn_count.is_multiple_of(300)
                        {
                            log::warn!(
                                "[live2d] update_frame: update_clipping_resources failed \
                                 ({} occurrences so far): {e:?}",
                                self.clipping_warn_count
                            );
                        }
                        false
                    }
                };
                if !updated {
                    match self.renderer.create_clipping_resources(&self.device, &cp) {
                        Ok(cr) => stage.clipping = cr,
                        Err(e) => {
                            log::warn!(
                                "[live2d] update_frame: create_clipping_resources failed: {e:?}"
                            );
                        }
                    }
                }
            }
        }

        // Compose fit * gesture and upload to GPU.
        self.update_composite_transform();

        Ok(())
    }

    /// Execute the two-pass render (mask + model) into `target_view`.
    fn render_passes(
        &self,
        encoder: &mut wgpu::CommandEncoder,
        target_view: &wgpu::TextureView,
    ) -> Result<(), HostError> {
        let stage = self
            .stage
            .as_ref()
            .ok_or(HostError::Render(RenderErrorKind::NoModel))?;

        // Pass 1: draw masks to mask render target
        {
            let mut mp = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("mask"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: stage.mask.view(),
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            let _ = self.renderer.draw_masks_with_textures(
                &mut mp,
                &stage.meshes,
                &stage.clipping,
                &stage.textures,
            );
        }

        // Pass 2: draw model to target view
        {
            let mut rp = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("model"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: target_view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(self.clear_color),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            let _ = self.renderer.draw_with_textures_clipping_and_transform(
                &mut rp,
                &stage.meshes,
                &stage.textures,
                &stage.clipping,
                &stage.mask,
                &stage.transform,
            );
        }

        Ok(())
    }

    // ------------------------------------------------------------------
    // Public render API
    // ------------------------------------------------------------------

    /// Render the current frame to an off-screen texture.
    ///
    /// The texture is stored in `self.offscreen_texture` (a
    /// `SharedOffscreenTexture`) and can be exported as a
    /// `SharedTextureHandle` for the D3D11 side after this call
    /// returns successfully.
    ///
    /// Blocks until the GPU work (render passes + copy_to_shared) has
    /// retired. One-shot callers and `FrameDriver` use this; the
    /// production frame loop uses [`Self::render_to_texture_submit`]
    /// and performs the equivalent wait outside the renderer mutex
    /// (see the frame-loop red line in AGENTS.md).
    pub fn render_to_texture(&mut self) -> Result<(), HostError> {
        let idx = self.render_to_texture_submit()?;
        // Block until this frame's GPU work completes before returning.
        //
        // The shared D3D12 texture is sampled by Flutter's ANGLE
        // backend at arbitrary times (button hover triggers extra
        // compositor frames). Waiting on this submission ensures the
        // copy_to_shared above has retired before `FrameEvent::Updated`
        // is emitted and Dart calls `markFrameAvailable`, so the shared
        // texture is never observed in a partially-written state.
        //
        // Bounded for the same reason as the frame loop's out-of-lock
        // wait: a lost GPU (driver TDR) must not hang the caller —
        // 2s is ~120 frame budgets. A timeout/error must propagate:
        // returning Ok would let `FrameEvent::Updated` through with the
        // copy possibly not retired (hover-flicker red line).
        self.device
            .poll(wgpu::PollType::Wait {
                submission_index: Some(idx),
                timeout: Some(std::time::Duration::from_secs(2)),
            })
            .map_err(|e| {
                HostError::Render(RenderErrorKind::Wgpu(format!("gpu wait failed: {e:?}")))
            })?;
        Ok(())
    }

    /// Render the current frame to the off-screen texture and submit the
    /// GPU work, **without** waiting for it to retire.
    ///
    /// Returns the `SubmissionIndex` of the submitted work. The caller
    /// MUST `device.poll(PollType::Wait { submission_index, .. })` on
    /// that index (Device is Clone, so this can happen after releasing
    /// the renderer mutex) **before** signalling Dart that the frame is
    /// ready — otherwise ANGLE can sample a partially-copied shared
    /// texture (see docs/postmortem/2026-07-21-viewer-hover-flicker.md).
    pub(crate) fn render_to_texture_submit(&mut self) -> Result<wgpu::SubmissionIndex, HostError> {
        let now = Instant::now();
        let dt = self
            .last_frame_time
            .map(|t| now.duration_since(t).as_secs_f32())
            .unwrap_or(0.0)
            .clamp(0.0, MAX_FRAME_DT);
        self.last_frame_time = Some(now);

        self.update_frame(dt)?;

        let (width, height) = self
            .offscreen_size
            .or_else(|| self.surface_config.as_ref().map(|c| (c.width, c.height)))
            .unwrap_or((512, 512));

        // (Re)create the shared D3D12 offscreen texture when its size
        // changes. `SharedOffscreenTexture::new` allocates a D3D12
        // resource with `ALLOW_SHARED` set, exports an NT handle, and
        // wraps the memory as a `wgpu::Texture` for use as a render
        // target. The format is constrained to BGRA8 for cross-device
        // compatibility with the D3D11 TextureHandler.
        let needs_new = self
            .offscreen_texture
            .as_ref()
            .map(|t| t.width() != width || t.height() != height)
            .unwrap_or(true);
        if needs_new {
            let texture = SharedOffscreenTexture::new(&self.device, width, height, DEFAULT_FORMAT)?;
            self.offscreen_texture = Some(texture);
        }

        // We always know `offscreen_texture` exists here because we
        // either returned an error above or installed one.
        let shared = self
            .offscreen_texture
            .as_ref()
            .ok_or(HostError::Render(RenderErrorKind::SurfaceInvalid))?;
        // Render to the private (non-shared) texture. The shared D3D12
        // resource is only touched by the copy below, so ANGLE never
        // samples a partially-rendered frame.
        let view = shared.render_target_view();

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("render_to_texture"),
            });
        self.render_passes(&mut encoder, view)?;
        // Single GPU copy: private → shared. This is the only write to
        // the shared D3D12 resource, so ANGLE either sees the previous
        // complete frame or the new one — never a mask-only or
        // partially-drawn frame.
        shared.copy_to_shared(&mut encoder);
        let idx = self.queue.submit(Some(encoder.finish()));

        Ok(idx)
    }

    /// Render the current frame to the configured surface.
    ///
    /// This also presents the frame and handles surface loss/outdated states
    /// by reconfiguring the surface.
    ///
    /// Error semantics:
    ///   * `SurfaceInvalid` — surface is detached (app backgrounded,
    ///     mid-swap) or `get_current_texture` returned `Lost`/`Outdated`/
    ///     `Timeout`/`Occluded`/`Validation`. The frame loop treats this as
    ///     "skip a tick"; the caller is expected to reattach or resize on
    ///     its own schedule. Surface loss reconfigures the surface before
    ///     returning.
    ///   * `NoModel` — surface is configured but no `Stage` is loaded.
    ///     After `install_android_surface` (Android device swap) or a
    ///     successful `detach_surface` followed by a reload race, the
    ///     frame loop worker may tick before Dart's `loadModel` lands.
    ///     Distinguish this from `SurfaceInvalid` so the loop can skip a
    ///     frame without spamming `Failed` events to Dart.
    pub fn render_to_surface(&mut self) -> Result<(), HostError> {
        let surface = self
            .surface
            .as_ref()
            .ok_or(HostError::Render(RenderErrorKind::SurfaceInvalid))?;

        // Pre-acquire guard: if the Stage is gone (Android device-swap or
        // mid-reload), skip before doing any GPU work. Without this guard
        // we hit `update_frame`'s `SurfaceInvalid` return, which the loop
        // already maps to `FrameEvent::Failed` — spamming the Dart side
        // at 60Hz with `Failed` for what is really just "no model yet".
        if self.stage.is_none() {
            return Err(HostError::Render(RenderErrorKind::NoModel));
        }

        let st = surface.get_current_texture();
        let out = match st {
            wgpu::CurrentSurfaceTexture::Success(t) => t,
            wgpu::CurrentSurfaceTexture::Suboptimal(t) => t,
            wgpu::CurrentSurfaceTexture::Lost | wgpu::CurrentSurfaceTexture::Outdated => {
                if let Some(ref config) = self.surface_config {
                    let width = config.width;
                    let height = config.height;
                    self.resize(width, height);
                }
                return Err(HostError::Render(RenderErrorKind::SurfaceInvalid));
            }
            wgpu::CurrentSurfaceTexture::Timeout
            | wgpu::CurrentSurfaceTexture::Occluded
            | wgpu::CurrentSurfaceTexture::Validation => {
                return Err(HostError::Render(RenderErrorKind::SurfaceInvalid));
            }
        };

        let now = Instant::now();
        let dt = self
            .last_frame_time
            .map(|t| now.duration_since(t).as_secs_f32())
            .unwrap_or(0.0)
            .clamp(0.0, MAX_FRAME_DT);
        self.last_frame_time = Some(now);

        self.update_frame(dt)?;

        let view = out
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("render_to_surface"),
            });
        self.render_passes(&mut encoder, &view)?;
        self.queue.submit(Some(encoder.finish()));
        self.queue.present(out);

        Ok(())
    }

    /// Resize the surface and recompute the fit matrix.
    pub fn resize(&mut self, width: u32, height: u32) {
        if width == 0 || height == 0 {
            return;
        }
        if let Some(ref mut config) = self.surface_config {
            config.width = width;
            config.height = height;
        }
        if let Some(ref surface) = self.surface {
            if let Some(ref config) = self.surface_config {
                surface.configure(&self.device, config);
            }
        }
        // Track the requested dimensions so the headless offscreen
        // path (`render_to_texture` without a surface) sees the same
        // size the caller asked for, instead of falling back to 512.
        self.offscreen_size = Some((width, height));
        self.recompute_fit(width, height);
    }

    /// Set the model bounds center used as the zoom anchor.
    pub fn set_fit_center(&mut self, center: Option<(f32, f32)>) {
        if let Some(ref mut stage) = self.stage {
            stage.fit_center = center;
        }
        // Propagate to the shared gesture slot so zoom ops issued through
        // the FRB handle anchor on the new center without a renderer lock.
        if let Ok(mut g) = self.gesture.lock() {
            g.fit_center = center;
        }
    }

    /// Set the logical window size and recompute the fit matrix.
    ///
    /// Use this when rendering to texture (no surface) to keep the model
    /// fit consistent with the intended output dimensions. When a surface
    /// is attached (Android), also reconfigures the swapchain. Alias of
    /// [`Self::resize`], kept because both names are part of the FRB
    /// public API.
    pub fn set_window_size(&mut self, width: u32, height: u32) {
        self.resize(width, height);
    }

    /// Set the background clear color for the model render pass.
    pub fn set_clear_color(&mut self, r: f64, g: f64, b: f64, a: f64) {
        self.clear_color = wgpu::Color { r, g, b, a };
    }

    /// Attach an Android surface from a raw ANativeWindow pointer.
    ///
    /// Creates a wgpu Vulkan surface, configures it at the given
    /// Install a freshly-built Android surface bundle into the renderer.
    ///
    /// This is the synchronous tail of `RendererHandle::attach_surface`.
    /// All async work (instance + adapter + device + surface creation)
    /// happens outside the renderer lock in
    /// `RenderContext::new_with_android_window`, because
    /// `std::sync::MutexGuard` is not `Send` and cannot cross an `.await`.
    /// This method takes ownership of the bundle and installs it in one
    /// brief locked section.
    ///
    /// Safe to call before any model is loaded — no GPU resources exist
    /// to invalidate when we swap device/queue/renderer.
    #[cfg(target_os = "android")]
    pub fn install_android_surface(
        &mut self,
        ctx: RenderContext,
        surface: wgpu::Surface<'static>,
        config: wgpu::SurfaceConfiguration,
        format: wgpu::TextureFormat,
        width: u32,
        height: u32,
    ) {
        log::info!("[live2d] install_android_surface: {width}x{height} format={format:?}");
        // The new device invalidates every GPU resource created on the
        // previous (headless) device: textures, mesh buffers, clipping
        // resources, mask render target, and the transform uniform. If we
        // leave the old `Stage` in place the frame loop worker — which may
        // already be ticking by the time the Dart side awaits `loadModel` —
        // calls `render_to_surface` with resources bound to a freed device,
        // and Vulkan silently produces no output (the "Android 模型无法渲染"
        // symptom). Drop the stage here; the caller MUST reload the model
        // immediately afterwards to rebuild resources on the new device.
        self.stage = None;
        // The offscreen texture (if any) is also bound to the old device.
        self.offscreen_texture = None;
        self.instance = ctx.instance;
        self.adapter = ctx.adapter;
        self.device = ctx.device;
        self.queue = ctx.queue;
        self.renderer = WgpuLive2dRenderer::new(&self.device, format);
        surface.configure(&self.device, &config);
        self.surface = Some(surface);
        self.surface_config = Some(config);
        self.offscreen_size = Some((width, height));
        self.recompute_fit(width, height);
        log::info!("[live2d] install_android_surface: done, stage cleared");
    }

    /// Detach the current surface (app backgrounded, surface destroyed).
    ///
    /// Drops both the `wgpu::Surface` and its `SurfaceConfiguration`. The
    /// underlying `ANativeWindow` is not released here — the caller owns
    /// it. After detach, the frame loop worker continues to tick but every
    /// `render_to_surface` call will return `SurfaceInvalid` (no surface)
    /// or `NoModel` (Stage was already cleared by `install_android_surface`).
    /// The Dart side is expected to call this from the platform channel's
    /// pause handler before the `SurfaceTexture` is destroyed; re-attach
    /// on resume triggers a fresh `install_android_surface` cycle.
    #[cfg(target_os = "android")]
    pub fn detach_surface(&mut self) {
        log::info!("[live2d] detach_surface: clearing surface + config");
        self.surface = None;
        self.surface_config = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Windows offscreen path must report "no Stage loaded" as
    /// `NoModel`, not `SurfaceInvalid` — the frame loop maps `NoModel`
    /// to a silent skipped tick (`FrameEvent::Idle`) while anything
    /// else becomes a 60Hz `Failed` spam and a Dart error banner
    /// during the normal "frame loop started, model still loading"
    /// window.
    #[test]
    fn render_to_texture_submit_without_model_returns_no_model() {
        let Ok(mut renderer) = pollster::block_on(Live2dRenderer::new_headless()) else {
            eprintln!("skip: no GPU available for headless renderer");
            return;
        };
        let err = renderer
            .render_to_texture_submit()
            .expect_err("submit without a loaded model must fail");
        assert!(
            matches!(err, HostError::Render(RenderErrorKind::NoModel)),
            "expected NoModel, got {err:?}"
        );
    }

    /// B3 regression: `recompute_fit` derives the resize fit from the
    /// cached rest-pose bounds. For a freshly loaded (undeformed) model
    /// this must produce exactly the same fit scalars as running
    /// `fit_model_matrix` over the initial meshes at the new size —
    /// proving the clone-free path is equivalent to the old one.
    #[test]
    #[ignore = "requires a GPU and L2D_TEST_MODEL"]
    fn recompute_fit_matches_fit_model_matrix_on_rest_pose() {
        let mut renderer = pollster::block_on(Live2dRenderer::new_headless())
            .expect("this test needs a GPU adapter");
        let model_path = std::env::var_os("L2D_TEST_MODEL")
            .map(std::path::PathBuf::from)
            .expect("set L2D_TEST_MODEL to a .model3.json");
        assert!(
            model_path.is_file(),
            "L2D_TEST_MODEL does not exist: {}",
            model_path.display()
        );
        renderer.load_model(&model_path).expect("load_model");

        let initial_meshes = renderer
            .stage
            .as_ref()
            .expect("stage after load")
            .runtime
            .meshes()
            .to_vec();

        for (w, h) in [(1024u32, 768u32), (1920, 1080), (600, 1200)] {
            renderer.recompute_fit(w, h);
            let expected = fit_model_matrix(&initial_meshes, w, h);
            let stage = renderer.stage.as_ref().unwrap();
            assert!(
                (stage.fit_scale_x - expected.scale_x()).abs() < 1e-5,
                "{w}x{h} scale_x: {} vs {}",
                stage.fit_scale_x,
                expected.scale_x()
            );
            assert!(
                (stage.fit_scale_y - expected.scale_y()).abs() < 1e-5,
                "{w}x{h} scale_y: {} vs {}",
                stage.fit_scale_y,
                expected.scale_y()
            );
            assert!(
                (stage.fit_tx - expected.as_slice()[12]).abs() < 1e-5,
                "{w}x{h} tx: {} vs {}",
                stage.fit_tx,
                expected.as_slice()[12]
            );
            assert!(
                (stage.fit_ty - expected.as_slice()[13]).abs() < 1e-5,
                "{w}x{h} ty: {} vs {}",
                stage.fit_ty,
                expected.as_slice()[13]
            );
        }
    }
}
