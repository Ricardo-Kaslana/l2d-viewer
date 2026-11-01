use mocari_host::frb_api::RendererHandle;
use mocari_host::render::renderer::Live2dRenderer;

/// Helper: build a headless renderer and wrap it in a [`RendererHandle`].
/// This needs a GPU; on CI without one the helper returns `None` and the
/// test prints a skip message.
fn try_new_handle() -> Option<RendererHandle> {
    let renderer = pollster::block_on(Live2dRenderer::new_headless()).ok()?;
    Some(RendererHandle::new(renderer))
}

fn test_model_path() -> std::path::PathBuf {
    let path = std::env::var_os("L2D_TEST_MODEL")
        .map(std::path::PathBuf::from)
        .expect("set L2D_TEST_MODEL to a .model3.json");
    assert!(
        path.is_file(),
        "L2D_TEST_MODEL does not exist: {}",
        path.display()
    );
    path
}

#[test]
fn test_renderer_handle_creation() {
    let Some(handle) = try_new_handle() else {
        eprintln!("skip: no GPU available for headless renderer");
        return;
    };
    // Verify handle creation succeeded by exercising a simple operation.
    let groups = handle.get_motion_groups().unwrap();
    assert!(
        groups.is_empty(),
        "motion groups should be empty without a model"
    );
}

#[test]
#[ignore = "requires a GPU and L2D_TEST_MODEL"]
fn test_renderer_handle_operations() {
    let handle = try_new_handle().expect("this test needs a GPU adapter");
    let model_path = test_model_path();

    // Load model and verify info returned.
    let info = handle
        .load_model(model_path.to_string_lossy().to_string())
        .unwrap();
    assert!(info.version >= 2, "moc3 version should be >= 2");
    eprintln!(
        "Loaded model: version={}, motion_groups={:?}",
        info.version, info.motion_groups
    );

    // Verify motion groups are populated after loading.
    let groups = handle.get_motion_groups().unwrap();
    assert!(
        !groups.is_empty(),
        "motion groups should not be empty after loading"
    );

    // Exercise all handle operations and ensure they do not panic.
    handle.tap().unwrap();
    handle.zoom(1.5).unwrap();
    handle.pan_start().unwrap();
    handle.pan_delta(10.0, 20.0, 800, 600).unwrap();
    handle.pan_end().unwrap();
    handle.reset_gesture().unwrap();
    handle.resize(1024, 768).unwrap();
    handle.set_fit_center(Some((0.5, 0.5))).unwrap();

    // Trigger a motion if any group exists.
    if let Some(first_group) = groups.first() {
        handle.trigger_motion(first_group.clone()).unwrap();
    }

    // Render to texture should succeed now that a model is loaded.
    let frame = handle.render_to_texture().unwrap();
    assert!(
        frame.width > 0 && frame.height > 0,
        "frame dimensions must be positive (got {frame:?})"
    );
    #[cfg(target_os = "windows")]
    {
        // On Windows the route A D3D12 shared handle should be a real
        // NT kernel handle rather than the prior placeholder zero.
        assert_ne!(
            frame.native_handle, 0,
            "expected a non-zero D3D12 shared NT handle on Windows"
        );
    }
}

#[cfg(target_os = "windows")]
#[test]
#[ignore = "requires a GPU and L2D_TEST_MODEL"]
fn test_renderer_handle_resize_updates_shared_texture_dimensions() {
    let handle = try_new_handle().expect("this test needs a GPU adapter");
    let model_path = test_model_path();

    handle
        .load_model(model_path.to_string_lossy().to_string())
        .unwrap();
    handle.resize(640, 480).unwrap();
    let frame1 = handle.render_to_texture().unwrap();
    assert_eq!(frame1.width, 640);
    assert_eq!(frame1.height, 480);

    handle.resize(320, 200).unwrap();
    let frame2 = handle.render_to_texture().unwrap();
    assert_eq!(frame2.width, 320);
    assert_eq!(frame2.height, 200);
}

/// Verify that `set_window_size` propagates to the offscreen render
/// path, mirroring the contract the Phase 2 frame loop relies on.
///
/// The frame loop (FrameDriver / RendererHandle::start_frame_loop)
/// drives `render_to_texture` at 60Hz and emits `FrameEvent::Updated`
/// carrying the shared NT handle + dimensions. This test pins the
/// underlying size-propagation contract that the loop depends on:
///   * `set_window_size(w, h)` followed by `render_to_texture()` must
///     produce a `SharedTextureHandle` of width `w` and height `h`;
///   * On Windows the `native_handle` must be a real non-zero D3D12 NT
///     handle, not the legacy placeholder `0`.
///
/// Testing the literal `start_frame_loop(sink: StreamSink<FrameEvent>)`
/// path in pure Rust is impractical because constructing an FRB
/// `StreamSink` requires the Dart runtime. The 60Hz tick loop itself
/// is covered by `frame_driver::tests::frame_driver_drives_frames_at_60hz`.
#[test]
#[ignore = "requires a GPU and L2D_TEST_MODEL"]
fn test_set_window_size_drives_offscreen_dimensions() {
    let handle = try_new_handle().expect("this test needs a GPU adapter");
    let model_path = test_model_path();

    handle
        .load_model(model_path.to_string_lossy().to_string())
        .unwrap();

    // set_window_size + render should produce a frame of the requested size.
    handle.set_window_size(1280, 720).unwrap();
    let frame = handle.render_to_texture().unwrap();
    assert_eq!(frame.width, 1280, "set_window_size width not propagated");
    assert_eq!(frame.height, 720, "set_window_size height not propagated");

    #[cfg(target_os = "windows")]
    {
        // Phase 1 route A: the handle must be a real D3D12 NT handle.
        assert_ne!(
            frame.native_handle, 0,
            "expected a non-zero D3D12 shared NT handle on Windows"
        );
    }

    // Changing the window size should propagate to the next frame too.
    handle.set_window_size(800, 600).unwrap();
    let frame2 = handle.render_to_texture().unwrap();
    assert_eq!(frame2.width, 800);
    assert_eq!(frame2.height, 600);

    // stop_frame_loop must be callable without panicking even when no
    // loop was started (idempotent / defensive contract).
    handle.stop_frame_loop();
}
