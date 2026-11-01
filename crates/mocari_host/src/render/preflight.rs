//! Pre-decode validation of the textures referenced by a `*.model3.json`.
//!
//! mocari's `load_model_runtime` decodes every referenced texture **in
//! parallel** with no dimension or memory budget: a corrupt/hostile PNG
//! whose IHDR claims a huge size (or a model shipping many 8K textures)
//! drives peak memory to `Σ(decode buffer + RGBA8 copy)`. That ends in
//! `handle_alloc_error` → **abort** (no unwind, `catch_unwind` cannot
//! help) or the Android low-memory killer (SIGKILL) — both kill the
//! whole process with no error banner. Validating existence and IHDR
//! dimensions up front turns those crashes into a clean `HostError`.

use std::io::Read;
use std::path::Path;

use crate::error::{HostError, LoadErrorKind};

/// Must match `max_texture_dimension_2d` in
/// `device::required_limits_for_cubism_textures`; anything larger would
/// fail GPU upload validation even if it survived decoding.
pub const MAX_TEXTURE_DIM: u32 = 8192;

/// Peak decoded-RGBA8 budget across all textures of one model (1 GiB).
/// mocari decodes all textures in parallel, so the budget guards the
/// *sum*, not the largest single texture.
pub const MAX_TOTAL_DECODED_BYTES: u64 = 1 << 30;

const PNG_SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

/// Extract `(width, height)` from a PNG file header (signature + IHDR).
///
/// Returns `None` when the buffer is too short, the signature does not
/// match, or the first chunk is not IHDR (which the PNG spec requires).
pub fn png_dimensions(header: &[u8]) -> Option<(u32, u32)> {
    if header.len() < 24 || header[..8] != PNG_SIGNATURE || &header[12..16] != b"IHDR" {
        return None;
    }
    let w = u32::from_be_bytes(header[16..20].try_into().ok()?);
    let h = u32::from_be_bytes(header[20..24].try_into().ok()?);
    Some((w, h))
}

/// Validate every texture referenced by `model3_path` before handing the
/// model to mocari's parallel decoder.
///
/// Checks per texture: file exists and is readable, header is a valid
/// PNG (Cubism ships PNG only), IHDR dimensions are non-zero and within
/// [`MAX_TEXTURE_DIM`]. Checks per model: total decoded RGBA8 size stays
/// within [`MAX_TOTAL_DECODED_BYTES`].
///
/// A model3.json that cannot be parsed or has no texture list passes
/// through untouched — mocari surfaces its own (unwinding, catchable)
/// parse error for those.
pub fn validate_model3_textures(model3_path: &Path) -> Result<(), HostError> {
    let Ok(text) = std::fs::read_to_string(model3_path) else {
        return Ok(());
    };
    let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
        return Ok(());
    };
    let Some(textures) = json
        .get("FileReferences")
        .and_then(|f| f.get("Textures"))
        .and_then(|t| t.as_array())
    else {
        return Ok(());
    };

    let base = model3_path.parent().unwrap_or_else(|| Path::new("."));
    let mut total_bytes: u64 = 0;
    for entry in textures {
        let Some(rel) = entry.as_str() else { continue };
        let path = base.join(rel);
        let mut header = [0u8; 24];
        let mut file = std::fs::File::open(&path).map_err(|e| {
            HostError::Load(LoadErrorKind::MissingFile(format!("texture {rel}: {e}")))
        })?;
        file.read_exact(&mut header).map_err(|_| {
            HostError::Load(LoadErrorKind::InvalidManifest(format!(
                "texture {rel}: file too short to be a PNG"
            )))
        })?;
        let (w, h) = png_dimensions(&header).ok_or_else(|| {
            HostError::Load(LoadErrorKind::InvalidManifest(format!(
                "texture {rel}: not a valid PNG"
            )))
        })?;
        if w == 0 || h == 0 || w > MAX_TEXTURE_DIM || h > MAX_TEXTURE_DIM {
            return Err(HostError::Load(LoadErrorKind::InvalidManifest(format!(
                "texture {rel}: dimensions {w}x{h} outside supported range (1..={MAX_TEXTURE_DIM})"
            ))));
        }
        total_bytes = total_bytes.saturating_add(u64::from(w) * u64::from(h) * 4);
    }
    if total_bytes > MAX_TOTAL_DECODED_BYTES {
        return Err(HostError::Load(LoadErrorKind::InvalidManifest(format!(
            "textures decode to {total_bytes} bytes RGBA8, over the {MAX_TOTAL_DECODED_BYTES} byte budget"
        ))));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::PathBuf;

    fn png_header(w: u32, h: u32) -> Vec<u8> {
        let mut v = Vec::with_capacity(24);
        v.extend_from_slice(&PNG_SIGNATURE);
        v.extend_from_slice(&13u32.to_be_bytes());
        v.extend_from_slice(b"IHDR");
        v.extend_from_slice(&w.to_be_bytes());
        v.extend_from_slice(&h.to_be_bytes());
        v
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "mocari_host_preflight_{tag}_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_model(dir: &Path, textures: &[&str]) -> PathBuf {
        let list = textures
            .iter()
            .map(|t| format!("\"{t}\""))
            .collect::<Vec<_>>()
            .join(",");
        let json = format!("{{\"FileReferences\":{{\"Textures\":[{list}]}}}}");
        let path = dir.join("m.model3.json");
        std::fs::write(&path, json).unwrap();
        path
    }

    #[test]
    fn png_dimensions_parses_valid_header() {
        assert_eq!(png_dimensions(&png_header(2048, 4096)), Some((2048, 4096)));
    }

    #[test]
    fn png_dimensions_rejects_bad_signature_and_short_input() {
        assert_eq!(png_dimensions(b"not a png header, sorry!"), None);
        assert_eq!(png_dimensions(&PNG_SIGNATURE), None);
    }

    #[test]
    fn missing_texture_file_is_a_clean_error() {
        let dir = temp_dir("missing");
        let model = write_model(&dir, &["gone.png"]);
        let err = validate_model3_textures(&model).unwrap_err();
        assert!(err.to_string().contains("gone.png"), "{err}");
    }

    #[test]
    fn oversized_ihdr_is_rejected_without_decoding() {
        let dir = temp_dir("huge");
        std::fs::File::create(dir.join("huge.png"))
            .unwrap()
            .write_all(&png_header(20000, 20000))
            .unwrap();
        let model = write_model(&dir, &["huge.png"]);
        let err = validate_model3_textures(&model).unwrap_err();
        assert!(err.to_string().contains("20000"), "{err}");
    }

    #[test]
    fn non_png_texture_is_rejected() {
        let dir = temp_dir("notpng");
        std::fs::write(dir.join("t.png"), b"JFIF definitely not a png").unwrap();
        let model = write_model(&dir, &["t.png"]);
        let err = validate_model3_textures(&model).unwrap_err();
        assert!(err.to_string().contains("not a valid PNG"), "{err}");
    }

    #[test]
    fn total_budget_guards_parallel_decode_sum() {
        let dir = temp_dir("budget");
        // Five 8192×8192 textures pass the per-texture cap but sum to
        // 5 × 256 MiB = 1.25 GiB, over the 1 GiB budget.
        for i in 0..5 {
            std::fs::File::create(dir.join(format!("t{i}.png")))
                .unwrap()
                .write_all(&png_header(8192, 8192))
                .unwrap();
        }
        let model = write_model(&dir, &["t0.png", "t1.png", "t2.png", "t3.png", "t4.png"]);
        let err = validate_model3_textures(&model).unwrap_err();
        assert!(err.to_string().contains("budget"), "{err}");
    }

    #[test]
    fn valid_textures_pass() {
        let dir = temp_dir("ok");
        std::fs::File::create(dir.join("ok.png"))
            .unwrap()
            .write_all(&png_header(4096, 4096))
            .unwrap();
        let model = write_model(&dir, &["ok.png"]);
        assert!(validate_model3_textures(&model).is_ok());
    }

    #[test]
    fn unparseable_model3_json_passes_through_to_mocari() {
        let dir = temp_dir("badjson");
        let path = dir.join("m.model3.json");
        std::fs::write(&path, "{ not json").unwrap();
        assert!(validate_model3_textures(&path).is_ok());
    }
}
