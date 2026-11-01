#[test]
fn reads_version_from_offset_4() {
    let mut buf = [0u8; 8];
    buf[0..4].copy_from_slice(b"MOC3");
    buf[4] = 2;
    assert_eq!(mocari_host::model::read_moc3_version(&buf), 2);
}

#[test]
fn version_ignores_consistency_byte_at_offset_5() {
    let mut buf = [0u8; 8];
    buf[0..4].copy_from_slice(b"MOC3");
    buf[4] = 5;
    buf[5] = 1; // consistency flag must not leak into the version
    assert_eq!(mocari_host::model::read_moc3_version(&buf), 5);
}

#[test]
fn returns_zero_for_bad_magic_or_short() {
    assert_eq!(mocari_host::model::read_moc3_version(b"MOC2"), 0);
    assert_eq!(mocari_host::model::read_moc3_version(&[0; 4]), 0);
}
