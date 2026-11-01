use thiserror::Error;

#[derive(Debug, Error)]
pub enum LoadErrorKind {
    #[error("missing file: {0}")]
    MissingFile(String),
    #[error("invalid manifest: {0}")]
    InvalidManifest(String),
    #[error("unsupported moc3 version: got v{0}")]
    UnsupportedMoc3Version(u32),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Error)]
pub enum RenderErrorKind {
    #[error("surface invalid")]
    SurfaceInvalid,
    /// `render_to_surface` was called but no model is loaded. Distinct
    /// from `SurfaceInvalid` so callers can distinguish "detach window"
    /// (loop should idle, no Dart-side error banner needed) from "model
    /// not yet loaded" (loop should skip a frame, then resume once
    /// `load_model` lands). See docs/postmortem/2026-07-23-... for the
    /// device-swap Stage-clear contract.
    #[error("no model loaded; render skipped")]
    NoModel,
    #[error("wgpu: {0}")]
    Wgpu(String),
}

#[derive(Debug, Error)]
pub enum HostError {
    #[error(transparent)]
    Load(#[from] LoadErrorKind),
    #[error(transparent)]
    Render(#[from] RenderErrorKind),
    #[error("纹理导出失败: {0}")]
    TextureExport(String),
}
