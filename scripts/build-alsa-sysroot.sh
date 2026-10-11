#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# Run inside the official Debian trixie amd64 CI container after apt-get update.
. /etc/os-release
[[ "$ID" == debian && "$VERSION_CODENAME" == trixie ]]
[[ "$(dpkg --print-architecture)" == amd64 ]]

name=alsa-sysroot-debian-trixie-amd64
out="$PWD/dist"
bundle="$out/$name"
# Refuse to mix files from a previous build.
[[ ! -e "$bundle" ]]
mkdir -p "$bundle"/{packages,metadata,licenses,sysroot,tests}

version="$(apt-cache policy libasound2-dev:amd64 | awk '/Candidate:/ {print $2; exit}')"
[[ -n "$version" && "$version" != "(none)" ]]
packages=(libasound2-dev libasound2t64)
printf 'Package\tVersion\tArchitecture\tSHA256\tFilename\n' > "$bundle/metadata/packages.tsv"

for package in "${packages[@]}"; do
  selector="$package:amd64=$version"
  apt-cache show "$selector" > "$bundle/metadata/$package.apt.txt"
  apt-get --print-uris download "$selector" > "$bundle/metadata/$package.download.txt"
  (
    cd "$bundle/packages"
    apt-get download "$selector"
  )
  deb="$bundle/packages/${package}_${version}_amd64.deb"
  [[ -f "$deb" ]]
  expected="$(awk '/^SHA256:/ {print $2; exit}' "$bundle/metadata/$package.apt.txt")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]]
  printf '%s  %s\n' "$expected" "$deb" | sha256sum --check
  [[ "$(dpkg-deb --field "$deb" Version)" == "$version" ]]
  [[ "$(dpkg-deb --field "$deb" Architecture)" == amd64 ]]
  dpkg-deb --info "$deb" > "$bundle/metadata/$package.control.txt"
  dpkg-deb --extract "$deb" "$bundle/sysroot"
  printf '%s\t%s\tamd64\t%s\t%s\n' "$package" "$version" "$expected" "$(basename "$deb")" \
    >> "$bundle/metadata/packages.tsv"
done

# Keep the original package metadata and make only ALSA's paths relocatable.
# This avoids globally sysrooting or hiding unrelated host pkg-config packages.
pc="$bundle/sysroot/usr/lib/x86_64-linux-gnu/pkgconfig/alsa.pc"
cp "$pc" "$bundle/metadata/alsa.pc.debian-original"
sed -i \
  -e 's|^prefix=/usr$|prefix=${pcfiledir}/../../..|' \
  -e 's|^exec_prefix=/usr$|exec_prefix=${prefix}|' "$pc"
grep -Fx 'prefix=${pcfiledir}/../../..' "$pc"

cp /etc/os-release "$bundle/metadata/os-release"
cp -a /etc/apt/sources.list.d "$bundle/metadata/apt-sources.list.d"
if [[ -f /etc/apt/sources.list ]]; then
  cp /etc/apt/sources.list "$bundle/metadata/apt-sources.list"
fi
cp -a /usr/share/common-licenses "$bundle/licenses/"
cp README.md "$bundle/README.md"
cp scripts/build-alsa-sysroot.sh "$bundle/metadata/build-alsa-sysroot.sh"
{
  printf 'Built UTC: %s\n' "$(date -u +%FT%TZ)"
  printf 'Repository: https://github.com/%s\n' "${GITHUB_REPOSITORY:-local}"
  printf 'Commit: %s\n' "${GITHUB_SHA:-local}"
  printf 'Run: https://github.com/%s/actions/runs/%s\n' "${GITHUB_REPOSITORY:-local}" "${GITHUB_RUN_ID:-local}"
  printf 'Container: debian:trixie-slim (resolved digest is in the Actions job log)\n'
  printf 'Target: Debian 13 trixie amd64\n'
  printf 'ALSA package version: %s\n' "$version"
  cc --version | head -1
  pkg-config --version
  ldd --version | head -1
} > "$bundle/metadata/provenance.txt"

cat > "$bundle/env.sh" <<'ENV'
# Source this file from Bash in a subshell to scope the dependency environment.
_alsa_bundle="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export ALSA_SYSROOT="$_alsa_bundle/sysroot"
if [[ -n "${PKG_CONFIG_SYSROOT_DIR:-}" && "${PKG_CONFIG_SYSROOT_DIR}" != "/" ]]; then
  printf '%s\n' 'Use this native ALSA bundle in a shell without PKG_CONFIG_SYSROOT_DIR.' >&2
  return 1
fi
export PKG_CONFIG_PATH="$ALSA_SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$ALSA_SYSROOT/usr/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$ALSA_SYSROOT/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset _alsa_bundle
ENV

cat > "$bundle/tests/alsa-smoke.c" <<'C'
#include <alsa/asoundlib.h>
#include <stdio.h>

int main(void) {
    puts(snd_asoundlib_version());
    return 0;
}
C

# Test the extracted bundle in a different directory and explicitly select its
# runtime. No audio device is opened and no global ALSA package is installed.
testroot="$(mktemp -d)"
trap 'rm -rf -- "$testroot"' EXIT
cp -a "$bundle" "$testroot/relocated"
mkdir "$testroot/host-pkgconfig"
cat > "$testroot/host-pkgconfig/host-probe.pc" <<'PC'
prefix=/usr
Name: host-probe
Description: Test that non-ALSA pkg-config metadata stays visible and unchanged
Version: 1.0
PC
(
  export PKG_CONFIG_PATH="$testroot/host-pkgconfig"
  source "$testroot/relocated/env.sh"
  [[ "$(pkg-config --variable=pcfiledir alsa)" == "$ALSA_SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig" ]]
  [[ "$(pkg-config --variable=prefix host-probe)" == /usr ]]
  pkg-config --modversion alsa
  pkg-config --cflags --libs alsa
  read -r -a cflags <<< "$(pkg-config --cflags alsa)"
  read -r -a libs <<< "$(pkg-config --libs alsa)"
  cc -Wall -Wextra -Werror "${cflags[@]}" "$bundle/tests/alsa-smoke.c" \
    -o "$testroot/alsa-smoke" "${libs[@]}"
  ldd "$testroot/alsa-smoke"
  ldd "$testroot/alsa-smoke" | grep -F "libasound.so.2 => $ALSA_SYSROOT/"
  "$testroot/alsa-smoke"
) | tee "$bundle/tests/smoke-test.txt"

# Retain the symlink topology inside the tarball; Actions' outer ZIP alone does not.
(
  cd "$bundle"
  find sysroot -type l -printf '%p -> %l\n' | sort > metadata/symlinks.txt
  find . -type f ! -name FILES.sha256 -print0 | sort -z | xargs -0 sha256sum > FILES.sha256
  sha256sum --check FILES.sha256
)
tar --sort=name --owner=0 --group=0 --numeric-owner -czf "$out/$name.tar.gz" -C "$out" "$name"
(
  cd "$out"
  sha256sum "$name.tar.gz" > SHA256SUMS
  sha256sum --check SHA256SUMS
)
cat "$bundle/metadata/packages.tsv"
cat "$out/SHA256SUMS"
