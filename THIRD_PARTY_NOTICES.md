# Third-Party Notices

Live2D Viewer itself is licensed under the MIT License (see `LICENSE`).
This file records the third-party components that are vendored, linked, or
bundled into the application. The list is not a substitute for the license
texts shipped with those components.

## Vendored source

### Mocari

- Path: `third_party/mocari/`
- Upstream: <https://github.com/Eatgrapes/Mocari>
- Baseline: `mocari` 0.4.0 (crates.io)
- License: MIT, Copyright (c) 2026 Eatgrapes
- License text: `third_party/mocari/LICENSE`
- Local modifications are documented in `third_party/mocari/UPSTREAM.md`.

The vendored copy is patched to match Cubism's out-of-range disable semantics,
to tolerate negative drawable-mask placeholders, and to reduce per-frame
allocation and upload overhead. These modifications are distributed under the
same MIT license.

## Rust dependencies

The Rust workspace depends on crates from crates.io, including Mocari, wgpu,
winit, flutter_rust_bridge, serde, thiserror, log, and platform crates for
Windows and Android. Exact versions and checksums are recorded in `Cargo.lock`.
Their licenses are checked by `cargo deny` using `deny.toml`.

## Flutter and Dart dependencies

The Flutter application uses the Flutter SDK and the packages declared in
`app/pubspec.yaml`, including flutter_rust_bridge, flutter_riverpod, http,
crypto, archive, file_picker, permission_handler, path_provider, and freezed.
Flutter generates a complete `NOTICES` file at build time; the application's
license page reads that generated registry.

## Assets

No Live2D model, texture, motion, or audio assets are distributed in this
repository or in official release artifacts. The application icon and the
in-app logo are first-party artwork generated from `design/icon/make_icon.py`
and `app/lib/widgets/app_logo.dart`.

"Live2D" and "Cubism" are trademarks or registered trademarks of Live2D Inc.
This project is unofficial and is not affiliated with, endorsed by, sponsored
by, or certified by Live2D Inc.
