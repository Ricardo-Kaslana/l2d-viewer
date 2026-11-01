# Changelog

All notable changes to Live2D Viewer are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The project intends to use semantic versioning for tagged releases.

## [0.2.0] - 2026-11-01

First public-source release. This is an MVP, not a store-ready release.

### Added

- Windows and Android native rendering through Rust/wgpu and Mocari.
- D3D12 shared-texture path for Flutter Windows and Vulkan SurfaceTexture path
  for Android.
- Flutter shell with Library, Viewer, Settings, and Remote pages.
- Local model discovery, custom model paths, and persisted settings.
- Remote `pkg-index/v1` catalogs with SHA-256 verification, download limits,
  traversal/zip-bomb rejection, atomic installation, and deletion.
- Immersive Windows fullscreen, optional FPS overlay, and frame-rate caps.
- MIT licensing, third-party notices, contribution/security/conduct policies,
  issue templates, and automated release workflows.
- Model-agnostic test setup through `L2D_TEST_MODEL`, `L2D_STRESS_MODELS`, and
  `L2D_RENDER_MODEL`.

### Changed

- Android application ID is now `io.github.dev.live2dviewer`; Windows metadata
  and the in-app About section identify the project as unofficial.
- Android broad storage access is requested only for custom external paths.
- Remote source configuration accepts a directory URL or a full `index.json`
  URL and rejects non-http(s) schemes.
- Rust is pinned to 1.97.1; Flutter to 3.35.5; Android NDK to r26d.
- Android Gradle wrapper and the Dart `.so` staging helper are now tracked and
  reused by local and CI builds.

### Removed

- The unlicensed bundled model and the built-in model extraction flow.
- No-op window-mode/input stubs, legacy PoC modules, the placeholder
  `frb_codegen` crate, and unused dependencies.
- Internal plans, session archives, and personal paths from the public tree.

### Fixed

- D3D12 shared-texture teardown and resize handle-swap crashes.
- Android stale surface resources after device replacement.
- Multi-variant part visibility and negative drawable-mask placeholders in the
  vendored Mocari runtime.
- Corrupt/oversized texture handling and wgpu uncaptured-error process aborts.
- Remote path/zip-bomb validation, empty version entries, and delete rollback.

### Security

- Remote package size, SHA-256, path traversal, and zip-bomb guards.
- Texture preflight before decoding.
- Debug logs and error banners avoid local paths and full remote URLs.
