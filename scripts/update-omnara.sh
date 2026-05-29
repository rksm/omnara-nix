#!/usr/bin/env bash
# Re-pin the Omnara standalone binaries in default.nix from releases.omnara.com.
#
# Upstream serves only a mutating `/latest` (no version-stamped URLs), so this
# script recomputes the content hash of each platform artifact and, if any
# changed, rewrites default.nix. The version string is discovered by running
# the Linux x64 binary (there is no version endpoint), so this is meant to run
# on an x86_64 Linux CI runner.
#
# Requires: curl, jq, nix, python3. Emits VERSION / UPDATED to $GITHUB_OUTPUT.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nixfile="$root/default.nix"
base="https://releases.omnara.com/latest"

systems=(aarch64-darwin x86_64-darwin x86_64-linux aarch64-linux)
declare -A url=(
  [aarch64-darwin]="$base/omnara-darwin-arm64.zip"
  [x86_64-darwin]="$base/omnara-darwin-x64.zip"
  [x86_64-linux]="$base/omnara-linux-x64"
  [aarch64-linux]="$base/omnara-linux-arm64"
)

echo "computing current artifact hashes..."
declare -A newhash
for s in "${systems[@]}"; do
  newhash[$s]="$(nix store prefetch-file --json "${url[$s]}" | jq -r '.hash')"
  echo "  $s  ${newhash[$s]}"
done

# Compare against the hashes currently pinned in default.nix.
changed=false
for s in "${systems[@]}"; do
  cur="$(python3 - "$nixfile" "$s" <<'PY'
import re, sys
text, sysname = open(sys.argv[1]).read(), sys.argv[2]
m = re.search(rf'\b{re.escape(sysname)} = \{{\s*url = "[^"]*";\s*hash = "([^"]*)";', text)
print(m.group(1) if m else "")
PY
)"
  [ "$cur" != "${newhash[$s]}" ] && changed=true
done

if ! $changed; then
  echo "already up to date."
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "UPDATED=false" >>"$GITHUB_OUTPUT"
  exit 0
fi

echo "artifacts changed; discovering version from the linux-x64 binary..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "${url[x86_64-linux]}" -o "$tmp/omnara"
chmod +x "$tmp/omnara"
version="$(OMNARA_NO_UPDATE=1 "$tmp/omnara" --version 2>/dev/null | tr -d '[:space:]' || true)"
if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
  echo "ERROR: could not determine version from the binary (got: '$version')." >&2
  echo "Refusing to write a bogus version pin." >&2
  exit 1
fi
echo "new version: $version"

python3 - "$nixfile" "$version" \
  "${newhash[aarch64-darwin]}" "${newhash[x86_64-darwin]}" \
  "${newhash[x86_64-linux]}" "${newhash[aarch64-linux]}" <<'PY'
import re, sys
path, version = sys.argv[1], sys.argv[2]
hashes = {
    "aarch64-darwin": sys.argv[3],
    "x86_64-darwin":  sys.argv[4],
    "x86_64-linux":   sys.argv[5],
    "aarch64-linux":  sys.argv[6],
}
s = open(path).read()
s = re.sub(r'(\n  version = ")[^"]*(";)', rf'\g<1>{version}\g<2>', s, count=1)
for sysname, h in hashes.items():
    s = re.sub(
        rf'(\b{re.escape(sysname)} = \{{\s*\n\s*url = "[^"]*";\s*\n\s*hash = ")[^"]*(";)',
        rf'\g<1>{h}\g<2>',
        s,
    )
open(path, "w").write(s)
PY

echo "updated default.nix to $version"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "VERSION=$version" >>"$GITHUB_OUTPUT"
  echo "UPDATED=true" >>"$GITHUB_OUTPUT"
fi
