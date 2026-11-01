//! Model fit helpers shared between the render PoC and the production host.
//!
//! Extracted from `crates/mocari_host/examples/render_poc.rs` so both the
//! example and the host renderer can compute the same aspect-correct NDC
//! scale and bounds center without duplicating the math.
//!
//! All helpers are pure: they take mesh geometry and a surface size in
//! physical pixels, and return either `(f32, f32)` scales or a `Matrix44`.
//! No GPU resources, no wgpu state, no winit types — keeps the math testable
//! without a window.

use mocari::{core::Matrix44, moc3::Moc3DrawableMesh};

/// NDC extent the model bounds should occupy along the fitting axis.
///
/// `1.0` would mean the model touches the viewport edge; `2.0` fills the
/// full NDC range (-1..+1). Live2D mesh bounds typically include invisible
/// deformation/physics area beyond the visible character, so filling the
/// full viewport keeps the visible model at a reasonable display size.
pub const VIEW_FILL: f32 = 2.0;

/// AABB of every drawable mesh vertex as `(width, height, center_x, center_y)`.
///
/// Returns `None` if the bounds collapse (zero width or zero height).
/// This is the cacheable form of the model's rest-pose extent: callers
/// that need a deterministic fit across resizes should compute it once
/// at load time instead of re-scanning (possibly deformed) meshes.
pub fn model_bounds(meshes: &[Moc3DrawableMesh]) -> Option<(f32, f32, f32, f32)> {
    let (mut bx, mut by, mut bx2, mut by2) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
    for v in meshes.iter().flat_map(|m| m.vertices()) {
        let p = v.position();
        bx = bx.min(p[0]);
        by = by.min(p[1]);
        bx2 = bx2.max(p[0]);
        by2 = by2.max(p[1]);
    }
    let bw = bx2 - bx;
    let bh = by2 - by;
    if bw <= 0.0 || bh <= 0.0 {
        None
    } else {
        Some((bw, bh, (bx + bx2) * 0.5, (by + by2) * 0.5))
    }
}

/// Model-space center of the AABB enclosing every drawable mesh vertex.
///
/// Returns `None` if the bounds collapse (zero width or zero height) so
/// callers can fall back to the same identity fit they would get from
/// `fit_model_matrix` on degenerate geometry.
pub fn model_bounds_center(meshes: &[Moc3DrawableMesh]) -> Option<(f32, f32)> {
    model_bounds(meshes).map(|(_, _, cx, cy)| (cx, cy))
}

/// Aspect-correct NDC scales that fit a model of `model_width` x `model_height`
/// inside a surface of `surface_width` x `surface_height` pixels.
///
/// With `scale_x = scale_y / aspect`, the horizontal fit constraint becomes
/// `model_width * scale_y / aspect <= VIEW_FILL`, so `fit_x` and `fit_y` are
/// independent per-axis limits and `scale_y = min(fit_x, fit_y)`.
pub fn fit_model_scales(
    model_width: f32,
    model_height: f32,
    surface_width: u32,
    surface_height: u32,
) -> (f32, f32) {
    if surface_width == 0 || surface_height == 0 {
        return (1.0, 1.0);
    }
    // Degenerate model dimensions would produce NaN scales from the
    // `VIEW_FILL / model_*` divisions below. Caller may have loaded a
    // half-broken mesh or constructed an empty bounds — fall back to
    // neutral scales rather than poisoning every downstream transform
    // (composite transform, clipping masks, frame loop).
    if model_width <= 0.0 || model_height <= 0.0 {
        return (1.0, 1.0);
    }
    let aspect = surface_width as f32 / surface_height as f32;
    let fit_x = VIEW_FILL * aspect / model_width;
    let fit_y = VIEW_FILL / model_height;
    let scale_y = fit_x.min(fit_y);
    (scale_y / aspect, scale_y)
}

/// Full fit transform: scale to fit the model in the surface, then translate
/// so the model bounds center sits at the NDC origin.
///
/// Returns `Matrix44::identity()` when the mesh bounds collapse — degenerate
/// models (zero-area) cannot anchor, so falling back to identity matches the
/// [`model_bounds_center`] `None` contract.
pub fn fit_model_matrix(
    meshes: &[Moc3DrawableMesh],
    surface_width: u32,
    surface_height: u32,
) -> Matrix44 {
    let (mut bx, mut by, mut bx2, mut by2) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
    for v in meshes.iter().flat_map(|m| m.vertices()) {
        let p = v.position();
        bx = bx.min(p[0]);
        by = by.min(p[1]);
        bx2 = bx2.max(p[0]);
        by2 = by2.max(p[1]);
    }
    let bw = bx2 - bx;
    let bh = by2 - by;
    if bw <= 0.0 || bh <= 0.0 {
        return Matrix44::identity();
    }
    let (sx, sy) = fit_model_scales(bw, bh, surface_width, surface_height);
    let mut m = Matrix44::identity();
    m.scale(sx, sy);
    m.translate(-(bx + bx2) * 0.5 * sx, -(by + by2) * 0.5 * sy);
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Square surface, square model: each scale should equal VIEW_FILL / model
    /// extent because aspect = 1.0 makes both per-axis limits identical.
    #[test]
    fn square_surface_square_model_scales_to_view_fill() {
        let (sx, sy) = fit_model_scales(2.0, 2.0, 1000, 1000);
        assert!((sx - VIEW_FILL / 2.0).abs() < 1e-5);
        assert!((sy - VIEW_FILL / 2.0).abs() < 1e-5);
    }

    /// Wide surface (aspect > 1): the horizontal fit limit is generous, so the
    /// vertical (model_height) limit should bind and `scale_x` must equal
    /// `scale_y / aspect` to preserve pixel aspect ratio.
    #[test]
    fn wide_surface_height_binds_and_aspect_is_preserved() {
        // 2:1 surface, 1x1 model. fit_y = VIEW_FILL / 1 = 2.0; fit_x = 2.0 * 2 / 1 = 4.0.
        // scale_y = min(4.0, 2.0) = 2.0; scale_x = 2.0 / 2 = 1.0.
        let (sx, sy) = fit_model_scales(1.0, 1.0, 2000, 1000);
        assert!((sy - VIEW_FILL).abs() < 1e-5);
        assert!((sx - VIEW_FILL / 2.0).abs() < 1e-5);
    }

    /// Tall surface (aspect < 1): the horizontal fit limit binds and
    /// `scale_x = scale_y / aspect` must still hold.
    #[test]
    fn tall_surface_width_binds_and_aspect_is_preserved() {
        // 1:2 surface, 1x1 model. fit_x = 2.0 * 0.5 / 1 = 1.0; fit_y = 2.0 / 1 = 2.0.
        // scale_y = min(1.0, 2.0) = 1.0; scale_x = 1.0 / 0.5 = 2.0.
        let (sx, sy) = fit_model_scales(1.0, 1.0, 1000, 2000);
        assert!((sx - VIEW_FILL).abs() < 1e-5);
        assert!((sy - VIEW_FILL / 2.0).abs() < 1e-5);
    }

    /// Invariant the whole fit routine is built around: regardless of surface
    /// aspect, `scale_x * aspect == scale_y` so the rendered model keeps pixel
    /// aspect ratio and doesn't squash or stretch on resize.
    #[test]
    fn scale_x_times_aspect_equals_scale_y() {
        for (sw, sh) in [(800u32, 600u32), (1920, 1080), (1080, 1920), (1, 1)] {
            let (sx, sy) = fit_model_scales(2.0, 3.0, sw, sh);
            let aspect = sw as f32 / sh as f32;
            assert!(
                (sx * aspect - sy).abs() < 1e-5,
                "sw={sw} sh={sh} sx={sx} sy={sy} aspect={aspect}"
            );
        }
    }

    /// `VIEW_FILL` is the single knob callers tune for margin; lock it so
    /// downstream rendering assumptions (PoC window size, etc.) stay valid.
    #[test]
    fn view_fill_constant_matches_poc_value() {
        assert!((VIEW_FILL - 2.0).abs() < f32::EPSILON);
    }

    /// Empty mesh slice has no vertices, so the bounds are degenerate; both
    /// helpers must signal this by returning `None` / identity rather than
    /// dividing by zero or panicking.
    #[test]
    fn empty_meshes_yield_none_center_and_identity_matrix() {
        let meshes: &[Moc3DrawableMesh] = &[];
        assert!(model_bounds_center(meshes).is_none());
        let m = fit_model_matrix(meshes, 800, 600);
        let s = m.as_slice();
        // Diagonal must be 1; every other cell (off-diagonal + translation)
        // must be 0. Check off-diagonal explicitly so a 1.0 sneaks through.
        for (i, &v) in s.iter().enumerate() {
            if i == 0 || i == 5 || i == 10 || i == 15 {
                assert_eq!(v, 1.0, "diagonal[{i}] should be 1, got {v}");
            } else {
                assert_eq!(v, 0.0, "off-diagonal[{i}] should be 0, got {v}");
            }
        }
    }

    /// Zero-sized surface: caller may not have observed a resize yet. Avoid a
    /// NaN-producing divide by returning neutral scales instead of panicking.
    #[test]
    fn zero_surface_returns_neutral_scales() {
        let (sx, sy) = fit_model_scales(1.0, 1.0, 0, 0);
        assert!(sx.is_finite() && sy.is_finite());
        assert_eq!(sx, 1.0);
        assert_eq!(sy, 1.0);
    }

    /// Degenerate model dimensions (zero or negative) must not produce
    /// NaN scales — the `VIEW_FILL / model_*` division would otherwise
    /// poison every downstream transform. Mirror the surface-zero guard.
    #[test]
    fn degenerate_model_dimensions_return_neutral_scales() {
        for (mw, mh) in [
            (0.0f32, 1.0f32),
            (1.0, 0.0),
            (0.0, 0.0),
            (-1.0, 1.0),
            (1.0, -1.0),
        ] {
            let (sx, sy) = fit_model_scales(mw, mh, 800, 600);
            assert!(
                sx.is_finite() && sy.is_finite(),
                "NaN for model {mw}x{mh}: sx={sx} sy={sy}"
            );
            assert_eq!(sx, 1.0, "model {mw}x{mh} sx");
            assert_eq!(sy, 1.0, "model {mw}x{mh} sy");
        }
    }
}
