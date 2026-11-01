# Maintainer and Agent Notes

This file is the shared working agreement for maintainers and coding agents.
The current code, tests, and build configuration take priority over this file.

## Project shape

- Flutter app in `app/`; Rust host/runtime in `crates/mocari_host/`.
- Vendored, patched Mocari in `third_party/mocari/`. Read
  `third_party/mocari/UPSTREAM.md` before changing or upgrading it.
- No model assets are bundled. Tests use `L2D_TEST_MODEL` and are ignored by
  default.
- Public entry docs are English. Active postmortems are Chinese with English
  summaries.

## Commands

From the repository root:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo test -p mocari_host --example render_poc
cargo test --manifest-path third_party/mocari/Cargo.toml --lib
```

From `app/`:

```bash
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
```

With a licensed local model:

```bash
export L2D_TEST_MODEL=/path/to/model.model3.json
cargo test --workspace -- --ignored
```

Do not report GPU/device coverage from a model-less CI run. Record manual GPU
and Android checks explicitly.

## Rendering invariants

Read `docs/ARCHITECTURE.md` and the relevant postmortem before touching these
paths.

- Preserve acquire → two render passes → submit → present/copy → schedule.
- Render masks before the model; preserve Mocari clipping and draw order.
- Never write the Windows shared texture from multiple draw calls. Render into
  the private target and copy once.
- Emit `FrameEvent.updated` only after that frame's GPU copy has retired.
- Keep `SharedOffscreenTexture.keep_device_alive` as the last field.
- Preflight textures before Mocari decoding.
- Do not let wgpu uncaptured errors use the default panic handler.
- Clear `stage`/`offscreen_texture` when replacing the wgpu device on Android.
- Keep frame-loop lifecycle operations on `_lifecycleChain`; use `_xxxInner`
  inside the chain.
- Do not reintroduce the removed `poc/render_loop.rs` or built-in model
  extraction.

## Models and assets

- Never commit an asset without documented redistribution rights.
- Do not add a proprietary game rip, paid sample, or copied model.
- Use `L2D_TEST_MODEL` for local verification.
- Remote packages are untrusted. Keep SHA-256, length, traversal, and zip-bomb
  checks; use HTTPS in documentation and tests.
- Do not weaken `MANAGE_EXTERNAL_STORAGE` guidance or the on-demand permission
  flow without checking Android policy implications.

## Generated files

Do not hand-edit:

- `crates/mocari_host/src/frb_generated.rs`
- `app/lib/src/rust/**`

Regenerate with:

```bash
flutter_rust_bridge_codegen generate \
  -r "crate::frb_api" \
  -d "app/lib/src/rust" \
  --rust-root "crates/mocari_host" \
  --dart-root "app"
```

Commit generated diffs with API changes. `ci.yml` checks for drift.

## Build and release

- Rust 1.97.1, Flutter 3.35.5, Dart 3.9.2, JDK 17, NDK r26d.
- Android cross-compilation is driven by `scripts/build-android.sh` or
  `scripts/build-android.ps1`; both stage the `.so` with
  `app/tool/stage_android_libs.dart`.
- Release signing reads `app/android/key.properties`; never commit it or a
  keystore.
- Tag releases are built as draft GitHub Releases. Without signing secrets the
  APK is debug-signed and the Windows ZIP is unsigned.
- Do not publish crates.io packages or push a public repository as part of a
  routine change.

## Change discipline

- Keep changes focused; separate mechanical formatting from behavior changes.
- Add regression tests at the lowest useful layer.
- Update `docs/STATUS.md`, `CHANGELOG.md`, and user docs when behavior or
  compatibility changes.
- Check `git diff --check` and `git status --short` before committing.
- Run the public-tree check (`scripts/check-public-tree.sh`) before publishing.
