# dots

Small, auditable CI jobs that prepare build dependencies as downloadable GitHub Actions artifacts.

## Debian 13 ALSA development bundle

The `ALSA dependency artifact` workflow runs on pushes to `main` that change its inputs, and can also be started from the Actions tab with **Run workflow**.

It downloads matching `libasound2-dev` and `libasound2t64` amd64 packages from Debian trixie's authenticated APT repositories, extracts them without running package install scripts, and verifies an ALSA compile/link and library-version smoke test after relocation. The exact versions, package metadata, SHA-256 checksums, original `.deb` files, copyright notices, and build provenance are included.

The artifact is named `alsa-sysroot-debian-trixie-amd64`. It contains a tarball and its `SHA256SUMS`. Download the artifact from a successful run, unzip it, then:

```bash
sha256sum -c SHA256SUMS
tar -xzf alsa-sysroot-debian-trixie-amd64.tar.gz
cd alsa-sysroot-debian-trixie-amd64
sha256sum -c FILES.sha256
source env.sh
pkg-config --modversion alsa
# Run the consuming project's normal build command in this shell.
```

Use a fresh shell or subshell to scope these environment variables. `env.sh` supplies the isolated pkg-config search path, include/library prefix, and runtime library path. This bundle targets Debian 13 amd64 and a compatible host toolchain/glibc; it is not a cross-compiler or a complete OS sysroot. It does not install packages globally, configure audio, or prove physical audio playback. Other dependencies still come from the consuming build environment.

Artifacts are retained for 30 days. Rerun the workflow for a fresh bundle if they expire. Each run intentionally resolves the current trixie package candidate and records the result, rather than claiming byte-identical output across repository updates.

## Security and provenance

- Only `contents: read` workflow token permissions
- Official GitHub actions pinned to full commit SHAs; checkout does not persist credentials
- Official `debian:trixie-slim` container and signed Debian APT repositories
- No custom secrets, releases, deployments, or third-party upload destinations
- The run log records the resolved container digest; the bundle records commit/run URLs and package metadata
- Debian package licensing remains in `sysroot/usr/share/doc/` and `licenses/common-licenses/`
