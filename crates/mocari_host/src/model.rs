use crate::error::LoadErrorKind;
use crate::manifest::Manifest;
use std::path::Path;

pub struct Model {
    pub manifest: Manifest,
    pub dir: std::path::PathBuf,
}

impl Model {
    pub fn load(dir: &Path) -> Result<Self, LoadErrorKind> {
        let manifest_bytes = std::fs::read(dir.join("manifest.json"))?;
        let manifest = Manifest::from_json(&manifest_bytes)?;
        let moc3_path = dir.join(&manifest.model.moc3);
        if !moc3_path.exists() {
            return Err(LoadErrorKind::MissingFile(manifest.model.moc3.clone()));
        }
        // Only the version check needs the header. The .moc3 body is
        // hundreds of KB and gets parsed later by the Mocari runtime;
        // pulling the whole file here to read 8 bytes wastes startup
        // time and trips antivirus scans on first launch. Read just the
        // magic + version byte (5 bytes) — `read_moc3_version` accepts
        // anything >= 5 bytes that starts with `b"MOC3"`.
        let version = read_moc3_version_file(&moc3_path)?;
        if version < 2 {
            return Err(LoadErrorKind::UnsupportedMoc3Version(version));
        }
        Ok(Self {
            manifest,
            dir: dir.to_path_buf(),
        })
    }
}

pub fn read_moc3_version(bytes: &[u8]) -> u32 {
    if bytes.len() < 5 || &bytes[0..4] != b"MOC3" {
        return 0;
    }
    // Cubism .moc3 header: byte 4 is the version, byte 5 is the
    // consistency flag. Reading 4..8 as LE u32 would fold the
    // consistency byte into the version (v5 + flag=1 → 261).
    bytes[4] as u32
}

/// Read just enough of the .moc3 header to extract the version byte.
/// Returns 0 on IO error or magic mismatch (matches `read_moc3_version`).
fn read_moc3_version_file(path: &Path) -> Result<u32, LoadErrorKind> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut header = [0u8; 8];
    match file.read(&mut header)? {
        0..=4 => Ok(0), // too short for magic + version
        n => Ok(read_moc3_version(&header[..n])),
    }
}
