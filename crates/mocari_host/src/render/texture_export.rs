use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
pub struct SharedTextureHandle {
    pub width: u32,
    pub height: u32,
    pub native_handle: u64,
}

/// Build a placeholder `SharedTextureHandle` for tests and non-Windows
/// fallbacks. Production callers should go through
/// `SharedOffscreenTexture::shared_handle` (the Windows path that
/// mints a real D3D12 NT handle via `ID3D12Device::CreateSharedHandle`).
pub fn make_dummy_handle(w: u32, h: u32) -> SharedTextureHandle {
    SharedTextureHandle {
        width: w,
        height: h,
        native_handle: 0xDEAD_BEEF,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handle_is_serializable() {
        let h = make_dummy_handle(1280, 720);
        let s = serde_json::to_string(&h).unwrap();
        assert!(s.contains("1280"));
        assert!(s.contains("720"));
        assert!(s.contains("3735928559")); // 0xDEAD_BEEF decimal
    }

    #[test]
    fn handle_roundtrip_json() {
        let h = make_dummy_handle(1920, 1080);
        let s = serde_json::to_string(&h).unwrap();
        let de: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(de["width"], 1920);
        assert_eq!(de["height"], 1080);
        assert_eq!(de["native_handle"], 3735928559u64);
    }
}
