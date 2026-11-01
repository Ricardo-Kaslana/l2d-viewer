#ifndef TEXTURE_HANDLER_H_
#define TEXTURE_HANDLER_H_

#include <d3d11_1.h>
#include <flutter/texture_registrar.h>
#include <memory>
#include <mutex>
#include <cstdint>
#include <wrl/client.h>

// Manages a D3D11 device and imports shared textures for Flutter rendering.
class TextureHandler {
 public:
  TextureHandler();
  ~TextureHandler();

  // Initialize the D3D11 device and immediate context.
  // Returns true on success.
  bool Initialize();

  // Open a shared texture handle (from D3D12 shared resource).
  // |handle| is the NT handle value exported by SharedTextureHandle
  // (minted by `ID3D12Device::CreateSharedHandle`). We duplicate it
  // into our own process handle table and hand the duplicate to
  // Flutter as a `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`,
  // letting ANGLE open it on its own D3D11 device (the cross-device
  // `eglBindTexImage` path was failing for a texture we opened on a
  // private D3D11 device; see docs/ARCHITECTURE.md).
  bool OpenSharedHandle(uint64_t handle);

  // Get the width of the currently opened texture.
  // Returns 0 if no texture is open.
  uint32_t GetWidth() const;

  // Get the height of the currently opened texture.
  // Returns 0 if no texture is open.
  uint32_t GetHeight() const;

  // Register the current D3D11 texture with Flutter's texture registrar.
  // Returns the Flutter texture ID, or -1 on failure.
  int64_t RegisterWithFlutter(flutter::TextureRegistrar* registrar);

  // Unregister the texture from Flutter.
  void UnregisterFromFlutter(flutter::TextureRegistrar* registrar);

  // Notify Flutter that a new frame is available.
  bool MarkFrameAvailable(flutter::TextureRegistrar* registrar);

  // Release the D3D11 texture (but keep the device).
  void ReleaseTexture();

 private:
  // D3D11 Device1. Retained for diagnostic purposes (adapter LUID
  // comparison vs. the D3D12 device on the Rust side) and as a
  // fallback path if the DxgiSharedHandle route turns out to be
  // unsupported by the installed ANGLE.
  Microsoft::WRL::ComPtr<ID3D11Device1> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;

  // The duplicated NT handle for the D3D12 shared resource. We hand
  // this to Flutter via `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`
  // so ANGLE opens it on its own D3D11 device, avoiding the cross-device
  // `eglBindTexImage` failure we saw when opening the texture on a
  // private D3D11 device.
  //
  // Concurrency: `OpenSharedHandle`/`ReleaseTexture` run on the Flutter
  // platform thread, while `ObtainDescriptor` (the GpuSurfaceTexture
  // callback) runs on the raster thread. `state_mutex_` guards the
  // triple {shared_nt_handle_, width_, height_} so the raster thread
  // never observes a half-swapped handle+dimensions during a resize or
  // model switch. `prev_nt_handle_` holds the handle from the previous
  // generation: OpenSharedHandle closes it only when swapping in the
  // *next* handle, so a raster read that grabbed the old handle just
  // before the swap still points at a live NT handle for that frame
  // (one-generation deferral avoids a use-after-CloseHandle -> fastfail).
  mutable std::mutex state_mutex_;
  HANDLE shared_nt_handle_ = nullptr;
  HANDLE prev_nt_handle_ = nullptr;

  // Cached texture dimensions. Guarded by state_mutex_.
  uint32_t width_ = 0;
  uint32_t height_ = 0;

  // Flutter texture ID.
  int64_t flutter_texture_id_ = -1;

  // GPU surface texture wrapper for Flutter, held as the TextureVariant
  // (std::variant) that TextureRegistrar::RegisterTexture expects.
  std::unique_ptr<flutter::TextureVariant> texture_variant_;

  // Internal callback that provides the surface descriptor to Flutter.
  const FlutterDesktopGpuSurfaceDescriptor* ObtainDescriptor(size_t width,
                                                             size_t height);
};

#endif  // TEXTURE_HANDLER_H_
