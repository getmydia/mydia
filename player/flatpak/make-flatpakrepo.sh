#!/usr/bin/env bash
# Generates the two .flatpakrepo files users add as remotes. The embedded
# GPGKey is the base64 of the binary OpenPGP keyring that `gpg --dearmor`
# produces, which is the form flatpak expects.
#
# The public key is an operator artifact, generated alongside the private key
# and committed to this directory. It is deliberately not in the repository
# until that has happened, so this script fails loudly rather than signing
# nothing. FLATPAK_PUBKEY overrides the path, which is how the test drives it
# with a throwaway key.
#
# Usage: player/flatpak/make-flatpakrepo.sh <output-dir>
set -euo pipefail

OUT="${1:?output directory required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBKEY="${FLATPAK_PUBKEY:-$HERE/flatpak-signing-key.pub.asc}"

if [ ! -f "$PUBKEY" ]; then
  echo "::error::missing $PUBKEY" >&2
  echo "Generate the signing key and commit its public half, as described in" >&2
  echo "docs/contributing/releasing.md under 'Flatpak channels'." >&2
  exit 1
fi

mkdir -p "$OUT"
# base64 -w0 is GNU-only and fails on macOS/BSD, where operators may run
# this. `tr -d` strips the wrapping portably.
KEY_B64="$(gpg --dearmor < "$PUBKEY" | base64 | tr -d '\n')"

write_repo() {
  local file="$1" title="$2" url="$3" comment="$4"
  cat > "$OUT/$file" <<EOF
[Flatpak Repo]
Title=$title
Url=$url
Homepage=https://mydia.dev
Comment=$comment
Description=$comment
Icon=https://mydia.dev/img/logo.svg
GPGKey=$KEY_B64
EOF
  echo "wrote $OUT/$file"
}

write_repo mydia.flatpakrepo \
  "Mydia" \
  "https://flatpak.mydia.dev/stable/" \
  "Mydia Player, stable releases"

write_repo mydia-beta.flatpakrepo \
  "Mydia Beta" \
  "https://flatpak.mydia.dev/beta/" \
  "Mydia Player, prerelease builds"
