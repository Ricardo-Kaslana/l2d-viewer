## Summary

Describe the change and why it is needed. Link the related issue if one exists.

## Verification

List the commands and manual checks you ran.

- [ ] `cargo fmt --all -- --check`
- [ ] `cargo clippy --workspace --all-targets -- -D warnings`
- [ ] `cargo test --workspace` (record ignored/GPU-skipped tests)
- [ ] `cd app && flutter analyze`
- [ ] `cd app && flutter test`
- [ ] Windows GPU check (if rendering/platform changed)
- [ ] Android device check (if Android/native changed)

## Checklist

- [ ] No model, texture, motion, audio, `.so`/DLL, keystore, or secret files are included.
- [ ] No unlicensed asset was added.
- [ ] Generated FRB files were regenerated, not hand-edited.
- [ ] Rendering invariants and relevant postmortems were reviewed.
- [ ] Documentation was updated for user-visible or build changes.
