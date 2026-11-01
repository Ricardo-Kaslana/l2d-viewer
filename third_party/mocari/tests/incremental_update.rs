//! Ground-truth equivalence test for the dirty-flag incremental mesh update.
//!
//! The control runtime invalidates its incremental snapshots before every
//! update, which forces the full re-evaluation path (the pre-optimization
//! behavior by construction). The incremental runtime uses the normal path.
//! Both receive identical mutations; their meshes must match exactly at every
//! step.

use std::path::{Path, PathBuf};

use mocari::assets::load_model_runtime;
use mocari::moc3::Moc3CountInfo;

/// Optional local-only model (gitignored `assets/`); complements the
/// caller-supplied model with different rigging when present.
const LOCAL_MODEL: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/assets/models/Hiyori/Hiyori.model3.json"
);

fn test_model_path() -> PathBuf {
    let path = std::env::var_os("L2D_TEST_MODEL")
        .map(PathBuf::from)
        .expect("set L2D_TEST_MODEL to a .model3.json");
    assert!(
        path.is_file(),
        "L2D_TEST_MODEL does not exist: {}",
        path.display()
    );
    path
}

fn test_moc3_path() -> PathBuf {
    let model = test_model_path();
    let bytes = std::fs::read(&model).expect("read L2D_TEST_MODEL");
    let json: serde_json::Value = serde_json::from_slice(&bytes).expect("parse L2D_TEST_MODEL");
    let moc = json
        .get("FileReferences")
        .and_then(|value| value.get("Moc"))
        .and_then(|value| value.as_str())
        .expect("L2D_TEST_MODEL must contain FileReferences.Moc");
    let path = model.parent().expect("model path has a parent").join(moc);
    assert!(
        path.is_file(),
        "referenced .moc3 not found: {}",
        path.display()
    );
    path
}

struct Lcg(u64);

impl Lcg {
    fn next_u32(&mut self) -> u32 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (self.0 >> 33) as u32
    }

    fn next_f32(&mut self) -> f32 {
        self.next_u32() as f32 / u32::MAX as f32
    }

    fn next_index(&mut self, len: usize) -> usize {
        (self.next_u32() as usize) % len.max(1)
    }
}

#[test]
#[ignore = "requires L2D_TEST_MODEL"]
fn incremental_update_matches_full_update() {
    run_equivalence(&test_model_path().to_string_lossy());
}

/// Guard against silent zero coverage: the equivalence run only exercises
/// the incremental glue fixed-point and draw-order-group re-sort paths if
/// the supplied model actually contains them.
#[test]
#[ignore = "requires L2D_TEST_MODEL"]
fn provided_model_covers_glue_and_draw_order_group_paths() {
    let bytes = std::fs::read(test_moc3_path()).unwrap();
    let counts = Moc3CountInfo::parse(&bytes).unwrap();
    assert!(
        counts.glue() > 0,
        "provided model has no glue: incremental glue path untested"
    );
    assert!(
        counts.draw_order_groups() > 0,
        "provided model has no draw order groups: re-sort gating untested"
    );
}

#[test]
fn incremental_update_matches_full_update_local_model() {
    if !Path::new(LOCAL_MODEL).exists() {
        eprintln!("skipping: {LOCAL_MODEL} not present");
        return;
    }
    run_equivalence(LOCAL_MODEL);
}

fn run_equivalence(model: &str) {
    let mut control = load_model_runtime(model).unwrap();
    let mut incremental = load_model_runtime(model).unwrap();
    let parameter_count = control.runtime().parameter_ids().len();
    let part_count = control.runtime().part_ids().len();
    assert!(parameter_count > 0);

    let mut rng = Lcg(0x5eed_1234_5678_9abc);
    for step in 0..400 {
        let mutation = rng.next_u32() % 10;
        match mutation {
            // Most steps: set 1-4 parameters, including values clamped at the
            // range edges (normalized outside 0..=1).
            0..=5 => {
                let count = 1 + rng.next_index(4);
                for _ in 0..count {
                    let index = rng.next_index(parameter_count);
                    let normalized = rng.next_f32() * 1.5 - 0.25;
                    control
                        .runtime_mut()
                        .set_parameter_normalized_by_index(index, normalized);
                    incremental
                        .runtime_mut()
                        .set_parameter_normalized_by_index(index, normalized);
                }
            }
            6 => {
                // No-op step: nothing changed since the last update.
            }
            7 => {
                // Re-set a parameter to a value it may already hold.
                let index = rng.next_index(parameter_count);
                control
                    .runtime_mut()
                    .set_parameter_normalized_by_index(index, 0.5);
                incremental
                    .runtime_mut()
                    .set_parameter_normalized_by_index(index, 0.5);
            }
            8 => {
                if part_count > 0 {
                    let index = rng.next_index(part_count);
                    let opacity = rng.next_f32();
                    control
                        .runtime_mut()
                        .set_part_opacity_by_index(index, opacity);
                    incremental
                        .runtime_mut()
                        .set_part_opacity_by_index(index, opacity);
                }
            }
            _ => {
                control.runtime_mut().reset_parameters();
                incremental.runtime_mut().reset_parameters();
                control.runtime_mut().reset_part_opacities();
                incremental.runtime_mut().reset_part_opacities();
            }
        }

        control.runtime_mut().invalidate_incremental_state();
        assert_eq!(control.runtime_mut().update_meshes(), Some(()));
        assert_eq!(incremental.runtime_mut().update_meshes(), Some(()));

        let control_meshes = control.runtime().meshes();
        let incremental_meshes = incremental.runtime().meshes();
        assert_eq!(control_meshes.len(), incremental_meshes.len());
        for (index, (expected, actual)) in control_meshes.iter().zip(incremental_meshes).enumerate()
        {
            assert!(
                expected == actual,
                "step {step} mutation {mutation}: drawable {index} diverged from full update",
            );
        }
    }
}
