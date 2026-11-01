//! User gesture state (zoom + pan) shared between the render PoC and the
//! production host.
//!
//! Extracted from `crates/mocari_host/examples/render_poc.rs` so the example
//! and the host renderer drive the same 4-affine-scalar gesture model without
//! duplicating math. The state accumulates translate + diagonal scale only —
//! no rotation, no shear — so it composes analytically with the fit matrix
//! to keep the product translate + diagonal scale and rebuildable from
//! [`mocari::core::Matrix44`]'s public `identity`/`scale`/`translate`.
//!
//! All state is pure: zoom/pan take inputs as scalars, never reach into
//! winit/wgpu types. Keep it that way so the math stays testable without a
//! window or a GPU.

use mocari::core::Matrix44;

/// Accumulated user gesture plus the in-flight right-drag pan state.
///
/// `scale_*` and `translate_*` are model-space affine params (identity =
/// 1, 1, 0, 0) folded into the final transform by [`GestureState::compute_transform`].
/// `is_panning` / `pan_last` are pure window-event plumbing so callers don't
/// need a separate struct to drive a right-drag pan.
#[derive(Debug, Clone)]
pub struct GestureState {
    pub scale_x: f32,
    pub scale_y: f32,
    pub translate_x: f32,
    pub translate_y: f32,
    pub is_panning: bool,
    /// Last cursor position while right-drag panning, in physical pixels.
    /// `None` when no drag is in flight (or the first CursorMoved seeds it).
    pub pan_last: Option<(f64, f64)>,
}

impl Default for GestureState {
    fn default() -> Self {
        Self::new()
    }
}

impl GestureState {
    /// Identity gesture: no zoom, no pan, no in-flight drag. This is the
    /// state that draws the model exactly where the fit matrix placed it.
    pub fn new() -> Self {
        Self {
            scale_x: 1.0,
            scale_y: 1.0,
            translate_x: 0.0,
            translate_y: 0.0,
            is_panning: false,
            pan_last: None,
        }
    }

    /// Returns the gesture to identity. Also clears the in-flight pan, so
    /// callers can wire this directly to a "reset view" key without leaking
    /// drag state across the reset.
    pub fn reset(&mut self) {
        self.scale_x = 1.0;
        self.scale_y = 1.0;
        self.translate_x = 0.0;
        self.translate_y = 0.0;
        self.is_panning = false;
        self.pan_last = None;
    }

    /// Zooms by `factor` (e.g. `1.1` per wheel notch, `>1.0` enlarges) about
    /// `center` in model space. `None` is the degenerate-bounds fallback used
    /// when the mesh AABB collapses and there is no anchor to zoom about.
    ///
    /// Center-anchored: `(cx, cy)` is invariant on screen when scale changes
    /// from `s` to `s * f`. Derivation (the constant `fit_tx` cancels):
    /// ```text
    /// fit_sx * (s * f * cx + t') == fit_sx * (s * cx + t)
    ///   => t' = t + s * cx * (1 - f)
    /// ```
    /// No rotation/shear is introduced, so the 4-scalar gesture stays a
    /// valid translate + diagonal scale.
    pub fn zoom(&mut self, factor: f32, center: Option<(f32, f32)>) {
        let (cx, cy) = center.unwrap_or((0.0, 0.0));
        let old_sx = self.scale_x;
        let old_sy = self.scale_y;
        self.scale_x *= factor;
        self.scale_y *= factor;
        self.translate_x += old_sx * cx * (1.0 - factor);
        self.translate_y += old_sy * cy * (1.0 - factor);
    }

    /// Starts a right-drag pan. The first `CursorMoved` after this seeds
    /// `pan_last`; subsequent moves compute per-move deltas.
    pub fn pan_start(&mut self) {
        self.is_panning = true;
        self.pan_last = None;
    }

    /// Converts a per-move pixel delta into a model-space translate and adds
    /// it to the gesture.
    ///
    /// The fit matrix maps model units to NDC (clip space, +/-1), not to
    /// pixels, so a 1-unit change in the final NDC translate spans
    /// `surface / 2` pixels. The per-frame composite emits the translate as
    /// `fit_scale * gesture_translate`, hence a pixel delta converts to a
    /// model-space delta of `(2 * dx_px / surface_w) / fit_scale_x`.
    /// Screen y is downward while NDC y is upward, so `dy` is negated to
    /// give the grab-and-drag feel.
    pub fn pan_delta(
        &mut self,
        dx_px: f32,
        dy_px: f32,
        surface_width: u32,
        surface_height: u32,
        fit_scale_x: f32,
        fit_scale_y: f32,
    ) {
        let w = surface_width.max(1) as f32;
        let h = surface_height.max(1) as f32;
        self.translate_x += (2.0 * dx_px / w) / fit_scale_x;
        self.translate_y += (-2.0 * dy_px / h) / fit_scale_y;
    }

    /// Ends a right-drag pan, clearing the last-cursor cache.
    pub fn pan_end(&mut self) {
        self.is_panning = false;
        self.pan_last = None;
    }

    /// Composes `M_fit * gesture` analytically.
    ///
    /// Both are translate + diagonal scale, so their product is also
    /// translate + diagonal scale. `Matrix44` has no public `[f32; 16]`
    /// constructor, so we build the result from `identity` + `scale` +
    /// `translate` rather than multiplying. The returned matrix is what
    /// the host should upload to the GPU uniform buffer each frame.
    pub fn compute_transform(
        &self,
        fit_scale_x: f32,
        fit_scale_y: f32,
        fit_tx: f32,
        fit_ty: f32,
    ) -> Matrix44 {
        let sx = fit_scale_x * self.scale_x;
        let sy = fit_scale_y * self.scale_y;
        let tx = fit_scale_x * self.translate_x + fit_tx;
        let ty = fit_scale_y * self.translate_y + fit_ty;
        let mut m = Matrix44::identity();
        m.scale(sx, sy);
        m.translate(tx, ty);
        m
    }
}

/// `GestureState` bundled with the fit-derived scalars gesture operations
/// consume (`fit_scale_x/y` for `pan_delta`, `fit_center` for `zoom`).
///
/// This is the unit shared via `Arc<Mutex<GestureSlot>>` between the FRB
/// control surface (`RendererHandle`) and the render loop. Keeping the
/// gesture + its inputs in one mutex lets `pan_delta`/`zoom`/`reset` update
/// gesture state without locking the full `Live2dRenderer` mutex — which
/// the 60Hz frame loop holds for the entire `render_to_texture`. The fit
/// scalars are refreshed by `Live2dRenderer` on model load and resize via
/// `update_fit`.
///
/// Field `state` is the pure gesture math; the fit scalars are inputs the
/// host caches so gesture ops don't have to touch the renderer/stage.
#[derive(Debug, Clone)]
pub struct GestureSlot {
    pub state: GestureState,
    pub fit_scale_x: f32,
    pub fit_scale_y: f32,
    pub fit_center: Option<(f32, f32)>,
}

impl Default for GestureSlot {
    fn default() -> Self {
        Self::new()
    }
}

impl GestureSlot {
    pub fn new() -> Self {
        Self {
            state: GestureState::new(),
            fit_scale_x: 1.0,
            fit_scale_y: 1.0,
            fit_center: None,
        }
    }

    /// Refresh the fit-derived scalars. Called by the host renderer when
    /// the fit matrix changes (model load, surface resize, window resize).
    pub fn update_fit(
        &mut self,
        fit_scale_x: f32,
        fit_scale_y: f32,
        fit_center: Option<(f32, f32)>,
    ) {
        self.fit_scale_x = fit_scale_x;
        self.fit_scale_y = fit_scale_y;
        self.fit_center = fit_center;
    }

    /// Apply a pixel-delta pan using the cached fit scalars. The caller
    /// supplies the surface size (from the Flutter widget, not the wgpu
    /// surface config) so pan works on headless offscreen paths too.
    pub fn pan_delta(&mut self, dx_px: f32, dy_px: f32, surface_width: u32, surface_height: u32) {
        self.state.pan_delta(
            dx_px,
            dy_px,
            surface_width,
            surface_height,
            self.fit_scale_x,
            self.fit_scale_y,
        );
    }

    /// Zoom about the cached `fit_center` anchor.
    pub fn zoom(&mut self, factor: f32) {
        self.state.zoom(factor, self.fit_center);
    }

    pub fn pan_start(&mut self) {
        self.state.pan_start();
    }

    pub fn pan_end(&mut self) {
        self.state.pan_end();
    }

    pub fn reset(&mut self) {
        self.state.reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: assert an entire `Matrix44` matches a row-by-row expectation.
    /// Row-major `[f32; 16]` is easier to read than the column-major slice
    /// `Matrix44` exposes via `as_slice`, so we use the slice and index into
    /// it column-by-column.
    fn assert_matrix_close(m: &Matrix44, expected: [f32; 16], tol: f32) {
        let s = m.as_slice();
        for (i, &e) in expected.iter().enumerate() {
            assert!(
                (s[i] - e).abs() < tol,
                "matrix[{i}] expected {e}, got {} (full: {:?})",
                s[i],
                s,
            );
        }
    }

    /// Identity gesture: scales default to 1, translates to 0, no pan in
    /// flight. This is the state a freshly-loaded model starts in.
    #[test]
    fn new_is_identity_with_no_pan() {
        let g = GestureState::new();
        assert_eq!(g.scale_x, 1.0);
        assert_eq!(g.scale_y, 1.0);
        assert_eq!(g.translate_x, 0.0);
        assert_eq!(g.translate_y, 0.0);
        assert!(!g.is_panning);
        assert!(g.pan_last.is_none());
    }

    /// After zooming and panning, `reset` must restore identity AND clear
    /// any in-flight pan state, so a "reset view" key doesn't leave a
    /// half-dragged cursor behind.
    #[test]
    fn reset_clears_zoom_pan_and_in_flight_drag() {
        let mut g = GestureState::new();
        g.zoom(2.0, Some((0.5, 0.5)));
        g.pan_start();
        g.pan_last = Some((100.0, 200.0));

        g.reset();

        assert_eq!(g.scale_x, 1.0);
        assert_eq!(g.scale_y, 1.0);
        assert_eq!(g.translate_x, 0.0);
        assert_eq!(g.translate_y, 0.0);
        assert!(!g.is_panning);
        assert!(g.pan_last.is_none());
    }

    /// Zooming about `(0, 0)` (no anchor) must change the scale and leave
    /// the translate alone — there's nothing to keep fixed on screen.
    #[test]
    fn zoom_at_origin_only_changes_scale() {
        let mut g = GestureState::new();
        g.zoom(1.5, Some((0.0, 0.0)));
        assert!((g.scale_x - 1.5).abs() < 1e-6);
        assert!((g.scale_y - 1.5).abs() < 1e-6);
        assert_eq!(g.translate_x, 0.0);
        assert_eq!(g.translate_y, 0.0);
    }

    /// Zooming about `(0, 0)` via `None` must produce the same result as
    /// `Some((0, 0))` — the degenerate-bounds fallback for an empty AABB.
    #[test]
    fn zoom_with_none_center_matches_zero_center() {
        let mut a = GestureState::new();
        a.zoom(1.5, None);
        let mut b = GestureState::new();
        b.zoom(1.5, Some((0.0, 0.0)));
        assert_eq!(a.scale_x, b.scale_x);
        assert_eq!(a.scale_y, b.scale_y);
        assert_eq!(a.translate_x, b.translate_x);
        assert_eq!(a.translate_y, b.translate_y);
    }

    /// Center-anchored zoom must keep `(cx, cy)` fixed on screen: the
    /// screen-space position is `fit_sx * (s * cx + t)` for some constant
    /// `fit_sx`, so equal-before/after requires `s * f * cx + t' == s * cx + t`,
    /// which gives `t' = t + s * cx * (1 - f)`.
    #[test]
    fn zoom_keeps_center_anchored_in_screen_space() {
        // Use a 1.0 fit scale so screen-space == NDC * fit = model * fit * gesture.
        let mut g = GestureState::new();
        let cx = 0.3_f32;
        let cy = -0.2_f32;
        let fit_sx = 1.0_f32;
        let fit_sy = 1.0_f32;
        let fit_tx = 0.0_f32;
        let fit_ty = 0.0_f32;

        let m_before = g.compute_transform(fit_sx, fit_sy, fit_tx, fit_ty);
        // Screen-space center = (m * [cx, cy, 0, 1])_xy = (sx*cx + tx, sy*cy + ty)
        let cx_before = m_before.as_slice()[0] * cx + m_before.as_slice()[12];
        let cy_before = m_before.as_slice()[5] * cy + m_before.as_slice()[13];

        g.zoom(1.7, Some((cx, cy)));

        let m_after = g.compute_transform(fit_sx, fit_sy, fit_tx, fit_ty);
        let cx_after = m_after.as_slice()[0] * cx + m_after.as_slice()[12];
        let cy_after = m_after.as_slice()[5] * cy + m_after.as_slice()[13];

        assert!(
            (cx_after - cx_before).abs() < 1e-5,
            "cx moved: {cx_before} -> {cx_after}"
        );
        assert!(
            (cy_after - cy_before).abs() < 1e-5,
            "cy moved: {cy_before} -> {cy_after}"
        );
    }

    /// The folded translate must match the analytical derivation exactly
    /// (not just preserve the anchor) so the host renderer doesn't see
    /// floating-point drift on a long zoom session.
    #[test]
    fn zoom_translate_matches_analytical_formula() {
        let mut g = GestureState::new();
        let cx = 0.3_f32;
        let cy = -0.2_f32;
        let factor = 1.7_f32;
        g.zoom(factor, Some((cx, cy)));
        // t' = t + s * c * (1 - f). Initial t=0, s=1, so t' = c * (1 - f).
        let expected_tx = cx * (1.0 - factor);
        let expected_ty = cy * (1.0 - factor);
        assert!((g.translate_x - expected_tx).abs() < 1e-6);
        assert!((g.translate_y - expected_ty).abs() < 1e-6);
        assert!((g.scale_x - factor).abs() < 1e-6);
        assert!((g.scale_y - factor).abs() < 1e-6);
    }

    /// `pan_start` must flip the in-flight flag and clear any previous
    /// `pan_last` so a fresh drag doesn't inherit the last drag's cursor
    /// (which would produce a giant jump on the first move).
    #[test]
    fn pan_start_clears_pan_last() {
        let mut g = GestureState::new();
        g.pan_last = Some((999.0, 999.0));
        g.pan_start();
        assert!(g.is_panning);
        assert!(g.pan_last.is_none());
    }

    /// `pan_end` must clear both `is_panning` and `pan_last`. The render
    /// loop checks `is_panning` before reading `pan_last`, so leaving the
    /// last cursor set after a release would be safe but pointless; we
    /// still clear it to make the post-release state obvious.
    #[test]
    fn pan_end_clears_all_drag_state() {
        let mut g = GestureState::new();
        g.pan_start();
        g.pan_last = Some((10.0, 20.0));
        g.pan_end();
        assert!(!g.is_panning);
        assert!(g.pan_last.is_none());
    }

    /// 100-pixel drag on a 1000x1000 surface with fit scale 1.0 must move
    /// the model by `2 * 100 / 1000 = 0.2` model units in NDC. The factor
    /// of 2 comes from NDC being +/-1 across the full surface.
    #[test]
    fn pan_delta_pixels_to_model_units() {
        let mut g = GestureState::new();
        g.pan_delta(100.0, 50.0, 1000, 1000, 1.0, 1.0);
        assert!((g.translate_x - 0.2).abs() < 1e-6);
        // dy is negated so dragging down moves the model down too.
        assert!((g.translate_y - (-0.1)).abs() < 1e-6);
    }

    /// The pixel-to-model conversion includes `1 / fit_scale`, so a larger
    /// fit scale (model is smaller on screen) must require a bigger
    /// gesture translate for the same on-screen movement.
    #[test]
    fn pan_delta_scales_inversely_with_fit_scale() {
        let mut g1 = GestureState::new();
        g1.pan_delta(100.0, 0.0, 1000, 1000, 1.0, 1.0);
        let mut g2 = GestureState::new();
        g2.pan_delta(100.0, 0.0, 1000, 1000, 2.0, 2.0);
        // g2's fit is 2x as large, so it needs half the model delta.
        assert!(g1.translate_x > g2.translate_x);
        assert!((g1.translate_x - 2.0 * g2.translate_x).abs() < 1e-6);
    }

    /// A zero-sized surface would divide by zero in the pan math. Treat
    /// it as 1 pixel to stay finite; this matches the renderer's zero-size
    /// skip path (the host doesn't pan on an unobservable surface anyway).
    #[test]
    fn pan_delta_handles_zero_surface_without_nan() {
        let mut g = GestureState::new();
        g.pan_delta(10.0, 20.0, 0, 0, 1.0, 1.0);
        assert!(g.translate_x.is_finite());
        assert!(g.translate_y.is_finite());
    }

    /// Identity gesture on top of an identity fit must produce the
    /// identity matrix. This is the "no-op" case the PoC hits on the very
    /// first frame after a successful model load.
    #[test]
    fn compute_transform_identity_gesture_identity_fit() {
        let g = GestureState::new();
        let m = g.compute_transform(1.0, 1.0, 0.0, 0.0);
        let mut expected = [0.0_f32; 16];
        expected[0] = 1.0;
        expected[5] = 1.0;
        expected[10] = 1.0;
        expected[15] = 1.0;
        assert_matrix_close(&m, expected, 1e-6);
    }

    /// Non-identity fit alone (no user gesture) must produce a pure
    /// scale+translate that matches the fit matrix the host would compute
    /// in `fit::fit_model_matrix`. The render PoC expects this exact
    /// composition on the first frame after load.
    #[test]
    fn compute_transform_identity_gesture_with_fit() {
        let g = GestureState::new();
        let m = g.compute_transform(2.0, 3.0, 0.5, -0.25);
        let s = m.as_slice();
        // scale_x, scale_y, 1 (z), 1 (w) on the diagonal.
        assert!((s[0] - 2.0).abs() < 1e-6);
        assert!((s[5] - 3.0).abs() < 1e-6);
        assert!((s[10] - 1.0).abs() < 1e-6);
        assert!((s[15] - 1.0).abs() < 1e-6);
        // Translate is fit_tx, fit_ty (gesture translate is 0).
        assert!((s[12] - 0.5).abs() < 1e-6);
        assert!((s[13] - (-0.25)).abs() < 1e-6);
        // All off-diagonals stay zero — no rotation/shear introduced.
        for (i, &v) in s.iter().enumerate() {
            if matches!(i, 0 | 5 | 10 | 15 | 12 | 13) {
                continue;
            }
            assert_eq!(v, 0.0, "off-diagonal[{i}] should be 0, got {v}");
        }
    }

    /// `compute_transform` is the analytical product of `M_fit * gesture`:
    /// `sx = fit_sx * g_sx`, `tx = fit_sx * g_tx + fit_tx`, and likewise
    /// for y. Lock this so the host renderer and the PoC agree.
    #[test]
    fn compute_transform_composes_fit_and_gesture() {
        let mut g = GestureState::new();
        g.scale_x = 1.5;
        g.scale_y = 2.0;
        g.translate_x = 0.3;
        g.translate_y = -0.4;
        let m = g.compute_transform(2.0, 0.5, 1.0, -1.0);
        let s = m.as_slice();
        assert!((s[0] - 2.0 * 1.5).abs() < 1e-6);
        assert!((s[5] - 0.5 * 2.0).abs() < 1e-6);
        assert!((s[10] - 1.0).abs() < 1e-6);
        assert!((s[12] - (2.0 * 0.3 + 1.0)).abs() < 1e-6);
        assert!((s[13] - (0.5 * -0.4 + -1.0)).abs() < 1e-6);
    }
}
