//! Bare-metal wgpu 30 triangle test — no mocari at all.
use std::sync::Arc;
use winit::{
    application::ApplicationHandler,
    dpi::LogicalSize,
    event::WindowEvent,
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    window::Window,
};

struct VState {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    pipeline: wgpu::RenderPipeline,
    window: Arc<Window>,
}

impl VState {
    async fn new(w: Arc<Window>) -> Result<Self, Box<dyn std::error::Error>> {
        let sz = w.inner_size();
        // Note: `Box::leak` permanently leaks the `Arc<Window>`. This is
        // acceptable for a one-shot smoke test, but if you copy this file
        // as a template, prefer storing the `Arc<Window>` in `VState` and
        // passing a non-leaked reference to `create_surface`. The leak
        // exists here only because `create_surface` requires a
        // `&'static` reference and the example doesn't manage lifetime
        // scoping.
        let inst = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::GL,
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
        let caps = surface.get_capabilities(&adapter);
        eprintln!("adapter: {:?}", adapter.get_info());
        eprintln!("formats: {:?}", caps.formats);

        let fmt = caps.formats[0];
        eprintln!("using format: {:?}", fmt);

        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("bare-test"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::default(),
                memory_hints: wgpu::MemoryHints::default(),
                trace: wgpu::Trace::Off,
                experimental_features: wgpu::ExperimentalFeatures::default(),
            })
            .await?;

        let cfg = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: fmt,
            width: sz.width.max(1),
            height: sz.height.max(1),
            present_mode: wgpu::PresentMode::Immediate,
            desired_maximum_frame_latency: 2,
            view_formats: vec![fmt],
            alpha_mode: caps.alpha_modes[0],
            color_space: wgpu::SurfaceColorSpace::Auto,
        };
        surface.configure(&device, &cfg);

        // Simple RED triangle shader
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("bare"),
            source: wgpu::ShaderSource::Wgsl(
                r"
@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4<f32> {
    let pos = array(vec2(0.0, 0.5), vec2(-0.5, -0.5), vec2(0.5, -0.5));
    return vec4(pos[idx], 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4<f32> {
    return vec4(1.0, 0.0, 0.0, 1.0);
}
"
                .into(),
            ),
        });

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("bare-pipe"),
            layout: None,
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                buffers: &[],
            },
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: fmt,
                    blend: Some(wgpu::BlendState {
                        color: wgpu::BlendComponent {
                            src_factor: wgpu::BlendFactor::One,
                            dst_factor: wgpu::BlendFactor::Zero,
                            operation: wgpu::BlendOperation::Add,
                        },
                        alpha: wgpu::BlendComponent::OVER,
                    }),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });

        eprintln!("pipeline ready");
        Ok(Self {
            surface,
            device,
            queue,
            config: cfg,
            pipeline,
            window: w,
        })
    }

    fn render(&self) -> bool {
        let st = self.surface.get_current_texture();
        let out = match st {
            wgpu::CurrentSurfaceTexture::Success(t) => {
                eprintln!("  surf_ok({}x{})", t.texture.width(), t.texture.height());
                t
            }
            wgpu::CurrentSurfaceTexture::Suboptimal(t) => {
                eprintln!("  surf_subopt");
                t
            }
            other => {
                eprintln!("  surf_err: {:?}", other);
                return false;
            }
        };
        let view = out
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let mut enc = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
        {
            let mut rp = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: None,
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.1,
                            g: 0.2,
                            b: 0.3,
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
            rp.set_pipeline(&self.pipeline);
            rp.draw(0..3, 0..1);
        }
        self.queue.submit(Some(enc.finish()));
        self.queue.present(out);
        self.window.request_redraw();
        true
    }
}

struct App {
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
                    .with_title("Bare Triangle")
                    .with_inner_size(LogicalSize::new(900, 900)),
            )
            .expect("window"),
        );
        self.state = Some(pollster::block_on(VState::new(w.clone())).expect("init"));
        w.request_redraw();
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
            WindowEvent::RedrawRequested => {
                s.render();
            }
            WindowEvent::Resized(sz) if sz.width > 0 && sz.height > 0 => {
                s.config.width = sz.width;
                s.config.height = sz.height;
                s.surface.configure(&s.device, &s.config);
                s.window.request_redraw();
            }
            _ => {}
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::init();
    eprintln!("--- bare triangle test ---");
    let el = EventLoop::new()?;
    el.set_control_flow(ControlFlow::Poll);
    el.run_app(&mut App { state: None })?;
    Ok(())
}
