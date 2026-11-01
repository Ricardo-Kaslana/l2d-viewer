#include "texture_handler.h"

#include <cstdio>
#include <wrl/client.h>
#include <dxgi1_2.h>
#include <dxgi1_4.h>
#include <dxgi1_6.h>

namespace {

// Select the high-performance DXGI adapter (the discrete GPU on a
// dual-GPU laptop). wgpu creates its D3D12 device with
// `PowerPreference::HighPerformance` on DX12 (see
// crates/mocari_host/src/render/device.rs), so the shared resource
// lives on that adapter. If D3D11 lands on a *different* adapter (the
// default the OS picks for `D3D11CreateDevice(nullptr, ...)` is often
// the integrated GPU), `OpenSharedResource1` rejects the NT handle
// with E_INVALIDARG. Pinning D3D11 to the same HighPerformance adapter
// makes the two devices agree on the GPU.
//
// Returns nullptr when IDXGIFactory6 is unavailable (pre-Windows 10
// 1803) or enumeration fails; callers then fall back to the default
// adapter selection.
Microsoft::WRL::ComPtr<IDXGIAdapter1> SelectHighPerformanceAdapter() {
  Microsoft::WRL::ComPtr<IDXGIFactory1> factory1;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory1)))) {
    return nullptr;
  }
  Microsoft::WRL::ComPtr<IDXGIFactory6> factory6;
  if (FAILED(factory1.As(&factory6)) || !factory6) {
    return nullptr;
  }
  Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
  if (FAILED(factory6->EnumAdapterByGpuPreference(
          0, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
          IID_PPV_ARGS(&adapter)))) {
    return nullptr;
  }
  return adapter;
}

}  // namespace

TextureHandler::TextureHandler() = default;

TextureHandler::~TextureHandler() {
  ReleaseTexture();
}

bool TextureHandler::Initialize() {
  if (device_) {
    return true;
  }

  D3D_FEATURE_LEVEL feature_levels[] = {
      D3D_FEATURE_LEVEL_11_1,
      D3D_FEATURE_LEVEL_11_0,
  };

  UINT base_flags = 0;
#ifdef _DEBUG
  // Try the debug layer first - useful when the DirectX SDK is
  // installed locally. If the SDK is not installed the call fails
  // (typically with E_INVALIDARG / DXGI_ERROR_SDK_COMPONENT_MISSING);
  // we then retry without the debug flag below so users without the
  // SDK can still see the model render.
  base_flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif

  D3D_FEATURE_LEVEL obtained_feature_level;
  Microsoft::WRL::ComPtr<ID3D11Device> device;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context;

  // Pin D3D11 to the same GPU wgpu selected (HighPerformance / discrete
  // on dual-GPU laptops). Without this the two devices can land on
  // different adapters and OpenSharedResource1 fails with E_INVALIDARG.
  Microsoft::WRL::ComPtr<IDXGIAdapter1> hp_adapter =
      SelectHighPerformanceAdapter();
  if (hp_adapter) {
    DXGI_ADAPTER_DESC1 hp_desc{};
    if (SUCCEEDED(hp_adapter->GetDesc1(&hp_desc))) {
      std::fprintf(stderr,
                   "[live2d/texture] TextureHandler: pinning D3D11 to "
                   "HighPerformance adapter = %ls (LUID {HighPart=%ld, "
                   "LowPart=%lu})\n",
                   hp_desc.Description, hp_desc.AdapterLuid.HighPart,
                   hp_desc.AdapterLuid.LowPart);
    }
  } else {
    std::fprintf(stderr,
                 "[live2d/texture] TextureHandler: no HighPerformance "
                 "adapter available; falling back to default adapter\n");
  }

  auto try_create = [&](UINT flags) -> HRESULT {
    device.Reset();
    context.Reset();
    // When an explicit adapter is supplied the DriverType MUST be
    // D3D_DRIVER_TYPE_UNKNOWN; passing D3D_DRIVER_TYPE_HARDWARE with a
    // non-null adapter is itself E_INVALIDARG.
    HRESULT hr = D3D11CreateDevice(
        hp_adapter.Get(),                                    // Adapter
        hp_adapter ? D3D_DRIVER_TYPE_UNKNOWN                 // DriverType
                   : D3D_DRIVER_TYPE_HARDWARE,
        nullptr,                    // Software
        flags,                      // Flags
        feature_levels,             // pFeatureLevels
        ARRAYSIZE(feature_levels),  // FeatureLevels
        D3D11_SDK_VERSION,          // SDKVersion
        &device,                    // ppDevice
        &obtained_feature_level,    // pFeatureLevel
        &context                    // ppImmediateContext
    );
    if (FAILED(hr)) {
      // Fallback to WARP if hardware creation fails. WARP is a software
      // adapter and requires a null IDXGIAdapter.
      hr = D3D11CreateDevice(
          nullptr,
          D3D_DRIVER_TYPE_WARP,
          nullptr,
          flags,
          feature_levels,
          ARRAYSIZE(feature_levels),
          D3D11_SDK_VERSION,
          &device,
          &obtained_feature_level,
          &context
      );
    }
    return hr;
  };

  HRESULT hr = try_create(base_flags);
  if (FAILED(hr) && (base_flags & D3D11_CREATE_DEVICE_DEBUG) != 0) {
    // The DirectX SDK debug layer is not installed. Retry without
    // it so users without the SDK can still see the model render.
    std::fprintf(stderr,
                 "[live2d/texture] TextureHandler: D3D11 device creation "
                 "with DEBUG flag failed (hr=0x%08lx); retrying without "
                 "D3D11_CREATE_DEVICE_DEBUG\n",
                 static_cast<unsigned long>(hr));
    hr = try_create(0);
  }

  if (FAILED(hr)) {
    std::fprintf(stderr,
                 "[live2d/texture] TextureHandler: D3D11CreateDevice "
                 "failed with hr=0x%08lx - texture registration disabled\n",
                 static_cast<unsigned long>(hr));
    return false;
  }

  // D3D11CreateDevice always returns the latest ID3D11Device version, which
  // implements ID3D11Device1. We need Device1 specifically for
  // OpenSharedResource1 (the only API that accepts D3D12's NT HANDLE).
  Microsoft::WRL::ComPtr<ID3D11Device1> device1;
  hr = device.As(&device1);
  if (FAILED(hr) || !device1) {
    std::fprintf(stderr,
                 "[live2d/texture] TextureHandler: QI to ID3D11Device1 "
                 "failed with hr=0x%08lx - texture registration disabled\n",
                 static_cast<unsigned long>(hr));
    return false;
  }

  device_ = device1;
  context_ = context;

  // Stage 1 diagnostic: log the adapter that D3D11 landed on so we can
  // compare it against the D3D12 LUID printed on the Rust side. If the
  // two differ, cross-API shared resources will fail to open on the
  // D3D11 device and we need to pin D3D11 to the same adapter via
  // IDXGIFactory4::EnumAdapterByLuid (Stage 2) or wrap D3D11 over D3D12
  // via D3D11On12CreateDevice (Stage 3).
  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  if (SUCCEEDED(device_.As(&dxgi_device))) {
    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    if (SUCCEEDED(dxgi_device->GetAdapter(&adapter))) {
      DXGI_ADAPTER_DESC desc{};
      HRESULT hr_desc = adapter->GetDesc(&desc);
      if (SUCCEEDED(hr_desc)) {
        std::fprintf(
            stderr,
            "[live2d/texture] TextureHandler: D3D11 adapter = %ls "
            "(LUID {{HighPart=%lu, LowPart=%lu}}, VendorId=0x%04x, "
            "DeviceId=0x%04x)\n",
            desc.Description,
            desc.AdapterLuid.HighPart, desc.AdapterLuid.LowPart,
            desc.VendorId, desc.DeviceId);
      } else {
        std::fprintf(stderr,
                     "[live2d/texture] TextureHandler: IDXGIAdapter::GetDesc "
                     "failed with hr=0x%08lx\n",
                     static_cast<unsigned long>(hr_desc));
      }
    } else {
      std::fprintf(stderr,
                   "[live2d/texture] TextureHandler: IDXGIDevice::GetAdapter "
                   "failed\n");
    }
  } else {
    std::fprintf(stderr,
                 "[live2d/texture] TextureHandler: QI to IDXGIDevice failed\n");
  }

  return true;
}

bool TextureHandler::OpenSharedHandle(uint64_t handle) {
  if (!device_) {
    std::fprintf(stderr, "[live2d/texture] OpenSharedHandle: device_ is null\n");
    return false;
  }

  HANDLE src_handle = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(handle));
  if (!src_handle || src_handle == INVALID_HANDLE_VALUE) {
    std::fprintf(stderr,
                 "[live2d/texture] OpenSharedHandle: handle 0x%llx is null or INVALID_HANDLE_VALUE\n",
                 static_cast<unsigned long long>(handle));
    return false;
  }

  // Duplicate the NT handle into our own handle table. The original
  // handle is owned by the Rust side (minted by
  // `ID3D12Device::CreateSharedHandle`); duplicating gives us an
  // independent handle we can hand to Flutter/ANGLE without Rust
  // closing the source from under us. We use `DUPLICATE_SAME_ACCESS`
  // so the duplicate inherits the `GENERIC_ALL` access mask the Rust
  // side requested, which ANGLE needs to open the resource.
  //
  // Everything below works on LOCAL variables only. We do not touch the
  // shared {shared_nt_handle_, width_, height_} triple until the atomic
  // swap under state_mutex_ at the end, so the raster thread
  // (ObtainDescriptor) never sees a half-updated handle+dimensions.
  HANDLE dup_handle = nullptr;
  HANDLE current_process = GetCurrentProcess();
  if (!DuplicateHandle(current_process, src_handle,
                       current_process, &dup_handle,
                       0, FALSE, DUPLICATE_SAME_ACCESS)) {
    std::fprintf(stderr,
                 "[live2d/texture] OpenSharedHandle: DuplicateHandle failed "
                 "for handle=0x%llx with GLE=%lu\n",
                 static_cast<unsigned long long>(handle),
                 static_cast<unsigned long>(GetLastError()));
    return false;
  }

  // Open the resource *on our own D3D11 device* purely to read its
  // dimensions. We release it immediately afterwards -- the texture
  // that ANGLE samples is opened by ANGLE on its own device using the
  // duplicated NT handle.
  Microsoft::WRL::ComPtr<ID3D11Resource> resource;
  HRESULT hr = device_->OpenSharedResource1(
      dup_handle,
      IID_PPV_ARGS(resource.GetAddressOf())
  );
  if (FAILED(hr)) {
    std::fprintf(stderr,
                 "[live2d/texture] OpenSharedHandle: ID3D11Device1::OpenSharedResource1 "
                 "failed for handle=0x%llx with hr=0x%08lx\n",
                 static_cast<unsigned long long>(handle),
                 static_cast<unsigned long>(hr));
    CloseHandle(dup_handle);
    return false;
  }

  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
  hr = resource.As(&texture);
  if (FAILED(hr) || !texture) {
    std::fprintf(stderr,
                 "[live2d/texture] OpenSharedHandle: ID3D11Resource -> ID3D11Texture2D cast "
                 "failed with hr=0x%08lx\n",
                 static_cast<unsigned long>(hr));
    CloseHandle(dup_handle);
    return false;
  }

  D3D11_TEXTURE2D_DESC desc{};
  texture->GetDesc(&desc);
  const uint32_t new_width = desc.Width;
  const uint32_t new_height = desc.Height;
  std::fprintf(stderr,
               "[live2d/texture] OpenSharedHandle: imported %ux%u DXGI format=%u "
               "BindFlags=0x%08x MiscFlags=0x%08x Usage=%u\n",
               new_width, new_height, desc.Format, desc.BindFlags, desc.MiscFlags,
               static_cast<unsigned>(desc.Usage));

  // Atomic swap under the lock. Close the previous-generation handle now
  // (a full generation has elapsed since it was last handed out), demote
  // the current handle to prev_nt_handle_, and install the new handle.
  // Deferring the current handle's close by one generation keeps a raster
  // read that grabbed it just before this swap pointing at a live handle.
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (prev_nt_handle_) {
      CloseHandle(prev_nt_handle_);
    }
    prev_nt_handle_ = shared_nt_handle_;
    shared_nt_handle_ = dup_handle;
    width_ = new_width;
    height_ = new_height;
  }

  std::fprintf(stderr,
               "[live2d/texture] OpenSharedHandle: duplicated NT handle 0x%p "
               "for DxgiSharedHand surface type\n",
               dup_handle);
  return true;
}

uint32_t TextureHandler::GetWidth() const {
  std::lock_guard<std::mutex> lock(state_mutex_);
  return width_;
}

uint32_t TextureHandler::GetHeight() const {
  std::lock_guard<std::mutex> lock(state_mutex_);
  return height_;
}

int64_t TextureHandler::RegisterWithFlutter(flutter::TextureRegistrar* registrar) {
  if (!registrar || !shared_nt_handle_) {
    return -1;
  }

  if (flutter_texture_id_ != -1) {
    return flutter_texture_id_;
  }

  // Hand ANGLE the NT handle directly (surface type
  // `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`). ANGLE opens the
  // resource on *its own* D3D11 device, which avoids the cross-device
  // `eglBindTexImage` failure we saw when opening the texture on a
  // private D3D11 device. See docs/ARCHITECTURE.md (Windows path).
  texture_variant_ = std::make_unique<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(
          kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
          [this](size_t width, size_t height)
              -> const FlutterDesktopGpuSurfaceDescriptor* {
            return this->ObtainDescriptor(width, height);
          }));

  flutter_texture_id_ = registrar->RegisterTexture(texture_variant_.get());

  return flutter_texture_id_;
}

void TextureHandler::UnregisterFromFlutter(flutter::TextureRegistrar* registrar) {
  if (!registrar || flutter_texture_id_ == -1) {
    return;
  }

  registrar->UnregisterTexture(flutter_texture_id_, nullptr);
  flutter_texture_id_ = -1;
  texture_variant_.reset();
}

bool TextureHandler::MarkFrameAvailable(flutter::TextureRegistrar* registrar) {
  if (!registrar || flutter_texture_id_ == -1) {
    return false;
  }
  // No copy needed -- ANGLE samples the D3D12-shared resource directly
  // via the NT handle. wgpu writes the resource on its D3D12 device
  // while ANGLE reads it on its D3D11 device; the shared-resource
  // contract (ALLOW_SIMULTANEOUS_ACCESS on the Rust side) permits this.
  return registrar->MarkTextureFrameAvailable(flutter_texture_id_);
}

void TextureHandler::ReleaseTexture() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (shared_nt_handle_) {
    CloseHandle(shared_nt_handle_);
    shared_nt_handle_ = nullptr;
  }
  if (prev_nt_handle_) {
    CloseHandle(prev_nt_handle_);
    prev_nt_handle_ = nullptr;
  }
  width_ = 0;
  height_ = 0;
}

const FlutterDesktopGpuSurfaceDescriptor* TextureHandler::ObtainDescriptor(
    size_t width, size_t height) {
  // Runs on the raster thread. Take a consistent snapshot of the
  // {handle, width, height} triple under the lock so we never pair a
  // handle from one generation with dimensions from another while the
  // platform thread swaps them in OpenSharedHandle.
  HANDLE handle_snapshot = nullptr;
  uint32_t width_snapshot = 0;
  uint32_t height_snapshot = 0;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    handle_snapshot = shared_nt_handle_;
    width_snapshot = width_;
    height_snapshot = height_;
  }

  if (!handle_snapshot) {
    return nullptr;
  }

  static thread_local FlutterDesktopGpuSurfaceDescriptor descriptor;
  descriptor = {};
  descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  // For `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle` the handle
  // field is the NT HANDLE minted by D3D12's CreateSharedHandle.
  descriptor.handle = handle_snapshot;
  descriptor.width = width_snapshot;
  descriptor.height = height_snapshot;
  descriptor.visible_width = width_snapshot;
  descriptor.visible_height = height_snapshot;
  descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
  descriptor.release_callback = nullptr;
  descriptor.release_context = nullptr;
  return &descriptor;
}