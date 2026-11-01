use mocari_host::version;

#[test]
fn smoke_version() {
    let v = version();
    assert!(!v.is_empty(), "version should not be empty");
}
