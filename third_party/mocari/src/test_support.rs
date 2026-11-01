//! Test-only helpers for locating a user-supplied model.
//!
//! The repository does not distribute model assets. Asset-dependent tests
//! read `L2D_TEST_MODEL` (a `.model3.json` path) and are marked ignored so a
//! normal test run cannot silently pass without them.

use std::path::PathBuf;

pub(crate) fn test_model_path() -> Option<PathBuf> {
    let path = PathBuf::from(std::env::var_os("L2D_TEST_MODEL")?);
    path.is_file().then_some(path)
}

pub(crate) fn test_moc3_path() -> Option<PathBuf> {
    let model = test_model_path()?;
    let bytes = std::fs::read(&model).ok()?;
    let json: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    let moc = json.get("FileReferences")?.get("Moc")?.as_str()?;
    let path = model.parent()?.join(moc);
    path.is_file().then_some(path)
}
