# Project Status

- **Snapshot:** 2026-11-01, version 0.2.0
- **Basis:** current source tree and tests. Historical plans are not treated as
  evidence of completion.
- **Stage:** MVP with working Windows and Android rendering; not a store-ready
  release.

## Capability matrix

| Area | Status | Evidence and boundaries |
| --- | --- | --- |
| Windows render path | Working | Rust/wgpu renders to a D3D12 shared texture and Flutter displays it via `Texture`. Manually verified on a discrete NVIDIA GPU. |
| Android render path | Working | wgpu Vulkan renders to a Flutter `SurfaceTexture` via `ANativeWindow`. Manually verified on a Mali GPU / Android 10 device. |
| Rust model runtime | Working | Cubism-compatible parsing, motions, physics, clipping masks, and pose handling use the vendored Mocari 0.4.0 patch. |
| Two-pass rendering | Working | Mask pass before model pass; clipping semantics preserved by Mocari. |
| Zoom / pan / reset | Working | Viewer gestures and `render_poc` share fit/gesture math. Wheel zoom, drag pan, reset, keyboard shortcuts. |
| Motion selection | Working | Motion groups are exposed through FRB; the Viewer lists and triggers groups. |
| Fullscreen | Working (Windows) | Immersive fullscreen channel, F11/Esc, overlay panel. Android immersive mode exists; stress testing remains manual. |
| FPS cap and overlay | Working | Persisted 30/60/120/unlimited cap; optional live FPS overlay. |
| Local / custom models | Working | Async directory scan, manifest or `model3.json` fallback, custom paths. |
| Remote model catalogs | Working | `pkg-index/v1`, SHA-256, size limits, traversal/zip-bomb rejection, atomic install, delete flow. |
| Storage permission | Optional | Broad Android storage access is requested only for custom external paths. |
| Audio | Not implemented | No audio dependency or playback path. |
| Hit-area input | Partial | Rust hit-test helper exists; Flutter does not map taps to model hit areas. |
| Release signing | Optional | `app/android/key.properties` enables release signing; otherwise builds remain debug-signed. |
| GPU/device automation | Not covered | GitHub-hosted runners have no GPU; long-run and real-device checks are manual. |

## Verification snapshot

Automated local checks that pass without a model or GPU:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo test -p mocari_host --example render_poc
cargo test --manifest-path third_party/mocari/Cargo.toml --lib
cd app && flutter analyze && flutter test
```

Asset-dependent tests are explicitly ignored and require `L2D_TEST_MODEL`.
A green automated run must not be described as GPU or real-model coverage.

## Known gaps

- No automated Windows 60fps long-run, resize cycle, or hover-flicker check.
- No automated Android rotation/pause-resume stress or release-signing check.
- No bundled model or redistributable sample model.
- No audio or hit-area integration.
- No Google Play submission; the all-files storage permission is a policy risk.
- Remote downloads are unauthenticated beyond HTTPS and the index SHA-256.
- The vendored Mocari patch must be re-validated on every upstream upgrade.

## Next milestones

1. Real-device Android lifecycle stress and Windows 60fps/resize regression.
2. Hit-area input and motion mapping.
3. Audio playback.
4. Optional signed release pipeline with documented keystore ownership.
5. Upstream the Mocari behavior fixes or maintain an auditable patch set.
