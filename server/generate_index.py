#!/usr/bin/env python3
"""Generate pkg-index/v1 index.json and zip packages from a Live2D model directory.

Usage:
    python generate_index.py <source_dir> <output_dir>

Example:
    python generate_index.py /path/to/models /srv/live2d-models

The source directory should contain one subdirectory per model, each with a
*.model3.json file at its root. Each model is zipped into <output>/packages/<name>.zip
and an index.json is written to <output>/index.json.

Idempotent: existing zips are skipped if the source directory has not been
modified since the zip was created.
"""

import hashlib
import json
import os
import sys
import zipfile
from pathlib import Path


def find_model3_json(model_dir: Path) -> Path | None:
    for f in model_dir.iterdir():
        if f.is_file() and f.name.endswith(".model3.json"):
            return f
    return None


def derive_name(model_id: str) -> str:
    return model_id.replace("_", " ").replace("-", " ").title()


def dir_mtime(directory: Path) -> float:
    latest = directory.stat().st_mtime
    for root, _dirs, files in os.walk(directory):
        for f in files:
            mt = (Path(root) / f).stat().st_mtime
            if mt > latest:
                latest = mt
    return latest


def zip_model(model_dir: Path, zip_path: Path) -> None:
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    # Write to a sibling temp file and atomically rename into place.
    # A crash/Ctrl-C mid-write must not leave a truncated zip at the
    # final path: its mtime would be newer than every source file, so
    # the mtime skip check would treat it as up to date forever and
    # the index would advertise a corrupt package (bad sha256 aside,
    # clients still waste the download). The `.tmp` never satisfies
    # `zip_path.exists()`, so an interrupted build self-heals on the
    # next run.
    tmp_path = zip_path.with_suffix(zip_path.suffix + ".tmp")
    try:
        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as zf:
            # `followlinks=False` (default) so a stray symlink inside the
            # model directory cannot escape and smuggle in arbitrary
            # files (e.g. `/etc/passwd`) into the package. Reviewers
            # expect a package to contain only the model's own files.
            for root, _dirs, files in os.walk(model_dir):
                for f in sorted(files):
                    full = Path(root) / f
                    arcname = full.relative_to(model_dir)
                    zf.write(full, arcname)
        os.replace(tmp_path, zip_path)
    except BaseException:
        tmp_path.unlink(missing_ok=True)
        raise


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <source_dir> <output_dir>", file=sys.stderr)
        sys.exit(1)

    source_dir = Path(sys.argv[1]).resolve()
    output_dir = Path(sys.argv[2]).resolve()
    packages_dir = output_dir / "packages"

    if not source_dir.is_dir():
        print(f"Error: source directory not found: {source_dir}", file=sys.stderr)
        sys.exit(1)

    packages = []
    skipped = 0
    built = 0

    model_dirs = sorted(
        d for d in source_dir.iterdir()
        if d.is_dir() and find_model3_json(d) is not None
    )

    print(f"Found {len(model_dirs)} model directories in {source_dir}")

    # Remove stale zips for source directories that no longer exist
    # (deleted since the previous run). Without this, the index keeps
    # advertising packages whose zip is now orphaned on the server.
    if packages_dir.is_dir():
        live_ids = {d.name for d in model_dirs}
        for stale in packages_dir.glob("*.zip"):
            if stale.stem not in live_ids:
                print(f"  Removing orphan zip: {stale.name}")
                stale.unlink()
        # Leftover temp files from an interrupted run are never valid.
        for stale_tmp in packages_dir.glob("*.zip.tmp"):
            print(f"  Removing stale temp file: {stale_tmp.name}")
            stale_tmp.unlink()

    for model_dir in model_dirs:
        model_id = model_dir.name
        zip_path = packages_dir / f"{model_id}.zip"

        needs_build = True
        if zip_path.exists():
            src_mtime = dir_mtime(model_dir)
            if zip_path.stat().st_mtime >= src_mtime:
                needs_build = False
                skipped += 1

        if needs_build:
            print(f"  Packing {model_id}...")
            zip_model(model_dir, zip_path)
            built += 1

        size = zip_path.stat().st_size
        sha = sha256_file(zip_path)

        packages.append({
            "id": model_id,
            "name": derive_name(model_id),
            "latest": "1.0.0",
            "versions": [{
                "version": "1.0.0",
                "url": f"packages/{model_id}.zip",
                "sha256": sha,
                "size": size,
            }],
        })

    index = {
        "schema": "live2d-viewer.pkg-index/v1",
        "packages": packages,
    }

    index_path = output_dir / "index.json"
    output_dir.mkdir(parents=True, exist_ok=True)
    # Write atomically: write to a sibling temp file, fsync, rename.
    # A reader (nginx, browser) that opens the path mid-write would
    # otherwise see a partially-written JSON and reject it. `os.replace`
    # is atomic on POSIX (rename(2)) and Windows (MoveFileEx with
    # MOVEFILE_REPLACE_EXISTING).
    tmp_index_path = index_path.with_suffix(index_path.suffix + ".tmp")
    with open(tmp_index_path, "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_index_path, index_path)

    print(f"Done: {built} built, {skipped} skipped, {len(packages)} total in {index_path}")


if __name__ == "__main__":
    main()
