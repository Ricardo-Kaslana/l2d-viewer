# Active Postmortems

These notes document rendering and platform failures that still constrain the
current code. Each file starts with an English summary; the detailed analysis is
kept in Chinese to preserve the original engineering record.

Read the linked note before changing the corresponding path.

| Note | What happened | Read before |
| --- | --- | --- |
| [2026-07-19-live2d-white-screen.md](2026-07-19-live2d-white-screen.md) | A wgpu 30 surface path omitted `queue.present` and redraw scheduling, producing a white window. Established the complete acquire → submit → present → redraw loop. | Changing wgpu/winit loops or examples. |
| [2026-07-21-viewer-hover-flicker.md](2026-07-21-viewer-hover-flicker.md) | Hovering UI caused extra composition frames while the shared texture was mid-render. Established the private-target + atomic copy rule. | Changing `shared_offscreen.rs`, texture export, or the Windows texture handler. |
| [2026-07-21-viewer-setwindowsize-black-bars.md](2026-07-21-viewer-setwindowsize-black-bars.md) | Resize handling produced black bars and a stale-handle/`TextureLayer` lifecycle failure. Established in-place handle updates and careful texture registration. | Changing resize handling, `RendererNotifier._onFrameUpdated`, or texture layers. |
| [2026-07-22-android-integration-debugging.md](2026-07-22-android-integration-debugging.md) | Android integration lessons: layered permissions, FUSE directory scans, content URIs, Riverpod refresh behavior, lifecycle races, device replacement, and Vulkan formats. | Changing Android storage, scanning, lifecycle, or surface setup. |
| [2026-07-23-android-stage-stale-after-device-swap.md](2026-07-23-android-stage-stale-after-device-swap.md) | Replacing the Android wgpu device left a stage bound to freed resources, causing a silent no-render. | Changing `install_android_surface` or device/queue replacement. |
| [2026-07-30-multi-variant-parts-visible.md](2026-07-30-multi-variant-parts-visible.md) | Upstream Mocari clamped out-of-range keyforms, drawing every variant at once. The vendored patch implements Cubism's disable semantics. | Changing Mocari keyform/part/deformer/opacity code or upgrading Mocari. |
| [2026-07-30-windows-model-switch-process-crash.md](2026-07-30-windows-model-switch-process-crash.md) | Two independent Windows crashes: D3D12 teardown of a manually-created resource, and a fastfail from unregistering a texture while the raster thread painted. | Changing D3D12 COM resources, texture registration, or resize handling. |
| [2026-07-31-android-perf-optimization.md](2026-07-31-android-perf-optimization.md) | Android performance work: shared vertex buffers, dirty updates, mip generation, and reduced per-frame writes. | Changing the wgpu bridge, mesh updates, or texture sampling. |
| [2026-08-01-invalid-mask-drawable-index.md](2026-08-01-invalid-mask-drawable-index.md) | Some exporters use `-1` as a "no mask" placeholder; passing it to the renderer failed the whole model load. | Changing drawable-mask parsing or clipping resource creation. |

## Rules that came from these notes

- Do not use a deprecated render loop as a template.
- Do not write a shared texture directly from multiple draw calls.
- Do not unregister a Flutter texture during resize while the raster thread may
  still paint it.
- Do not trust model data at the renderer boundary; validate or clean it first.
- Do not replace a wgpu device without discarding resources bound to the old
  device and reloading the model.
- Do not treat a green GPU-less CI run as rendering coverage.

If a note becomes obsolete, replace it with a current note rather than deleting
the lesson silently.
