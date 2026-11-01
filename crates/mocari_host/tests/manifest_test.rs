use mocari_host::manifest::Manifest;

const VALID: &str = r#"{
  "schema": "live2d-viewer.manifest/v1",
  "id": "shizuku.v1",
  "name": "Shizuku",
  "author": "x",
  "license": "CC-BY-4.0",
  "requiredEditorVersion": "5.0.0+",
  "model": { "moc3": "model.moc3", "textures": ["model.texture.png"] },
  "motion": { "defaultIdle": "motion/idle.motion3.json", "groups": [
    { "id": "idle", "files": ["motion/idle.motion3.json"] }
  ]},
  "expression": [
    { "id": "smile", "file": "expression/smile.exp3.json" }
  ],
  "physics": "physics/physics.json",
  "hitAreas": "hit_areas.json",
  "metadata": { "scale": 1.0, "offset": [0, 0] }
}"#;

#[test]
fn parses_minimal_v1_manifest() {
    let m = Manifest::from_json(VALID.as_bytes()).expect("parse");
    assert_eq!(m.id, "shizuku.v1");
    assert_eq!(m.expression.len(), 1);
    assert!((m.metadata.scale - 1.0).abs() < 1e-6);
}

#[test]
fn rejects_wrong_schema() {
    let bad = r#"{"schema":"other/v1","id":"x"}"#;
    let err = Manifest::from_json(bad.as_bytes()).unwrap_err();
    assert!(matches!(
        err,
        mocari_host::error::LoadErrorKind::InvalidManifest(_)
    ));
}

#[test]
fn metadata_present_but_missing_scale_defaults_to_one() {
    // Regression: `"metadata": {}` used to yield scale = 0.0 (f32
    // default) while Dart defaults to 1.0 — the model would collapse.
    let json = VALID.replace(
        r#""metadata": { "scale": 1.0, "offset": [0, 0] }"#,
        r#""metadata": { "offset": [0, 0] }"#,
    );
    let m = Manifest::from_json(json.as_bytes()).expect("parse");
    assert!((m.metadata.scale - 1.0).abs() < 1e-6);
}

#[test]
fn missing_metadata_defaults_to_one() {
    let json = VALID.replace(
        r#",
  "metadata": { "scale": 1.0, "offset": [0, 0] }"#,
        "",
    );
    let m = Manifest::from_json(json.as_bytes()).expect("parse");
    assert!((m.metadata.scale - 1.0).abs() < 1e-6);
}

#[test]
fn rejects_missing_required_field_moc3() {
    // `model.moc3` is required — its absence must surface as a
    // deserialisation error, not silently fall back to empty string.
    let bad = r#"{
      "schema": "live2d-viewer.manifest/v1",
      "id": "x", "name": "x", "author": "x", "license": "x",
      "requiredEditorVersion": "x",
      "model": { "textures": [] },
      "motion": { "defaultIdle": "idle.motion3.json", "groups": [] }
    }"#;
    assert!(Manifest::from_json(bad.as_bytes()).is_err());
}

#[test]
fn rejects_missing_required_field_default_idle() {
    // `motion.defaultIdle` is required by both Rust and Dart (M3
    // alignment); missing it must fail deserialisation.
    let bad = r#"{
      "schema": "live2d-viewer.manifest/v1",
      "id": "x", "name": "x", "author": "x", "license": "x",
      "requiredEditorVersion": "x",
      "model": { "moc3": "m.moc3", "textures": [] },
      "motion": { "groups": [] }
    }"#;
    assert!(Manifest::from_json(bad.as_bytes()).is_err());
}

#[test]
fn rejects_non_string_schema_field() {
    // Schema must be a string. Numeric / object schema must not be
    // silently coerced.
    let bad = r#"{
      "schema": 42,
      "id": "x", "name": "x", "author": "x", "license": "x",
      "requiredEditorVersion": "x",
      "model": { "moc3": "m.moc3", "textures": [] },
      "motion": { "defaultIdle": "idle", "groups": [] }
    }"#;
    assert!(Manifest::from_json(bad.as_bytes()).is_err());
}
