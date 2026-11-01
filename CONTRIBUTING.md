# Contributing

Thanks for helping improve Live2D Viewer. This is an unofficial project and is
not affiliated with Live2D Inc.

## Before you start

- Read `docs/ARCHITECTURE.md` for the component map and rendering invariants.
- Read the relevant postmortem before changing the frame loop, shared
  textures, Android surface lifecycle, or the vendored Mocari runtime.
- For anything security-sensitive, follow `SECURITY.md` instead of opening a
  public issue.

## Asset policy

This repository does not distribute Live2D models, textures, motions, or audio.
Do not add assets whose redistribution rights you cannot prove. That includes
commercial game rips, paid Live2D samples, and files copied from another
viewer's repository.

Use your own licensed model for manual testing:

```bash
export L2D_TEST_MODEL=/path/to/model/model.model3.json
```

On PowerShell:

```powershell
$env:L2D_TEST_MODEL = "D:\models\model\model.model3.json"
```

`L2D_TEST_MODEL` must point to a `.model3.json`; the `.moc3` path is read from
that file. The stress test additionally uses `L2D_STRESS_MODELS` (a
platform-separated list of model3 paths). These variables are local-only and
must never be committed.

## Toolchain

The tested versions are pinned in the repository:

- Rust `1.97.1` (`rust-toolchain.toml`)
- Flutter `3.35.5` / Dart `3.9.2`
- JDK 17 and Android NDK `r26d` for Android builds
- Visual Studio with the Desktop C++ workload for Windows builds

## Checks

Run the Rust checks from the repository root:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo test -p mocari_host --example render_poc
cargo test --manifest-path third_party/mocari/Cargo.toml --lib
```

Run the Flutter checks from `app/`:

```bash
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
```

If your environment sets `PUB_HOSTED_URL` to a package mirror, override it
with `https://pub.dev` before `pub get`; changing the hosted source makes pub
re-resolve the lockfile and drift away from the committed versions.

Tests that require a real model or a GPU are explicitly ignored or print a
skip reason when the environment cannot provide them. Do not report a green
test run as rendering coverage; record which manual GPU/device checks you ran.

## Generated files

Do not edit these by hand:

- `crates/mocari_host/src/frb_generated.rs`
- `app/lib/src/rust/**`

Regenerate them with:

```bash
flutter_rust_bridge_codegen generate \
  -r "crate::frb_api" \
  -d "app/lib/src/rust" \
  --rust-root "crates/mocari_host" \
  --dart-root "app"
```

Commit the generated diff when the public API changes.

## Pull requests

- Keep changes focused; avoid unrelated formatting or refactors.
- Update documentation and tests with behavior changes.
- Include the commands you ran and any GPU/device verification.
- For rendering or platform changes, list the Windows GPU and Android device
  used, or state clearly that they were not tested.
- Do not commit build outputs, `.so`/DLL files, model assets, keystores,
  `local.properties`, or IDE files.

The project is licensed under MIT. By contributing, you agree that your
contribution is provided under the same license.
