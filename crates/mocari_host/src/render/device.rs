use crate::error::{HostError, RenderErrorKind};

/// Plain (non-sRGB) BGRA. The offscreen target is shared into Flutter via
/// ANGLE's EGL_D3D_TEXTURE_ANGLE, whose eglBindTexImage only accepts the
/// plain unorm BGRA format (DXGI B8G8R8A8_UNORM). B8G8R8A8_UNORM_SRGB and
/// _TYPELESS both fail the bind with "Binding D3D surface failed".
pub(crate) const DEFAULT_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Bgra8Unorm;

pub struct RenderContext {
    pub instance: wgpu::Instance,
    pub adapter: wgpu::Adapter,
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
}

impl RenderContext {
    /// The set of backends we attempt to bring up, ordered from most
    /// preferred (matches the platform's native windowing stack) to
    /// fallbacks.
    ///
    /// On Windows we MUST prefer D3D12 because the offscreen rendering
    /// path threads the texture through a D3D11 `TextureHandler` that
    /// opens a shared NT handle on the same device. Vulkan or other
    /// backends would still paint the model fine, but they cannot
    /// produce the shared handle the Flutter TextureHandler needs.
    pub fn default_backends() -> wgpu::Backends {
        // We must pin Windows to DX12 because the offscreen rendering
        // pipeline threads the texture through a D3D11 `TextureHandler`
        // that opens a shared NT handle on the same D3D12 device.
        // Vulkan or other backends can render the model fine but they
        // cannot produce the shared handle Flutter's TextureHandler
        // consumes. Drop Vulkan/Metal/etc. — wgpu's primary backend
        // for Vulkan tends to win `HighPerformance` priority on
        // Windows even when DX12 is available, so we must exclude it.
        #[cfg(target_os = "windows")]
        {
            wgpu::Backends::DX12
        }
        #[cfg(target_os = "android")]
        {
            wgpu::Backends::VULKAN
        }
        #[cfg(not(any(target_os = "windows", target_os = "android")))]
        {
            wgpu::Backends::all()
        }
    }

    pub async fn new_headless() -> Result<Self, HostError> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: Self::default_backends(),
            flags: wgpu::InstanceFlags::default(),
            memory_budget_thresholds: wgpu::MemoryBudgetThresholds::default(),
            backend_options: wgpu::BackendOptions::default(),
            display: None,
        });
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                force_fallback_adapter: false,
                compatible_surface: None,
                apply_limit_buckets: false,
            })
            .await
            .map_err(|e| HostError::Render(RenderErrorKind::Wgpu(format!("{e:?}"))))?;
        let (device, queue) = Self::request_device(&adapter).await?;
        Ok(Self {
            instance,
            adapter,
            device,
            queue,
        })
    }

    /// Create a `RenderContext` together with a Vulkan `Surface` built
    /// from a raw `ANativeWindow*`, where the adapter is guaranteed to
    /// be compatible with that surface.
    ///
    /// On Android, `RenderContext::new_headless` picks an adapter with
    /// `compatible_surface: None`. Some Mali Vulkan drivers then return
    /// empty capabilities for the Android surface in `attach_surface`,
    /// producing a `HostError` that FRB swallows as
    /// `Instance of 'HostErrorImpl'`. This constructor creates a fresh
    /// `wgpu::Instance`, builds the surface from the raw window pointer,
    /// requests an adapter with `compatible_surface: Some(&surface)`,
    /// and returns everything together so the caller can install the
    /// bundle into the renderer in a single brief lock — no `await`
    /// held across a `MutexGuard`.
    #[cfg(target_os = "android")]
    pub async fn new_with_android_window(
        window_ptr: u64,
        width: u32,
        height: u32,
    ) -> Result<
        (
            Self,
            wgpu::Surface<'static>,
            wgpu::SurfaceConfiguration,
            wgpu::TextureFormat,
        ),
        HostError,
    > {
        use crate::render::surface_android::create_surface_from_native_window;

        if width == 0 || height == 0 {
            return Err(HostError::Render(RenderErrorKind::Wgpu(
                "new_with_android_window: zero-sized".into(),
            )));
        }

        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: Self::default_backends(),
            flags: wgpu::InstanceFlags::default(),
            memory_budget_thresholds: wgpu::MemoryBudgetThresholds::default(),
            backend_options: wgpu::BackendOptions::default(),
            display: None,
        });

        // SAFETY: `window_ptr` is a valid `ANativeWindow*` acquired by
        // `ANativeWindow_fromSurface` in the Kotlin JNI bridge. The
        // caller (RendererHandle) keeps the SurfaceTexture alive for
        // the lifetime of this surface.
        let surface = unsafe { create_surface_from_native_window(&instance, window_ptr)? };

        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                force_fallback_adapter: false,
                compatible_surface: Some(&surface),
                apply_limit_buckets: false,
            })
            .await
            .map_err(|e| HostError::Render(RenderErrorKind::Wgpu(format!("{e:?}"))))?;
        let (device, queue) = Self::request_device(&adapter).await?;

        let caps = surface.get_capabilities(&adapter);
        let format = if caps.formats.contains(&DEFAULT_FORMAT) {
            DEFAULT_FORMAT
        } else {
            caps.formats.first().copied().ok_or_else(|| {
                HostError::Render(RenderErrorKind::Wgpu(
                    "new_with_android_window: surface supports no formats".into(),
                ))
            })?
        };

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width,
            height,
            present_mode: wgpu::PresentMode::Fifo,
            desired_maximum_frame_latency: 2,
            alpha_mode: wgpu::CompositeAlphaMode::Auto,
            color_space: wgpu::SurfaceColorSpace::Srgb,
            view_formats: vec![],
        };

        Ok((
            Self {
                instance,
                adapter,
                device,
                queue,
            },
            surface,
            config,
            format,
        ))
    }

    async fn request_device(
        adapter: &wgpu::Adapter,
    ) -> Result<(wgpu::Device, wgpu::Queue), HostError> {
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("mocari-host"),
                required_features: wgpu::Features::empty(),
                required_limits: required_limits_for_cubism_textures(),
                memory_hints: wgpu::MemoryHints::default(),
                trace: wgpu::Trace::Off,
                experimental_features: wgpu::ExperimentalFeatures::disabled(),
            })
            .await
            .map_err(|e| HostError::Render(RenderErrorKind::Wgpu(format!("{e:?}"))))?;
        // wgpu's default uncaptured-error handler panics, which aborts the
        // whole process when triggered from the frame-loop thread (validation
        // errors from a corrupt model, OOM on huge textures). Log instead;
        // real device loss still surfaces through surface errors.
        device.on_uncaptured_error(std::sync::Arc::new(|e: wgpu::Error| {
            log::error!("[live2d] wgpu uncaptured error (suppressed panic): {e}");
        }));
        Ok((device, queue))
    }
}

/// Minimum `wgpu::Limits` we need from a device.
///
/// `wgpu::Limits::downlevel_defaults()` caps `max_texture_dimension_2d` at
/// 2048 (wgpu-types-30.0.0/src/limits.rs:560), but real Cubism models can
/// legally ship textures up to 4096×4096 — and high-DPI variants up to
/// 8192×8192. With the downlevel cap, `WgpuLive2dRenderer::create_rgba8_texture`
/// panics on those models with
/// `Dimension X value 4096 exceeds the limit of 2048`.
///
/// Raise the 2D (and 1D, for consistency) texture dimension to 8192 while
/// keeping every other `downlevel_defaults()` field untouched:
///   * Windows is pinned to DX12 (D3D12 hardware supports ≥16384)
///   * Android is pinned to Vulkan (modern Android GPUs support ≥8192)
///   * The downlevel uniform-buffer / storage-buffer caps stay relevant for
///     the D3D11 TextureHandler cross-process path on Windows
fn required_limits_for_cubism_textures() -> wgpu::Limits {
    wgpu::Limits {
        max_texture_dimension_1d: 8192,
        max_texture_dimension_2d: 8192,
        ..wgpu::Limits::downlevel_defaults()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits_accommodate_4k_cubism_textures() {
        // Live2D models may ship 4096×4096 textures. The previous
        // `wgpu::Limits::downlevel_defaults()` cap of 2048 caused
        // `Device::create_texture` to panic with
        // `Dimension X value 4096 exceeds the limit of 2048`.
        let limits = required_limits_for_cubism_textures();
        assert!(
            limits.max_texture_dimension_2d >= 4096,
            "max_texture_dimension_2d must be >= 4096 to load 4K Cubism textures, got {}",
            limits.max_texture_dimension_2d
        );
    }

    #[test]
    fn limits_preserve_downlevel_defaults_for_other_fields() {
        // We only relax the texture dimension cap. Other downlevel fields
        // (uniform buffer size, storage buffers per stage, compute workgroup
        // size) must stay at downlevel values to keep the D3D11 cross-process
        // path and older Android Vulkan drivers happy.
        let limits = required_limits_for_cubism_textures();
        assert_eq!(limits.max_uniform_buffer_binding_size, 16 << 10);
        assert_eq!(limits.max_storage_buffers_per_shader_stage, 4);
        assert_eq!(limits.max_compute_workgroup_storage_size, 16352);
        assert_eq!(limits.max_color_attachments, 4);
    }
}
