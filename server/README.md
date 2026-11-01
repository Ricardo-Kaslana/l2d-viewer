# Remote Model Catalog

This directory contains a small catalog generator and an nginx sample. It is
not a hosted service and does not include model assets.

## Generate a catalog

Requirements: Python 3.10+.

```bash
python server/generate_index.py /path/to/models /srv/live2d-models
```

The input directory must contain one subdirectory per model, each with a
`*.model3.json` at its root. The generator writes:

```text
/srv/live2d-models/
├── index.json
└── packages/
    ├── model_a.zip
    └── model_b.zip
```

`index.json` uses the `live2d-viewer.pkg-index/v1` schema. Each package has a
`latest` version and a list of `{version, url, sha256, size}` entries. The
generator is idempotent based on source mtimes and writes ZIPs/JSON atomically.

The model directory name becomes the package `id`. Keep ids safe: no path
separators, control characters, `.` or `..`; the client validates them before
installation, but a clean catalog is easier to audit.

## Serve it

The sample `nginx.conf` serves the catalog root over HTTP for local/LAN
development:

```bash
sudo cp server/nginx.conf /etc/nginx/conf.d/live2d-models.conf
sudo nginx -t && sudo systemctl reload nginx
```

For anything reachable from the internet, terminate TLS and serve HTTPS. The
client warns on plain HTTP because a network attacker can replace both the index
and its package hashes.

## Trust model

- The app validates HTTP status, declared size, streamed size, final size,
  SHA-256, ZIP path traversal, absolute paths, drive letters, control
  characters, and zip-bomb limits.
- SHA-256 proves integrity **relative to the index**. It does not prove that
  the catalog publisher is trustworthy.
- The catalog should only contain models whose license permits the intended
  distribution. This repository does not supply any such models.

## Client configuration

In **Settings → Package source URL**, enter either:

- the catalog directory: `https://example.com/models/`, or
- the full index URL: `https://example.com/models/index.json`.

Relative package URLs resolve against the catalog directory. A missing or
malformed index is reported in the Remote page; it does not modify the local
library.
