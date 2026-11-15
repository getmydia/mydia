#!/usr/bin/env bash
# Keep devenv.lock's nixpkgs on flake.lock's revision.
#
# devenv.yaml and flake.nix both follow nixos-unstable, and devenv.yaml says the
# two locks must agree: the devenv shell CI tests in and the package the Nix
# build ships should come from one package set, and beam-version.nix resolves
# the Elixir/OTP pair from it. Dependabot updates flake.lock only, so its nixpkgs
# bumps would leave devenv.lock behind.
#
#   scripts/sync-devenv-nixpkgs.sh          copy flake.lock's node into devenv.lock
#   scripts/sync-devenv-nixpkgs.sh --check  exit 1 if the two differ
#
# Only `locked` is copied. `original` is whatever devenv.yaml asks for, and
# rewriting it would make the next `devenv update` see a changed input.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

python3 - "${1:-}" << 'PYEOF'
import json, sys

check = sys.argv[1] == "--check"

with open("flake.lock") as f:
    flake = json.load(f)
with open("devenv.lock") as f:
    raw = f.read()
devenv = json.loads(raw)


def nixpkgs_node(lock, name):
    # The root's `nixpkgs` input names the node; it is "nixpkgs" today, but
    # Nix renames it (nixpkgs_2, ...) when two inputs pin different revisions.
    node = lock["nodes"][lock["root"]]["inputs"]["nixpkgs"]
    if not isinstance(node, str):
        sys.exit(f"{name}: root nixpkgs input is a follows, not a node")
    return lock["nodes"][node]


want = nixpkgs_node(flake, "flake.lock")["locked"]
node = nixpkgs_node(devenv, "devenv.lock")

if node["locked"] == want:
    print(f"devenv.lock nixpkgs matches flake.lock ({want['rev'][:12]}).")
    sys.exit(0)

if check:
    print(
        "devenv.lock nixpkgs is not on flake.lock's revision:\n"
        f"    flake.lock   {want['rev']}\n"
        f"    devenv.lock  {node['locked'].get('rev')}\n"
        "  Run scripts/sync-devenv-nixpkgs.sh and commit devenv.lock.",
        file=sys.stderr,
    )
    sys.exit(1)

node["locked"] = want
# devenv writes the lock without a trailing newline; keep whatever it had so a
# sync is a one-node diff.
out = json.dumps(devenv, indent=2)
if raw.endswith("\n"):
    out += "\n"
with open("devenv.lock", "w") as f:
    f.write(out)
print(f"devenv.lock nixpkgs -> {want['rev'][:12]}")
PYEOF
