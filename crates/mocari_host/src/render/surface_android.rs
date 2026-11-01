//! Android surface creation from ANativeWindow via wgpu Vulkan backend.

use crate::error::{HostError, RenderErrorKind};

/// Create a wgpu `Surface` from a raw `ANativeWindow` pointer.
///
/// # Safety
///
/// `window_ptr` must be a valid, non-null `ANativeWindow*` obtained from
/// `ANativeWindow_fromSurface`. The caller retains ownership of the
/// underlying window; the surface borrows it for its lifetime.
pub unsafe fn create_surface_from_native_window(
    instance: &wgpu::Instance,
    window_ptr: u64,
) -> Result<wgpu::Surface<'static>, HostError> {
    use raw_window_handle::{
        AndroidDisplayHandle, AndroidNdkWindowHandle, RawDisplayHandle, RawWindowHandle,
    };

    let ptr = window_ptr as *mut std::ffi::c_void;
    if ptr.is_null() {
        return Err(HostError::Render(RenderErrorKind::Wgpu(
            "create_surface_from_native_window: null ANativeWindow pointer".into(),
        )));
    }

    let handle = AndroidNdkWindowHandle::new(std::ptr::NonNull::new(ptr).unwrap());
    let raw_handle = RawWindowHandle::AndroidNdk(handle);
    let raw_display = RawDisplayHandle::Android(AndroidDisplayHandle::new());

    let target = wgpu::SurfaceTargetUnsafe::RawHandle {
        raw_display_handle: Some(raw_display),
        raw_window_handle: raw_handle,
    };

    instance.create_surface_unsafe(target).map_err(|e| {
        HostError::Render(RenderErrorKind::Wgpu(format!(
            "create_surface_unsafe failed: {e}"
        )))
    })
}
