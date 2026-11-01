#include "flutter_window.h"

#include <optional>
#include <utility>

#include <flutter/encodable_value.h>
#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar.h>

#include "flutter/generated_plugin_registrant.h"
#include "../texture_handler.h"

namespace {

// The StandardMethodCodec encodes Dart `int` as either Int32 (when the
// value fits in `int32_t`) or Int64 otherwise. NT handles from
// `ID3D12Device::CreateSharedHandle` frequently have the high bit set
// (e.g. 0x80000040), so Dart serializes them as Int64. Earlier code
// used `std::get<int32_t>` which threw `bad_variant_access` on the
// Int64 case; this helper accepts either encoding and returns the
// value as a signed 64-bit integer (suitable for reinterpreting as
// `HANDLE` / `uintptr_t`).
int64_t ReadInt64Arg(const flutter::EncodableValue& value) {
  if (const int32_t* p = std::get_if<int32_t>(&value)) {
    return static_cast<int64_t>(*p);
  }
  if (const int64_t* p = std::get_if<int64_t>(&value)) {
    return *p;
  }
  return -1;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Wire up the Live2D shared-texture MethodChannel.
  // The channel name MUST match `TextureMethodChannel` in
  // `app/lib/bridge/texture_method_channel.dart`.
  texture_handler_ = std::make_unique<TextureHandler>();
  if (!texture_handler_->Initialize()) {
    // Texture registration is unavailable, but the rest of the app
    // can still run. The Dart side will see -1 from `register`.
    texture_handler_.reset();
  }

  flutter::BinaryMessenger* messenger =
      flutter_controller_->engine()->messenger();
  // The TextureRegistrar lives on the PluginRegistrar. We obtain the
  // registrar ref via the engine, then ask the PluginRegistrarManager
  // singleton to wrap it as a `PluginRegistrar` whose
  // `texture_registrar()` accessor returns the TextureRegistrar we
  // hand to TextureHandler.
  FlutterDesktopPluginRegistrarRef registrar_ref =
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "live2d_viewer_texture");
  flutter::PluginRegistrar* plugin_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrar>(registrar_ref);
  flutter::TextureRegistrar* registrar = plugin_registrar->texture_registrar();

  static const char kChannelName[] = "live2d_viewer/texture";
  texture_channel_ = std::make_unique<flutter::MethodChannel<>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());

  texture_channel_->SetMethodCallHandler(
      [this, registrar](const flutter::MethodCall<>& call,
                        std::unique_ptr<flutter::MethodResult<>> result) {
        const std::string& method = call.method_name();
        const flutter::EncodableMap* args =
            std::get_if<flutter::EncodableMap>(call.arguments());

        if (method == "register") {
          if (!args || !registrar || !texture_handler_) {
            result->Success(flutter::EncodableValue(static_cast<int64_t>(-1)));
            return;
          }
          auto w_it = args->find(flutter::EncodableValue("width"));
          auto h_it = args->find(flutter::EncodableValue("height"));
          auto n_it = args->find(flutter::EncodableValue("native_handle"));
          if (w_it == args->end() || h_it == args->end() || n_it == args->end()) {
            result->Success(flutter::EncodableValue(static_cast<int64_t>(-1)));
            return;
          }
          const auto width = static_cast<uint32_t>(ReadInt64Arg(w_it->second));
          const auto height = static_cast<uint32_t>(ReadInt64Arg(h_it->second));
          const auto handle = static_cast<uint64_t>(ReadInt64Arg(n_it->second));
          // width/height are sent by Dart for symmetry with the
          // TextureHandler C++ API; TextureHandler reads actual
          // dimensions from the D3D11Texture2D desc after
          // OpenSharedHandle.
          (void)width;
          (void)height;
          if (!texture_handler_->OpenSharedHandle(handle)) {
            result->Success(flutter::EncodableValue(static_cast<int64_t>(-1)));
            return;
          }
          const int64_t id = texture_handler_->RegisterWithFlutter(registrar);
          result->Success(flutter::EncodableValue(id));
        } else if (method == "update") {
          // In-place NT handle swap. On resize the Rust side reallocates
          // the offscreen D3D12 texture and mints a fresh NT handle; we
          // must point ANGLE at the new handle WITHOUT tearing down the
          // Flutter TextureLayer. Unregister+register (the old resize
          // path) destroys `texture_variant_` on the platform thread
          // while the raster thread is painting that layer, which makes
          // the engine throw an uncaught std::future_error across a
          // noexcept boundary -> terminate -> process abort (the
          // probabilistic resize crash). OpenSharedHandle atomically
          // swaps {handle,width,height} under state_mutex_, and
          // RegisterWithFlutter early-returns the EXISTING texture id
          // because flutter_texture_id_ is already set, so the layer is
          // never unregistered.
          if (!args || !registrar || !texture_handler_) {
            result->Success(flutter::EncodableValue(static_cast<int64_t>(-1)));
            return;
          }
          auto n_it = args->find(flutter::EncodableValue("native_handle"));
          if (n_it == args->end()) {
            result->Success(flutter::EncodableValue(static_cast<int64_t>(-1)));
            return;
          }
          const auto handle = static_cast<uint64_t>(ReadInt64Arg(n_it->second));
          if (!texture_handler_->OpenSharedHandle(handle)) {
            result->Success(flutter::EncodableValue(static_cast<int64_t>(-1)));
            return;
          }
          const int64_t id = texture_handler_->RegisterWithFlutter(registrar);
          result->Success(flutter::EncodableValue(id));
        } else if (method == "mark_frame_available") {
          if (!args || !registrar || !texture_handler_) {
            result->Success(flutter::EncodableValue());
            return;
          }
          // MarkTextureFrameAvailable takes the ID we returned from
          // `register`; we just need to propagate the ping.
          if (texture_handler_->MarkFrameAvailable(registrar)) {
            result->Success(flutter::EncodableValue());
          } else {
            result->Error("mark_frame_available_failed",
                          "TextureRegistrar::MarkTextureFrameAvailable failed");
          }
        } else if (method == "unregister") {
          if (texture_handler_ && registrar) {
            texture_handler_->UnregisterFromFlutter(registrar);
            texture_handler_->ReleaseTexture();
          }
          result->Success(flutter::EncodableValue());
        } else {
          result->NotImplemented();
        }
      });

  // Immersive fullscreen channel (mirrors Android's live2d_viewer/immersive).
  static const char kImmersiveChannelName[] = "live2d_viewer/immersive";
  immersive_channel_ = std::make_unique<flutter::MethodChannel<>>(
      messenger, kImmersiveChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  immersive_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        const std::string& method = call.method_name();
        HWND hwnd = GetHandle();

        if (method == "enable") {
          if (is_fullscreen_) {
            result->Success(flutter::EncodableValue());
            return;
          }
          saved_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
          GetWindowRect(hwnd, &saved_rect_);
          SetWindowLongPtr(hwnd, GWL_STYLE,
                           (saved_style_ & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
          HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
          MONITORINFO info = {sizeof(MONITORINFO)};
          GetMonitorInfo(monitor, &info);
          SetWindowPos(hwnd, HWND_TOP, info.rcMonitor.left, info.rcMonitor.top,
                       info.rcMonitor.right - info.rcMonitor.left,
                       info.rcMonitor.bottom - info.rcMonitor.top,
                       SWP_FRAMECHANGED | SWP_SHOWWINDOW);
          is_fullscreen_ = true;
          result->Success(flutter::EncodableValue());
        } else if (method == "disable") {
          if (!is_fullscreen_) {
            result->Success(flutter::EncodableValue());
            return;
          }
          SetWindowLongPtr(hwnd, GWL_STYLE, saved_style_);
          SetWindowPos(hwnd, nullptr, saved_rect_.left, saved_rect_.top,
                       saved_rect_.right - saved_rect_.left,
                       saved_rect_.bottom - saved_rect_.top,
                       SWP_FRAMECHANGED | SWP_SHOWWINDOW);
          is_fullscreen_ = false;
          result->Success(flutter::EncodableValue());
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Drop the channel first so Dart-side calls stop reaching the
  // handler while we tear down the texture resources.
  immersive_channel_.reset();
  texture_channel_.reset();
  if (texture_handler_) {
    texture_handler_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
