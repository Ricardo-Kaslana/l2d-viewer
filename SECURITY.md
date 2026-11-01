# Security Policy

## Supported versions

Security fixes are applied to the latest public release and the `main` branch.
Older pre-public builds that used the previous placeholder application ID are
not supported.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's
private vulnerability reporting flow in the repository's **Security** tab.
Include:

- affected version or commit;
- platform and device;
- reproduction steps;
- impact and any known mitigations.

The maintainers will acknowledge reports as time permits. This is a volunteer
project and no response-time SLA is offered.

## Threat model

- **Remote model catalogs are untrusted.** The app verifies package length and
  SHA-256 from the index, and rejects path traversal and zip bombs. A SHA-256
  hash supplied by an untrusted index proves integrity relative to that index,
  not authenticity. Use HTTPS and a source you trust. Plain HTTP remains
  available only for local/LAN development and produces a warning.
- **Model files are untrusted input.** Texture preflight bounds dimensions and
  decoded memory before handing files to Mocari. A malicious model can still
  consume substantial GPU/CPU resources; do not load models from untrusted
  sources.
- **Android "All files access" is optional.** The app can download, install,
  and render models from its managed directory without broad storage access.
  The all-files permission is requested only when the user adds a custom
  external path. Google Play distribution is not currently claimed; the
  permission is subject to Play policy review.
- **No telemetry is implemented.** The app does not include analytics or crash
  reporting dependencies.

## Secrets

Never commit keystores, passwords, tokens, `local.properties`, or signing
material. Release builds use repository secrets only inside CI. A missing
signing secret produces a debug-signed or unsigned artifact, never a fabricated
release signature.
