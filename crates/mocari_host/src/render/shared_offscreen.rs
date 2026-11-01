//! D3D12 shared `ID3D12Resource` that survives wgpu wrap-around.
//!
//! On Windows, wgpu owns the D3D12 device internally and cannot be
//! asked to allocate a resource with the shared flag set. This module
//! creates the resource through the raw D3D12 device (borrowed from
//! `wgpu::Device`'s HAL handle), exports an NT shared handle, then
//! re-wraps the same `ID3D12Resource` as a `wgpu::Texture` so that
//! other code can keep treating it like a regular wgpu render target.
//!
//! The key invariants are:
//!   * `ID3D12Resource::Format` MUST be a fully TYPED DXGI format (e.g.
//!     `B8G8R8A8_UNORM`), matching the wgpu wrap format. Flutter's GL
//!     backend (ANGLE) binds the opened D3D11 texture as an EGL surface
//!     and rejects `*_TYPELESS` formats, so a typed format is required.
//!   * `ID3D12Resource` is owned by `SharedOffscreenTexture` and is
//!     released automatically when the field drops (the `windows`
//!     crate binds COM lifetime to the Rust handle type).
//!   * `wgpu_texture` is declared before `raw_resource`, so its
//!     `Drop` runs first — any pending GPU work referencing the
//!     resource completes before COM decrements the refcount.

#[cfg(target_os = "windows")]
use wgpu::hal::dx12::Api as Dx12Api;
#[cfg(target_os = "windows")]
use wgpu_types as wgt;

use crate::error::HostError;
#[cfg(target_os = "windows")]
use crate::error::RenderErrorKind;

#[cfg(target_os = "windows")]
use windows::Win32::Foundation::{CloseHandle, HANDLE};
#[cfg(target_os = "windows")]
use windows::Win32::Graphics::Direct3D12::{
    ID3D12Resource, D3D12_CPU_PAGE_PROPERTY_UNKNOWN, D3D12_HEAP_FLAG_SHARED, D3D12_HEAP_PROPERTIES,
    D3D12_HEAP_TYPE_DEFAULT, D3D12_MEMORY_POOL_UNKNOWN, D3D12_RESOURCE_DESC,
    D3D12_RESOURCE_DIMENSION_TEXTURE2D, D3D12_RESOURCE_FLAGS, D3D12_RESOURCE_STATE_RENDER_TARGET,
    D3D12_TEXTURE_LAYOUT_UNKNOWN,
};
#[cfg(target_os = "windows")]
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_B8G8R8A8_UNORM_SRGB, DXGI_SAMPLE_DESC,
};

/// An off-screen render target that backs onto a D3D12 shared resource.
///
/// Wraps a `wgpu::Texture` (used as the render pass attachment) and the
/// underlying `ID3D12Resource` that owns the GPU memory. The NT
/// `HANDLE` returned by [`SharedOffscreenTexture::shared_handle`] is
/// what gets handed to the D3D11 side via Flutter's TextureHandler.
///
/// # Thread safety
///
/// `HANDLE` is a raw `*mut c_void` and is not `Send`/`Sync` by
/// default. The actual concurrency contract is: `SharedOffscreenTexture`
/// lives behind the `Arc<Mutex<Live2dRenderer>>` shared between the
/// FRB bridge control surface (`RendererHandle`) and the frame-loop
/// worker thread. All accesses go through that mutex, so the D3D11/
/// D3D12 device interactions always happen on the thread that holds
/// the lock — and the lock enforces serialised access. The unsafe
/// `Send`/`Sync` impls below let the value move through the `Mutex`
/// while keeping D3D calls single-threaded at runtime; they do NOT
/// make concurrent device calls safe on their own.
pub struct SharedOffscreenTexture {
    /// Private (non-shared) render target. The model is rendered here;
    /// the result is copied to `wgpu_texture` (the shared D3D12
    /// resource) in a single GPU command so ANGLE never samples a
    /// partially-rendered frame. Declared first so its `Drop` runs
    /// before the shared texture's.
    private_texture: wgpu::Texture,
    /// Cached default view of `private_texture`. The texture is only
    /// rebuilt on resize, so creating the view once here avoids a
    /// per-frame `create_view` in the render hot path.
    private_view: wgpu::TextureView,
    /// Shared render target exposed to Flutter via NT handle. Non-owning
    /// HAL view of the same memory as `raw_resource`. Declared before
    /// `raw_resource` so its `Drop` runs first — any pending GPU work
    /// referencing the resource completes before COM decrements the
    /// refcount.
    pub(crate) wgpu_texture: wgpu::Texture,
    /// Owned `ID3D12Resource`. The `windows` crate decrements COM
    /// refcount automatically when this field drops. The field is
    /// never read directly — it exists solely to keep the underlying
    /// GPU memory alive for the lifetime of this struct.
    #[cfg(target_os = "windows")]
    #[expect(dead_code)]
    raw_resource: ID3D12Resource,
    /// NT handle from `ID3D12Device::CreateSharedHandle`, valid until
    /// close. Stored so the same instance is consistently returned
    /// across `shared_handle()` calls without re-minting names.
    #[cfg(target_os = "windows")]
    raw_handle: HANDLE,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) format: wgpu::TextureFormat,
    /// Strong `wgpu::Device` clone, declared LAST so it drops AFTER
    /// `raw_resource`. `raw_resource` is an `ID3D12Resource` we created
    /// directly on the raw D3D12 device (bypassing wgpu's resource
    /// tracker), so wgpu does not know it must keep the `ID3D12Device`
    /// alive for it. When this struct drops, `wgpu_texture` (the last
    /// wgpu-tracked resource referencing the device) drops before
    /// `raw_resource`; if nothing else held the device, wgpu would then
    /// destroy the `ID3D12Device`, and the following COM `Release` on
    /// `raw_resource` would dereference a freed device — an access
    /// violation inside `D3D12Core.dll` (+0x5308e) at process teardown.
    /// Keeping this clone alive until after `raw_resource` releases
    /// guarantees the device outlives the manual COM object.
    #[cfg(target_os = "windows")]
    #[expect(dead_code)]
    keep_device_alive: wgpu::Device,
}

// SAFETY: see the type-level doc comment. The raw `HANDLE` and
// `ID3D12Resource` are only touched under the `Arc<Mutex<Live2dRenderer>>`
// lock held by the bridge control surface and the frame-loop worker.
// Moving the value between threads (lock acquire / release, field
// moves on resize) is safe because each access is serialised; D3D
// device calls themselves are single-threaded at runtime.
#[cfg(target_os = "windows")]
unsafe impl Send for SharedOffscreenTexture {}
#[cfg(target_os = "windows")]
unsafe impl Sync for SharedOffscreenTexture {}

#[cfg(target_os = "windows")]
impl Drop for SharedOffscreenTexture {
    fn drop(&mut self) {
        // Close the NT handle minted by CreateSharedHandle. Consumers
        // (C++ TextureHandler) DuplicateHandle into their own scope, so
        // closing our original is safe and required — without this every
        // resize rebuild leaked a kernel handle holding a reference to
        // the D3D12 resource. Field drops (wgpu textures, COM release)
        // run after this body and are independent of the NT handle.
        if !self.raw_handle.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.raw_handle);
            }
        }
    }
}

impl SharedOffscreenTexture {
    /// Create a shared `ID3D12Resource` of the given dimensions and
    /// wrap it as a `wgpu::Texture` usable as a render target.
    ///
    /// `format` must be `Bgra8UnormSrgb` or `Bgra8Unorm`. The
    /// underlying shared resource is allocated with the matching typed
    /// DXGI format so Flutter's ANGLE backend can bind it.
    #[cfg(target_os = "windows")]
    pub fn new(
        device: &wgpu::Device,
        width: u32,
        height: u32,
        format: wgpu::TextureFormat,
    ) -> Result<Self, HostError> {
        if width == 0 || height == 0 {
            return Err(HostError::Render(RenderErrorKind::Wgpu(
                "SharedOffscreenTexture: zero-sized".into(),
            )));
        }

        // The shared D3D12 resource MUST use a fully TYPED DXGI format,
        // not `*_TYPELESS`. Once D3D11 opens the shared handle, Flutter's
        // GL backend (ANGLE) binds that ID3D11Texture2D as an EGL surface
        // via `EGL_D3D_TEXTURE_ANGLE`. ANGLE maps the texture's DXGI
        // format to a GL internal format and REJECTS `*_TYPELESS`
        // (no unambiguous component type), which surfaced as
        // `Binding D3D surface failed` in external_texture_d3d.cc and a
        // black texture. A typed format is legal for cross-API D3D12<->
        // D3D11 sharing and satisfies ANGLE. The DXGI format must match
        // the wgpu wrap `format` exactly so the RTV wgpu creates is valid
        // on the typed resource (a typed UNORM resource cannot host an
        // sRGB view, and vice versa).
        let dxgi_format = match format {
            wgpu::TextureFormat::Bgra8Unorm => DXGI_FORMAT_B8G8R8A8_UNORM,
            wgpu::TextureFormat::Bgra8UnormSrgb => DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
            other => {
                return Err(HostError::Render(RenderErrorKind::Wgpu(format!(
                    "SharedOffscreenTexture: format {:?} not supported; \
                     shared resources require a typed BGRA8 D3D12 format \
                     matching the wgpu wrap format.",
                    other
                ))));
            }
        };

        // `as_hal` is `unsafe` and returns
        // `Option<impl Deref<Target = ...Device>>`. Deref to the concrete
        // `wgpu::hal::dx12::Device` so we can pass the reference to
        // associated functions like `texture_from_raw`.
        let hal_device = unsafe { device.as_hal::<Dx12Api>() }.ok_or_else(|| {
            HostError::Render(RenderErrorKind::Wgpu(
                "SharedOffscreenTexture: wgpu device is not backed by D3D12".into(),
            ))
        })?;
        let hal_device_ref: &wgpu::hal::dx12::Device = &hal_device;

        // Stage 1 diagnostic: print the D3D12 adapter LUID so we can
        // confirm whether wgpu's `HighPerformance` selection matches the
        // default D3D11 adapter that TextureHandler creates on the C++
        // side. Cross-adapter sharing requires either
        // D3D12_RESOURCE_FLAG_ALLOW_CROSS_ADAPTER or matching LUIDs;
        // without either, D3D11's `OpenSharedResource1` rejects the
        // NT handle with E_INVALIDARG.
        let luid = unsafe { hal_device_ref.raw_device().GetAdapterLuid() };
        log::debug!(
            "[live2d/texture] SharedOffscreenTexture: D3D12 adapter LUID = \
             {{HighPart={}, LowPart={}}}",
            luid.HighPart,
            luid.LowPart
        );

        let heap_props = D3D12_HEAP_PROPERTIES {
            // D3D11 can only open a shared D3D12 resource whose implicit
            // heap description it can map to an equivalent D3D11
            // allocation. That means a DEFAULT heap: a CUSTOM heap with
            // an explicit CPU page property / memory pool (e.g. L1 +
            // NOT_AVAILABLE) is not representable in D3D11, so
            // `OpenSharedResource1` rejects the NT handle with
            // E_INVALIDARG even though `CreateSharedHandle` succeeds. For
            // a DEFAULT heap the CPU page property and memory pool
            // preference MUST be UNKNOWN.
            Type: D3D12_HEAP_TYPE_DEFAULT,
            CPUPageProperty: D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
            MemoryPoolPreference: D3D12_MEMORY_POOL_UNKNOWN,
            CreationNodeMask: 0,
            VisibleNodeMask: 0,
        };
        let resource_desc = D3D12_RESOURCE_DESC {
            Dimension: D3D12_RESOURCE_DIMENSION_TEXTURE2D,
            Alignment: 0,
            Width: width as u64,
            Height: height,
            DepthOrArraySize: 1,
            MipLevels: 1,
            Format: dxgi_format,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Layout: D3D12_TEXTURE_LAYOUT_UNKNOWN,
            // Compose the D3D12_RESOURCE_FLAGS bitfield manually. Per
            // d3d12.h / the D3D12_RESOURCE_FLAGS enum:
            //   * D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET       = 0x1
            //   * D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS = 0x20
            // RENDER_TARGET lets the resource be bound as an RTV (so
            // CreateCommittedResource accepts RENDER_TARGET as the
            // initial state and wgpu can wrap it as a color target).
            // ALLOW_SIMULTANEOUS_ACCESS is REQUIRED for cross-API
            // sharing: the D3D12 queue rewrites this texture every frame
            // while the D3D11 side (Flutter) reads it without a keyed
            // mutex. Without it, D3D11's OpenSharedResource1 rejects the
            // NT handle with E_INVALIDARG (0x80070057) even though
            // CreateSharedHandle succeeds.
            // NOTE: there is NO `ALLOW_SHARED` resource flag — sharing
            // is enabled by the D3D12_HEAP_FLAG_SHARED heap flag passed
            // to CreateCommittedResource below. The previous 0x4 bit was
            // ALLOW_UNORDERED_ACCESS (mislabeled as "ALLOW_SHARED"),
            // which is unsupported for B8G8R8A8 and irrelevant to
            // sharing.
            Flags: D3D12_RESOURCE_FLAGS(0x1 | 0x20),
        };

        let raw_resource: ID3D12Resource = unsafe {
            let raw_device = hal_device_ref.raw_device();
            let mut resource: Option<ID3D12Resource> = None;
            raw_device
                .CreateCommittedResource(
                    &heap_props,
                    // D3D12_HEAP_FLAG_SHARED is required for
                    // `ID3D12Device::CreateSharedHandle` to succeed on a
                    // committed resource — without it the call returns
                    // `E_INVALIDARG` (0x80070057).
                    D3D12_HEAP_FLAG_SHARED,
                    &resource_desc,
                    D3D12_RESOURCE_STATE_RENDER_TARGET,
                    None,
                    &mut resource,
                )
                .map_err(|e| {
                    HostError::Render(RenderErrorKind::Wgpu(format!(
                        "SharedOffscreenTexture: CreateCommittedResource failed: {e}"
                    )))
                })?;
            resource.ok_or_else(|| {
                HostError::Render(RenderErrorKind::Wgpu(
                    "SharedOffscreenTexture: CreateCommittedResource returned null".into(),
                ))
            })?
        };

        // Export an NT shared handle. D3D12 uses name-based sharing
        // (`ID3D12Device::CreateSharedHandle(pobject, ...)`) but in
        // practice that returns a process-bound NT handle that the
        // D3D11 side opens with `ID3D11Device::OpenSharedResource`.
        // Because the offscreen texture is re-created whenever its size
        // changes, we mint a unique name per call to avoid
        // `E_ALREADY_EXISTS` if the previous handle is still
        // referenced.
        let raw_handle: HANDLE = unsafe {
            use std::sync::atomic::{AtomicU64, Ordering};
            let raw_device = hal_device_ref.raw_device();
            static HANDLE_COUNTER: AtomicU64 = AtomicU64::new(0);
            let counter = HANDLE_COUNTER.fetch_add(1, Ordering::Relaxed);
            // D3D12 spec requires UNICODE-only names. We mint a unique
            // UNICODE string per offscreen instance to avoid
            // `E_ALREADY_EXISTS` collisions across rebuilds. The D3D12
            // namespace is session-private by default; an empty or
            // unscoped name works within a single session.
            let unique = format!("Live2DViewerSharedTexture_w{width}_h{height}_{counter}");
            let wide: Vec<u16> = unique.encode_utf16().chain(std::iter::once(0)).collect();
            // Use GENERIC_ALL — the documented common value for D3D12 shared
            // handles and the value Microsoft samples use for cross-API
            // D3D11<->D3D12 shared textures. Earlier experiments with
            // GENERIC_READ | GENERIC_WRITE regressed CreateSharedHandle to
            // E_INVALIDARG. Keep the original mask; the cross-device bind
            // story (ANGLE on its own D3D11 device opening the shared
            // handle) is the working production path.
            const SHARED_ACCESS: u32 = 0x10000000; // GENERIC_ALL
            let handle = raw_device
                .CreateSharedHandle(
                    &raw_resource,
                    None,
                    SHARED_ACCESS,
                    windows::core::PCWSTR(wide.as_ptr()),
                )
                .map_err(|e| {
                    HostError::TextureExport(format!(
                        "SharedOffscreenTexture: ID3D12Device::CreateSharedHandle failed: {e}"
                    ))
                })?;
            // The kernel copies the name string during the call; `wide`
            // just needs to stay alive until here and then drops normally.
            let _ = &wide;
            handle
        };

        let hal_texture = unsafe {
            wgpu::hal::dx12::Device::texture_from_raw(
                raw_resource.clone(),
                format,
                wgpu::TextureDimension::D2,
                wgt_extent(width, height),
                1,
                1,
            )
        };

        let texture_descriptor = wgpu::TextureDescriptor {
            label: Some("shared_offscreen"),
            size: wgt_extent(width, height),
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        };

        let wgpu_texture = unsafe {
            device.create_texture_from_hal::<Dx12Api>(
                hal_texture,
                &texture_descriptor,
                wgt::TextureUses::COLOR_TARGET,
            )
        };

        // Private (non-shared) render target. The model is rendered here;
        // the result is copied to the shared texture in a single GPU
        // command so ANGLE never samples a partially-rendered frame.
        let private_texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("private_render_target"),
            size: wgt_extent(width, height),
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let private_view = private_texture.create_view(&wgpu::TextureViewDescriptor::default());

        Ok(Self {
            private_texture,
            private_view,
            wgpu_texture,
            raw_resource,
            raw_handle,
            width,
            height,
            format,
            keep_device_alive: device.clone(),
        })
    }

    /// The wrapped `wgpu::Texture` — the shared D3D12 resource exposed
    /// to Flutter. Use [`render_target`] for the color attachment.
    pub fn texture(&self) -> &wgpu::Texture {
        &self.wgpu_texture
    }

    /// The private (non-shared) render target used as the color
    /// attachment in the offscreen render pass. After rendering, call
    /// [`copy_to_shared`] to transfer the result to the shared texture.
    pub fn render_target(&self) -> &wgpu::Texture {
        &self.private_texture
    }

    /// Cached default view of the private render target. Prefer this
    /// over `render_target().create_view(..)` in per-frame code.
    pub fn render_target_view(&self) -> &wgpu::TextureView {
        &self.private_view
    }

    /// Copy the private render target to the shared D3D12 texture.
    ///
    /// Call this after the render pass completes, in the same command
    /// encoder, so the shared texture is updated in a single GPU
    /// command. ANGLE never observes a partially-rendered frame.
    pub fn copy_to_shared(&self, encoder: &mut wgpu::CommandEncoder) {
        encoder.copy_texture_to_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &self.private_texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyTextureInfo {
                texture: &self.wgpu_texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgt_extent(self.width, self.height),
        );
    }

    /// Lazily obtain a fresh NT shared handle for this resource.
    ///
    /// `windows` 0.62 wraps `GetSharedHandle` to return
    /// `Result<HANDLE>` directly with no out-parameter. TextureHandler
    /// clones the kernel handle into its own scope before returning.
    #[cfg(target_os = "windows")]
    pub fn shared_handle(&self) -> Result<HANDLE, HostError> {
        // The handle was minted by `ID3D12Device::CreateSharedHandle`
        // in `new()` and stored on the instance. Re-querying via
        // `IDXGIResource::GetSharedHandle` would only return whatever
        // was associated with the *current* IDXGIResource name, which
        // is null for a fresh resource — and D3D12's `GetSharedHandle`
        // path returns `NULL` without error in that case. Cache the
        // handle explicitly so the FRB-exposed value is always the
        // NT handle we minted.
        Ok(self.raw_handle)
    }

    pub fn width(&self) -> u32 {
        self.width
    }
    pub fn height(&self) -> u32 {
        self.height
    }
    pub fn format(&self) -> wgpu::TextureFormat {
        self.format
    }

    /// Build a `SharedTextureHandle` DTO that Flutter consumes via FRB.
    #[cfg(target_os = "windows")]
    pub fn texture_export_handle(&self) -> crate::render::texture_export::SharedTextureHandle {
        use crate::render::texture_export::SharedTextureHandle;
        let handle = self.shared_handle().unwrap_or(HANDLE(std::ptr::null_mut()));
        SharedTextureHandle {
            width: self.width,
            height: self.height,
            native_handle: handle.0 as u64,
        }
    }

    #[cfg(not(target_os = "windows"))]
    pub fn texture_export_handle(&self) -> crate::render::texture_export::SharedTextureHandle {
        crate::render::texture_export::make_dummy_handle(self.width, self.height)
    }

    /// Stub for non-Windows targets so the rest of the crate compiles.
    #[cfg(not(target_os = "windows"))]
    pub fn new(
        _device: &wgpu::Device,
        _width: u32,
        _height: u32,
        _format: wgpu::TextureFormat,
    ) -> Result<Self, HostError> {
        Err(HostError::TextureExport(
            "SharedOffscreenTexture not supported on non-Windows".into(),
        ))
    }
}

fn wgt_extent(width: u32, height: u32) -> wgpu::Extent3d {
    wgpu::Extent3d {
        width,
        height,
        depth_or_array_layers: 1,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Format guard: only BGRA variants are accepted.
    #[test]
    #[cfg(target_os = "windows")]
    fn unsupported_format_rejected() {
        let Ok(device) = pollster::block_on(async {
            crate::render::device::RenderContext::new_headless()
                .await
                .map(|ctx| ctx.device)
        }) else {
            eprintln!("skip: no GPU available");
            return;
        };
        let r = SharedOffscreenTexture::new(&device, 64, 64, wgpu::TextureFormat::Rgba8UnormSrgb);
        assert!(r.is_err(), "Rgba8 must be rejected for shared textures");
    }

    /// Zero-sized request rejected before any D3D12 work.
    #[test]
    #[cfg(target_os = "windows")]
    fn zero_sized_rejected() {
        let Ok(device) = pollster::block_on(async {
            crate::render::device::RenderContext::new_headless()
                .await
                .map(|ctx| ctx.device)
        }) else {
            eprintln!("skip: no GPU available");
            return;
        };
        let r = SharedOffscreenTexture::new(&device, 0, 64, wgpu::TextureFormat::Bgra8UnormSrgb);
        assert!(r.is_err());
    }

    /// `Rgba8UnormSrgb` placeholder does not depend on Windows APIs.
    #[test]
    fn dummy_handle_roundtrip() {
        let h = crate::render::texture_export::make_dummy_handle(1280, 720);
        assert_eq!(h.width, 1280);
        assert_eq!(h.height, 720);
    }
}
