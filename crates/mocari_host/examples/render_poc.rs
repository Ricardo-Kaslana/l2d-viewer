//! PoC: Live2D mesh rendering with mocari 0.4 + wgpu 30.
//! Run: `cargo run -p mocari_host --example render_poc`

use std::{path::PathBuf, sync::Arc, time::Instant};

use mocari::{
    assets::load_model_runtime,
    motion::load_motion,
    render::wgpu::{
        preferred_surface_format, WgpuClippingPlan, WgpuLive2dRenderer, WgpuMeshBuffers,
        WgpuTexture, WgpuTransform,
    },
    MotionPlayer,
};
use mocari_host::render::{fit::*, gesture::GestureState};
use winit::{
    application::ApplicationHandler,
    dpi::{LogicalSize, PhysicalSize},
    event::{ElementState, MouseButton, MouseScrollDelta, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    keyboard::{KeyCode, PhysicalKey},
    window::Window,
};

const MASK_SIZE: u32 = 256;

/// One motion group with every loadable file cached, in BTreeMap order.
struct MotionGroupCache {
    name: String,
    motions: Vec<mocari::json::Motion3>,
    file_index: usize,
}

struct Stage {
    runtime: mocari::ModelRuntime,
    textures: Vec<WgpuTexture>,
    meshes: WgpuMeshBuffers,
    clip: mocari::render::wgpu::WgpuClippingResources,
    mask: mocari::render::wgpu::WgpuMaskRenderTarget,
    xform: WgpuTransform,
    player: Option<MotionPlayer>,
    // Loaded-once motion groups in stable BTreeMap order; each group caches
    // every loadable file. `motion_group_index` is the group currently
    // playing and `MotionGroupCache::file_index` is the file within it. A
    // click advances the file index, wrapping into the next group when it
    // rolls over.
    motion_groups: Vec<MotionGroupCache>,
    motion_group_index: usize,
    // Accumulated user gesture (zoom + pan + in-flight right-drag). See
    // `mocari_host::render::gesture` for the affine math and the per-axis
    // translate/diagonal-scale composition invariant.
    gesture: GestureState,
    // M_fit affine params, refreshed on resize and at load. Used to invert
    // screen-pixel deltas back into model space for pan, and to compose the
    // final transform each frame.
    fit_scale_x: f32,
    fit_scale_y: f32,
    fit_tx: f32,
    fit_ty: f32,
    // Model bounds center = wheel-zoom anchor; None on degenerate bounds.
    fit_center: Option<(f32, f32)>,
}

fn load_stage(
    renderer: &WgpuLive2dRenderer,
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    path: &PathBuf,
    win_w: u32,
    win_h: u32,
) -> Result<Stage, Box<dyn std::error::Error>> {
    let loaded = load_model_runtime(path)?;
    let rt = loaded.runtime().clone();
    let model_dir = loaded.model_dir().map(|p| p.to_path_buf());
    let meshes = rt.meshes().to_vec();

    let textures: Vec<_> = loaded
        .textures()
        .iter()
        .map(|d| renderer.create_rgba8_texture(device, queue, d.width(), d.height(), d.rgba()))
        .collect::<Result<_, _>>()?;

    let mesh = WgpuMeshBuffers::from_drawables(device, &meshes).ok_or("no drawables")?;

    let mut cp = WgpuClippingPlan::from_mesh_buffers(&mesh);
    cp.assign_single_texture_layouts()?;
    cp.prepare_single_texture_masks(&mesh)?;
    let clip = renderer.create_clipping_resources(device, &cp)?;
    let mask = renderer.create_mask_render_target(device, MASK_SIZE)?;
    let fit = fit_model_matrix(&meshes, win_w, win_h);
    let fit_center = model_bounds_center(&meshes);
    let xform = renderer.create_transform(device, &fit);

    let base = model_dir
        .as_deref()
        .unwrap_or_else(|| std::path::Path::new("."));
    // Pre-load every loadable motion file from each group once, preserving
    // BTreeMap key order for groups and the group-internal iteratee order for
    // files. Groups that end up empty (all files failed to load) are dropped.
    let mut motion_groups = Vec::new();
    for (name, motions) in rt.model().motions().iter() {
        let mut files = Vec::new();
        for f in motions {
            let mp = base.join(f.file());
            match load_motion(&mp) {
                Ok(md) => {
                    eprintln!("motion group: {name} -> {}", mp.display());
                    files.push(md);
                }
                Err(_) => eprintln!(
                    "warning: skipping unloadable motion {name} -> {}",
                    mp.display()
                ),
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

    // Default to the `idle` group if present, otherwise the first loadable
    // group; otherwise no motion.
    let motion_group_index = motion_groups
        .iter()
        .position(|g| g.name == "idle")
        .unwrap_or(0);
    let player = motion_groups
        .get(motion_group_index)
        .and_then(|g| g.motions.first().map(|md| MotionPlayer::new(md.clone())));

    Ok(Stage {
        runtime: rt,
        textures,
        meshes: mesh,
        clip,
        mask,
        xform,
        player,
        motion_groups,
        motion_group_index,
        gesture: GestureState::new(),
        fit_scale_x: fit.scale_x(),
        fit_scale_y: fit.scale_y(),
        fit_tx: fit.as_slice()[12],
        fit_ty: fit.as_slice()[13],
        fit_center,
    })
}

fn update_stage(
    renderer: &WgpuLive2dRenderer,
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    stage: &mut Stage,
) {
    let meshes = stage.runtime.meshes();
    let up = stage.meshes.update_drawables(queue, meshes);
    if let Ok(ref info) = up {
        if info.bounds_changed() || info.visibility_changed() {
            let mut cp = WgpuClippingPlan::from_mesh_buffers(&stage.meshes);
            cp.assign_single_texture_layouts().ok();
            cp.prepare_single_texture_masks(&stage.meshes).ok();
            if let Ok(cr) = renderer.create_clipping_resources(device, &cp) {
                stage.clip = cr;
            }
        }
    }
}

struct VState {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    renderer: WgpuLive2dRenderer,
    stage: Stage,
    last: Instant,
    first: bool,
    window: Arc<Window>,
}

impl VState {
    async fn new(w: Arc<Window>, path: &PathBuf) -> Result<Self, Box<dyn std::error::Error>> {
        let sz = w.inner_size();
        let inst = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::PRIMARY,
            flags: wgpu::InstanceFlags::default(),
            memory_budget_thresholds: wgpu::MemoryBudgetThresholds::default(),
            backend_options: wgpu::BackendOptions::default(),
            display: None,
        });
        let ws: &'static Arc<Window> = Box::leak(Box::new(w.clone()));
        let surface = inst.create_surface(ws.as_ref())?;
        let adapter = inst
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                force_fallback_adapter: false,
                compatible_surface: Some(&surface),
                apply_limit_buckets: false,
            })
            .await
            .expect("adapter");
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("render-poc"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::default(),
                memory_hints: wgpu::MemoryHints::default(),
                trace: wgpu::Trace::Off,
                experimental_features: wgpu::ExperimentalFeatures::default(),
            })
            .await?;
        let caps = surface.get_capabilities(&adapter);
        let fmt = preferred_surface_format(&caps.formats).unwrap_or(caps.formats[0]);
        let cfg = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: fmt,
            width: sz.width.max(1),
            height: sz.height.max(1),
            present_mode: wgpu::PresentMode::AutoNoVsync,
            desired_maximum_frame_latency: 2,
            view_formats: vec![fmt],
            alpha_mode: caps.alpha_modes[0],
            color_space: wgpu::SurfaceColorSpace::Auto,
        };
        surface.configure(&device, &cfg);

        let renderer = WgpuLive2dRenderer::new(&device, fmt);
        let stage = load_stage(&renderer, &device, &queue, path, sz.width, sz.height)?;

        w.set_title(&format!(
            "Live2D — {} v{}",
            path.file_stem().unwrap_or_default().to_string_lossy(),
            stage.runtime.model().version()
        ));

        Ok(Self {
            surface,
            device,
            queue,
            config: cfg,
            renderer,
            stage,
            last: Instant::now(),
            first: true,
            window: w.clone(),
        })
    }

    fn resize(&mut self, sz: PhysicalSize<u32>) {
        if sz.width == 0 || sz.height == 0 {
            return;
        }
        self.config.width = sz.width;
        self.config.height = sz.height;
        self.surface.configure(&self.device, &self.config);
        let meshes = self.stage.runtime.meshes().to_vec();
        self.stage.fit_center = model_bounds_center(&meshes);
        let m = fit_model_matrix(&meshes, sz.width, sz.height);
        self.stage.fit_scale_x = m.scale_x();
        self.stage.fit_scale_y = m.scale_y();
        self.stage.fit_tx = m.as_slice()[12];
        self.stage.fit_ty = m.as_slice()[13];
        self.stage.xform = self.renderer.create_transform(&self.device, &m);
    }

    fn render(&mut self) -> bool {
        let dt = self.last.elapsed().as_secs_f32();
        self.last = Instant::now();

        if let Some(ref mut p) = self.stage.player {
            p.tick(dt);
            p.apply(&mut self.stage.runtime);
        }

        // Physics evaluates oscillators over current parameter values, so it must
        // run after motion writes parameters and before the meshes are rebuilt.
        // apply_physics is a no-op (returns false) when no physics is attached.
        self.stage.runtime.apply_physics(dt);

        // Motion::apply only writes parameter values; the deformable meshes are
        // not rebuilt until we ask the runtime to evaluate. Without this the
        // model stays on its initial pose even while a motion is "playing".
        if self.stage.runtime.update_meshes().is_none() {
            eprintln!("warning: model runtime failed to evaluate meshes this frame");
        }

        update_stage(&self.renderer, &self.device, &self.queue, &mut self.stage);

        // Compose M_fit * gesture analytically (see `GestureState::compute_transform`).
        let m = self.stage.gesture.compute_transform(
            self.stage.fit_scale_x,
            self.stage.fit_scale_y,
            self.stage.fit_tx,
            self.stage.fit_ty,
        );
        self.stage.xform.update_matrix(&self.queue, &m);

        if self.first {
            self.first = false;
            eprintln!(
                "model rendering: {} drawables",
                self.stage.meshes.drawables().len()
            );
        }

        let st = self.surface.get_current_texture();
        let out = match st {
            wgpu::CurrentSurfaceTexture::Success(t) => t,
            wgpu::CurrentSurfaceTexture::Suboptimal(t) => t,
            wgpu::CurrentSurfaceTexture::Lost | wgpu::CurrentSurfaceTexture::Outdated => {
                self.resize(PhysicalSize::new(self.config.width, self.config.height));
                return false;
            }
            _ => return false,
        };

        let view = out
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let mut enc = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });

        // Pass 1: draw masks to mask render target
        {
            let mut mp = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("mask"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: self.stage.mask.view(),
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
                &self.stage.meshes,
                &self.stage.clip,
                &self.stage.textures,
            );
        }

        // Pass 2: draw model
        {
            let mut rp = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: None,
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.35,
                            g: 0.40,
                            b: 0.50,
                            a: 1.0,
                        }),
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
                &self.stage.meshes,
                &self.stage.textures,
                &self.stage.clip,
                &self.stage.mask,
                &self.stage.xform,
            );
        }

        self.queue.submit(Some(enc.finish()));
        self.queue.present(out);
        self.window.request_redraw();
        true
    }

    /// Resets the user gesture to identity, restoring the initial fit view.
    fn reset_gesture(&mut self) {
        self.stage.gesture.reset();
    }

    fn tap(&mut self) {
        if self.stage.motion_groups.is_empty() {
            return;
        }
        let g = &mut self.stage.motion_groups[self.stage.motion_group_index];
        g.file_index += 1;
        if g.file_index >= g.motions.len() {
            // Exhausted this group's files: restart it and advance the group.
            g.file_index = 0;
            self.stage.motion_group_index =
                (self.stage.motion_group_index + 1) % self.stage.motion_groups.len();
        }
        let g = &self.stage.motion_groups[self.stage.motion_group_index];
        let md = g.motions[g.file_index].clone();
        self.stage.player = Some(MotionPlayer::new(md));
        eprintln!("motion: {}/{}", g.name, g.file_index);
    }
}

struct App {
    path: PathBuf,
    state: Option<VState>,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.state.is_some() {
            return;
        }
        let w = Arc::new(
            el.create_window(
                Window::default_attributes()
                    .with_title("Live2D Viewer")
                    .with_inner_size(LogicalSize::new(900, 900)),
            )
            .expect("window"),
        );
        self.state = Some(pollster::block_on(VState::new(w.clone(), &self.path)).expect("init"));
        let _ = w;
    }

    fn window_event(
        &mut self,
        el: &ActiveEventLoop,
        _id: winit::window::WindowId,
        ev: WindowEvent,
    ) {
        let Some(s) = self.state.as_mut() else { return };
        match ev {
            WindowEvent::CloseRequested => el.exit(),
            WindowEvent::Resized(sz) => s.resize(sz),
            WindowEvent::MouseInput { state, button, .. } => match (state, button) {
                (ElementState::Pressed, MouseButton::Left) => s.tap(),
                (ElementState::Pressed, MouseButton::Right) => s.stage.gesture.pan_start(),
                (ElementState::Released, MouseButton::Right) => s.stage.gesture.pan_end(),
                _ => {}
            },
            WindowEvent::CursorMoved { position, .. } => {
                if s.stage.gesture.is_panning {
                    let (x, y) = (position.x, position.y);
                    if let Some((lx, ly)) = s.stage.gesture.pan_last {
                        s.stage.gesture.pan_delta(
                            (x - lx) as f32,
                            (y - ly) as f32,
                            s.config.width,
                            s.config.height,
                            s.stage.fit_scale_x,
                            s.stage.fit_scale_y,
                        );
                    }
                    s.stage.gesture.pan_last = Some((x, y));
                }
            }
            WindowEvent::MouseWheel { delta, .. } => match delta {
                MouseScrollDelta::LineDelta(_, lines_y) => {
                    s.stage
                        .gesture
                        .zoom(1.1f32.powf(lines_y), s.stage.fit_center);
                }
                MouseScrollDelta::PixelDelta(pos) => {
                    s.stage
                        .gesture
                        .zoom(1.0 + (pos.y as f32 / 500.0), s.stage.fit_center);
                }
            },
            WindowEvent::KeyboardInput { event, .. } => {
                if let (PhysicalKey::Code(KeyCode::KeyR), ElementState::Pressed) =
                    (event.physical_key, event.state)
                {
                    s.reset_gesture();
                }
            }
            WindowEvent::RedrawRequested => {
                s.render();
            }
            _ => {}
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::init();
    let Some(p) = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("L2D_RENDER_MODEL").map(PathBuf::from))
    else {
        eprintln!(
            "usage: cargo run -p mocari_host --example render_poc -- \
             <path/to/model.model3.json>\n\
             or set L2D_RENDER_MODEL to a .model3.json path"
        );
        std::process::exit(2);
    };
    log::info!("Loading: {}", p.display());
    let el = EventLoop::new()?;
    el.set_control_flow(ControlFlow::Poll);
    el.run_app(&mut App {
        path: p,
        state: None,
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn widening_surface_does_not_shrink_height_limited_model() {
        let (_, square_scale_y) = fit_model_scales(3.0, 4.0, 900, 900);
        let (_, wide_scale_y) = fit_model_scales(3.0, 4.0, 1600, 900);

        assert!(
            (wide_scale_y - square_scale_y).abs() < f32::EPSILON,
            "widening a same-height surface changed scale_y from {square_scale_y} to {wide_scale_y}"
        );
    }
}
