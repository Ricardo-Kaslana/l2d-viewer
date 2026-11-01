# Models and Assets

## No bundled models

This repository does not distribute Live2D model assets. The application starts
with an empty library. You must supply models that you own or are licensed to
use.

Do not add a model, texture, motion, physics file, or audio clip to a pull
request unless you can document its redistribution license. Commercial game
extractions and paid sample packages are not acceptable unless their license
explicitly permits redistribution.

The `.gitignore` rejects `.moc3`, `.motion3.json`, `.physics3.json`, and the
model asset directories, but those rules are a safety net, not a license.

## Supported model format

The product scope is Cubism 5 with `.moc3` v3 data. A model directory contains
a standard `*.model3.json` plus the files it references:

```text
my-model/
├── my-model.model3.json
├── my-model.moc3
├── my-model.physics3.json
├── textures/
│   └── texture_00.png
└── motions/
    └── idle.motion3.json
```

`LocalModelRepo` also accepts an optional `manifest.json` using the
`live2d-viewer.manifest/v1` schema. The standard Cubism model3 file is usually
enough. The two formats are not interchangeable.

## Adding a local model

1. Open **Settings**.
2. Add the model directory, or a directory containing model subdirectories,
   under **Custom model paths**.
3. Return to **Library** and select the model.

On Windows this is a normal folder path. On Android, browsing outside the app
sandbox may require Android's "All files access" permission. The permission is
requested only when you add an external path; app-managed and remote models do
not require it.

The initial view fits the union of all drawable mesh bounds. That includes
background, deformation, and other geometry that may be mostly transparent or
clipped. Models authored for a custom in-game camera can therefore look small
at 1x even though the renderer is behaving correctly. Pinch on a phone, scroll
on Windows, or use the **In** button to zoom; **Reset** returns to the
mesh-bounds fit.

## Test models

Asset-dependent Rust tests are marked `#[ignore]` and read:

- `L2D_TEST_MODEL`: path to a `.model3.json`.
- `L2D_STRESS_MODELS`: platform-separated list of `.model3.json` paths for the
  stress test.
- `L2D_STRESS_ITERS`: optional stress iteration count (default 500).
- `L2D_RENDER_MODEL`: fallback model path for the `render_poc` example.

Example:

```bash
export L2D_TEST_MODEL=/models/my-model/my-model.model3.json
cargo test --workspace -- --ignored
```

The model and its textures remain local. CI does not download them, so GPU and
real-model coverage is manual.

## Remote catalogs

A remote catalog is a directory served over HTTP(S) with this layout:

```text
catalog/
├── index.json
└── packages/
    ├── model_a.zip
    └── model_b.zip
```

`index.json` follows `live2d-viewer.pkg-index/v1`:

```json
{
  "schema": "live2d-viewer.pkg-index/v1",
  "packages": [
    {
      "id": "model_a",
      "name": "Model A",
      "latest": "1.0.0",
      "versions": [
        {
          "version": "1.0.0",
          "url": "packages/model_a.zip",
          "sha256": "<lowercase hex>",
          "size": 123456
        }
      ]
    }
  ]
}
```

The app accepts either the directory containing `index.json` or the full
`index.json` URL. Package URLs resolve against the catalog directory. ZIP paths
are validated against traversal, absolute paths, drive letters, and zip bombs;
the installed directory is renamed into place atomically.

The SHA-256 hash proves integrity relative to the index. It does not
authenticate the publisher. Use HTTPS and a catalog you trust. See
`server/README.md` for the generator and nginx sample.

## Android storage permission

The manifest retains `MANAGE_EXTERNAL_STORAGE` and pre-Android-13 read access
for the optional custom-path feature. Google Play restricts these permissions;
this project does not currently claim Play Store readiness. The core app works
with remote and app-managed models without broad storage access.
