use crate::error::LoadErrorKind;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub schema: String,
    pub id: String,
    pub name: String,
    pub author: String,
    pub license: String,
    pub required_editor_version: String,
    pub model: ModelFiles,
    pub motion: Motion,
    #[serde(default)]
    pub expression: Vec<ExpressionEntry>,
    #[serde(default)]
    pub physics: Option<String>,
    #[serde(default)]
    pub hit_areas: Option<String>,
    #[serde(default)]
    pub metadata: Metadata,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelFiles {
    pub moc3: String,
    pub textures: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Motion {
    pub default_idle: String,
    pub groups: Vec<MotionGroup>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MotionGroup {
    pub id: String,
    pub files: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExpressionEntry {
    pub id: String,
    pub file: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Metadata {
    // Field-level default: `"metadata": {}` must yield scale 1.0
    // (matching Dart), not f32's 0.0 which would collapse the model.
    #[serde(default = "default_scale")]
    pub scale: f32,
    #[serde(default)]
    pub offset: (f32, f32),
}

fn default_scale() -> f32 {
    1.0
}

impl Default for Metadata {
    fn default() -> Self {
        Self {
            scale: 1.0,
            offset: (0.0, 0.0),
        }
    }
}

impl Manifest {
    pub fn from_json(bytes: &[u8]) -> Result<Self, LoadErrorKind> {
        let m: Manifest = serde_json::from_slice(bytes)
            .map_err(|e| LoadErrorKind::InvalidManifest(e.to_string()))?;
        if m.schema != "live2d-viewer.manifest/v1" {
            return Err(LoadErrorKind::InvalidManifest(format!(
                "unsupported schema: {}",
                m.schema
            )));
        }
        Ok(m)
    }
}
