# Build, Run, and Debugging

This is the practical companion to `docs/ARCHITECTURE.md`. It focuses on
getting the app running and on the manual checks that automated tests cannot
cover.

## Toolchain

- Rust `1.97.1` (`rust-toolchain.toml`)
- Flutter `3.35.5` / Dart `3.9.2`
- JDK 17
- Android NDK `r26d` (`26.3.11579264`), arm64-v8a
- Visual Studio with Desktop C++ for Windows

Run `rustup show` and `flutter --version` if a build behaves differently from
CI.

## Rust checks and examples

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo test -p mocari_host --example render_poc
cargo check -p mocari_host --example bare_triangle
```

Open a GPU smoke window:

```powershell
cargo run -p mocari_host --example bare_triangle
```

Run the standalone renderer with a licensed model:

```powershell
cargo run -p mocari_host --example render_poc -- "D:\models\model\model.model3.json"
```

`render_poc` left-click cycles motion groups, the wheel zooms around the model
bounds center, right-drag pans, and `R` resets the gesture. It exits with a usage
message if no path or `L2D_RENDER_MODEL` is supplied.

## Flutter checks

```powershell
Set-Location app
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
flutter run -d windows
```

Tests that require a model or GPU are not run by default. A passing
`flutter test` is UI/state coverage, not a rendering check.

## Windows build pitfalls

### Rust changes do not appear in the running app

The Windows runner loads `mocari_host.dll` next to the executable. If CMake's
`copy_if_different` step is skipped, a stale DLL can remain loaded.

Stop the process, delete the runner executable to force a relink, then rebuild:

```powershell
Get-Process live2d_viewer -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item app\build\windows\x64\runner\Debug\live2d_viewer.exe -ErrorAction SilentlyContinue
Set-Location app
flutter run -d windows
```

`scripts/build-windows.ps1` automates this. Do not run it in CI; it intentionally
kills a local app process.

### White window

First determine whether the problem is acquire/submit/present/redraw or the
model shader. Replace the model draw with a clear-color-only frame and use an
obvious color. If that presents, the surface loop is alive; investigate the
renderer, textures, matrices, and clipping next. See
`docs/postmortem/2026-07-19-live2d-white-screen.md`.

### Black bars or a frozen model after resize

The D3D12 shared resource is recreated on resize. Flutter must receive the new
NT handle and update the existing texture id through the texture channel's
`update` method. Unregistering and re-registering during resize can race the
raster thread and crash the process. See
`docs/postmortem/2026-07-21-viewer-setwindowsize-black-bars.md` and
`docs/postmortem/2026-07-30-windows-model-switch-process-crash.md`.

### Hover flicker

The shared texture must not be written by the mask/model draw calls directly.
Render into the private target and issue one copy. If UI hover changes
composition timing and the model flickers, check the copy ordering and the
`FrameEvent.updated` wait. See
`docs/postmortem/2026-07-21-viewer-hover-flicker.md`.

## Android build and device checks

Set `ANDROID_NDK_HOME` and build:

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk-r26d
bash scripts/build-android.sh
```

The script cross-compiles `libmocari_host.so`, stages it into
`app/android/app/src/main/jniLibs/arm64-v8a/`, verifies SHA-256, and runs
`flutter build apk --release`. A fresh clone has no `.so` in jniLibs; always use
the staging step before building.

Install and inspect logs:

```bash
adb install -r app/build/app/outputs/flutter-apk/app-release.apk
adb logcat -c
adb shell am start -n io.github.dev.live2dviewer/.MainActivity
adb logcat -d | grep -E 'install_android|attach_surface|loadModel|frame_loop|frameEvent'
```

Expected startup sequence includes surface installation, model load, and
`render_to_surface OK` frames. If the model is not visible, check the package
id, JNI library load, surface lifecycle, and whether the app is running with a
new enough `.so`.

### Old `.so` after Rust changes

The APK packages the `.so` from jniLibs, not cargo's target directory. Rerun
`app/tool/stage_android_libs.dart` (the build scripts do this) and check its
SHA-256 output. A behavior that "did not change" after a Rust edit is often a
stale jniLibs file.

### Storage permission

The app does not request broad storage access at startup. It requests it only
when adding a custom external path. Remote and app-managed models do not need
it. If the system permission channel is missing in a stale build, the custom
path action will show a helpful dialog rather than blocking the whole app.

## Manual GPU and device gate

Before claiming a rendering change is verified, run the applicable checks:

### Windows (discrete GPU recommended)

1. Sustained 60fps for at least 10 minutes; watch stderr for frame-loop errors
   and GPU memory growth.
2. Five slow resize drags, five maximize/restore cycles, and a cross-monitor
   move.
3. Thirty seconds of rapid hover over motion chips and zoom buttons.
4. Model switch/reload several times without a process exit.

### Android

1. Cold launch to an empty library, then add a local model and load it.
2. Rotate/resume/pause cycles and a fullscreen toggle if supported.
3. Remote install and delete.
4. Check logcat for the expected surface and frame sequence.

Record the GPU/device and what was actually run. If you did not run it, say so.

## Release signing

Copy `app/android/key.properties.example` to `app/android/key.properties`, point
`storeFile` to a keystore (relative to `app/android/app/` or absolute), and fill
the credentials. Never commit the real file or keystore.

Without `key.properties`, `flutter build apk --release` remains debug-signed.
That is useful for testing but not a production release. Windows artifacts are
unsigned.
