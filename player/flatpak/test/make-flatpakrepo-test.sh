#!/usr/bin/env bash
# Verifies make-flatpakrepo.sh emits files flatpak actually accepts, not merely
# files with the right-looking keys in them. Uses a throwaway GPG key and a
# throwaway flatpak installation, so it touches neither the repository nor the
# developer's real remotes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GNUPGHOME="$WORK/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

# --pinentry-mode loopback is required even for an unprotected key: without it
# gpg-agent still reaches for pinentry and fails with "No pinentry" on any
# headless machine, CI included.
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "Throwaway <throwaway@mydia.dev>" rsa2048 sign never >/dev/null 2>&1
gpg --export --armor throwaway@mydia.dev > "$WORK/pub.asc"
[ -s "$WORK/pub.asc" ] || { echo "FAIL: throwaway key generation produced no public key"; exit 1; }

FLATPAK_PUBKEY="$WORK/pub.asc" "$REPO_ROOT/player/flatpak/make-flatpakrepo.sh" "$WORK/out"

for f in mydia.flatpakrepo mydia-beta.flatpakrepo; do
  [ -f "$WORK/out/$f" ] || { echo "FAIL: $f not generated"; exit 1; }
  grep -q '^\[Flatpak Repo\]$' "$WORK/out/$f" || { echo "FAIL: $f missing section header"; exit 1; }
  grep -q '^GPGKey=' "$WORK/out/$f" || { echo "FAIL: $f missing GPGKey"; exit 1; }
done

grep -q '^Url=https://flatpak.mydia.dev/stable/$' "$WORK/out/mydia.flatpakrepo" \
  || { echo "FAIL: stable Url wrong"; exit 1; }
grep -q '^Url=https://flatpak.mydia.dev/beta/$' "$WORK/out/mydia-beta.flatpakrepo" \
  || { echo "FAIL: beta Url wrong"; exit 1; }

# The GPGKey must be base64 of a binary keyring that gpg can read back. A
# mangled key would still look fine to grep but break every client update.
grep '^GPGKey=' "$WORK/out/mydia.flatpakrepo" | cut -d= -f2- | base64 -d > "$WORK/roundtrip.gpg"
gpg --show-keys "$WORK/roundtrip.gpg" 2>/dev/null | grep -q 'throwaway@mydia.dev' \
  || { echo "FAIL: embedded GPGKey does not decode back to the signing key"; exit 1; }

# flatpak itself must accept the file. --no-gpg-verify is NOT passed, so this
# exercises the key parsing path specifically.
export FLATPAK_USER_DIR="$WORK/flatpak"
mkdir -p "$FLATPAK_USER_DIR"
if ! flatpak remote-add --user --from mydia-test "$WORK/out/mydia.flatpakrepo" 2>"$WORK/err"; then
  echo "FAIL: flatpak rejected the generated .flatpakrepo"
  cat "$WORK/err"
  exit 1
fi

flatpak remotes --user --columns=name | grep -qx mydia-test \
  || { echo "FAIL: remote was not registered"; exit 1; }

echo "PASS"
