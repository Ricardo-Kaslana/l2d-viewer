#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

class TextureHandler;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Manages the D3D11 import of the Rust-side D3D12 shared texture.
  std::unique_ptr<TextureHandler> texture_handler_;

  // Held alive so the Dart-side `register`/`mark_frame_available`/
  // `unregister` calls keep reaching the handler set in OnCreate.
  std::unique_ptr<flutter::MethodChannel<>> texture_channel_;

  // Immersive fullscreen state (live2d_viewer/immersive channel).
  std::unique_ptr<flutter::MethodChannel<>> immersive_channel_;
  bool is_fullscreen_ = false;
  LONG_PTR saved_style_ = 0;
  RECT saved_rect_ = {};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
