# Vendored Mocari

This directory is a modified copy of the `mocari` crate.

- Upstream repository: <https://github.com/Eatgrapes/Mocari>
- Baseline: crates.io `mocari` 0.4.0
- License: MIT, Copyright (c) 2026 Eatgrapes (`LICENSE` in this directory)
- Why vendored: the application needs behavior that is not present in the
  released 0.4.0 crate. The root `Cargo.toml` redirects the dependency with
  `[patch.crates-io]`.

## Local modifications

### Cubism out-of-range disable semantics

The released runtime clamps a binding parameter to the nearest keyform when it
falls outside the keyform's key range. Cubism instead hides the affected art
mesh, part, or deformer (and cascades through the parent chain) when a bound
parameter is outside the key range plus/minus the decimal-place tolerance.
The local changes are concentrated in:

- `src/moc3/keyform_bindings.rs` (`snap_eps`, `band_out_of_range`)
- `src/moc3/mesh_build.rs`
- `src/moc3/parts.rs`
- `src/moc3/deformers.rs`
- `src/runtime.rs` (`part_drawable_opacity` must not use part keyform opacity)

Do not replace this with upstream behavior without re-running the per-drawable
ground-truth comparison described in
`docs/postmortem/2026-07-30-multi-variant-parts-visible.md`.

### Negative drawable-mask placeholders

Some exporters write `-1` in a drawable's mask list to mean "no mask".
`src/moc3/drawable.rs` drops negative indices before the renderer converts
them to drawable indices. Regression coverage lives in
`tests/moc3_art_meshes.rs`. See
`docs/postmortem/2026-08-01-invalid-mask-drawable-index.md`.

### Rendering and update performance

Behavior-preserving changes reduce per-frame allocations and uploads:

- `keyform_slots` returns a small inline buffer; `compose()` evaluates one
  slot set per deformer; warp grids accumulate from raw slices; deformer depth
  order is cached at parse time.
- `src/render/wgpu/buffers.rs` uses one shared vertex buffer and one
  `write_buffer` per dirty byte span; drawable metadata is updated in place.
- Model textures build a full mip chain with straight-alpha-weighted box
  filtering; samplers use trilinear minification.
- `src/runtime.rs`, `src/moc3/dependency.rs`, `src/moc3/mesh_build.rs`, and
  `src/moc3/glues.rs` implement dirty-flag incremental mesh updates with a
  full-update fallback. `tests/incremental_update.rs` is the ground-truth
  equivalence test.

### Local test assets

The repository does not distribute model assets. Tests that need a real model
read `L2D_TEST_MODEL` (a path to a `.model3.json`) and are ignored when the
variable is absent. The historical tests that expected a tracked sample under
`crates/mocari_host/assets/` have been made model-agnostic or removed. Tests
that still reference local sample-model names require the upstream sample
assets to be placed in the gitignored `third_party/mocari/assets/` directory.

## Upgrading

1. Fetch the target upstream version and diff this directory against it.
2. Re-apply or re-verify every modification above; do not silently take
   upstream clamping or mask handling.
3. Run `cargo test --manifest-path third_party/mocari/Cargo.toml --lib`.
4. With a real model supplied through `L2D_TEST_MODEL`, run
   `cargo test --manifest-path third_party/mocari/Cargo.toml --test incremental_update -- --ignored`.
5. Re-run the per-drawable differential check against a Cubism-compatible
   reference viewer for any multi-variant model.
6. Update this file with the new upstream version and any new deviations.
