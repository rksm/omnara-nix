#!/usr/bin/env bash
# Update the pinned omnara version + wheel hashes in default.nix from the
# latest GitHub release that still ships per-platform wheels.
#
# Fails loudly (rather than writing a broken pin) if:
#   - no newer release exists,
#   - the release is missing a wheel for any supported platform, or
#   - the wheels' CPython ABI tag no longer matches `cp313`
#     (nixpkgs python3 == 3.13; a different tag needs a manual bump).
#
# Requires: curl, jq, nix. Emits VERSION / UPDATED to $GITHUB_OUTPUT in CI.
set -euo pipefail

repo="omnara-ai/omnara"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nixfile="$root/default.nix"
abi_tag="cp313"

# Each supported nix system -> (unique substring identifying its wheel asset).
systems=(aarch64-darwin x86_64-darwin x86_64-linux)
declare -A match=(
  [aarch64-darwin]="macosx_.*_arm64"
  [x86_64-darwin]="macosx_.*_x86_64"
  [x86_64-linux]="manylinux_.*_x86_64"
)

current="$(sed -n 's/^[[:space:]]*version = "\([0-9.]*\)";.*/\1/p' "$nixfile" | head -1)"
echo "current pinned version: $current"

release="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest")"
tag="$(jq -r '.tag_name' <<<"$release")"
version="${tag#v}"
echo "latest GitHub release: $tag"

if [ "$version" = "$current" ]; then
  echo "already up to date."
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "UPDATED=false" >>"$GITHUB_OUTPUT"
  exit 0
fi

assets="$(jq -r '.assets[].name' <<<"$release")"

declare -A file hash
for sys in "${systems[@]}"; do
  name="$(grep -E "^omnara-${version}-${abi_tag}-${abi_tag}-${match[$sys]}\.whl$" <<<"$assets" | head -1 || true)"
  if [ -z "$name" ]; then
    echo "ERROR: release $tag has no ${abi_tag} wheel for $sys (pattern: ${match[$sys]})." >&2
    echo "Upstream may have stopped publishing wheels, or changed the ABI tag." >&2
    echo "Available assets:" >&2; echo "$assets" | sed 's/^/  /' >&2
    exit 1
  fi
  url="https://github.com/$repo/releases/download/$tag/$name"
  echo "fetching hash: $name"
  h="$(nix store prefetch-file --json "$url" | jq -r '.hash')"
  file[$sys]="$name"
  hash[$sys]="$h"
done

# Rewrite version + each wheel's file/hash deterministically.
python3 - "$nixfile" "$version" \
  "${file[aarch64-darwin]}" "${hash[aarch64-darwin]}" \
  "${file[x86_64-darwin]}"  "${hash[x86_64-darwin]}" \
  "${file[x86_64-linux]}"   "${hash[x86_64-linux]}" <<'PY'
import re, sys
path, version = sys.argv[1], sys.argv[2]
vals = {
    "aarch64-darwin": (sys.argv[3], sys.argv[4]),
    "x86_64-darwin":  (sys.argv[5], sys.argv[6]),
    "x86_64-linux":   (sys.argv[7], sys.argv[8]),
}
s = open(path).read()
# version (first occurrence only)
s = re.sub(r'(\n  version = ")[0-9.]+(";)', rf'\g<1>{version}\g<2>', s, count=1)
# per-system file/hash inside the wheels attrset
for sysname, (fn, h) in vals.items():
    s = re.sub(
        rf'(\b{re.escape(sysname)} = \{{\s*\n\s*file = ")[^"]*(";\s*\n\s*hash = ")[^"]*(";)',
        rf'\g<1>{fn}\g<2>{h}\g<3>',
        s,
    )
open(path, "w").write(s)
PY

echo "updated default.nix to $version"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "VERSION=$version" >>"$GITHUB_OUTPUT"
  echo "UPDATED=true" >>"$GITHUB_OUTPUT"
fi
