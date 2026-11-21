#!/usr/bin/env bash
#
# Build one flake attribute for CI and record its output paths.
#
# Usage: scripts/ci-nix-build.sh <attr> <out-paths-file>
#
# Runs `nix build -L --print-out-paths .#<attr>`, writing the output paths to
# <out-paths-file> for the push step. On failure it repeats the last 200
# lines of `nix log` for each derivation that failed (a dependency, not
# necessarily <attr> itself), so the cause sits at the end of the job log
# instead of somewhere in the interleaved -L output above it.
set -uo pipefail

attr="$1"
out="$2"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# stdout (the paths) goes to $out via fd 3; stderr is shown and kept for the
# failure scan.
{ nix build -L --print-out-paths ".#$attr" 2>&1 1>&3 | tee "$log" >&2; } 3>"$out"
status="${PIPESTATUS[0]}"

if [ "$status" -eq 0 ]; then
  cat "$out"
  exit 0
fi

# Older Nix: "builder for '<drv>' failed". Newer: "Cannot build '<drv>'."
# followed by a "Reason:" line; a reason of "N dependency/dependencies
# failed" marks a parent with no log of its own, so it is skipped.
mapfile -t failed < <(
  awk -v q="'" '
    BEGIN { drv = "/nix/store/[^" q "]+[.]drv" }
    function drv_of(line) { match(line, drv); return substr(line, RSTART, RLENGTH) }
    pending != "" { if ($0 !~ /dependenc(y|ies) failed/) print pending; pending = "" }
    $0 ~ ("builder for " q drv q) { print drv_of($0) }
    $0 ~ ("Cannot build " q drv q) { pending = drv_of($0) }
    END { if (pending != "") print pending }
  ' "$log" | sort -u
)
if [ "${#failed[@]}" -eq 0 ]; then
  failed=(".#$attr")
fi
for drv in "${failed[@]}"; do
  echo "::error::nix build .#$attr failed in $drv"
  echo "----- last 200 lines of nix log $drv -----"
  nix log "$drv" 2>&1 | tail -n 200
  echo "----- end of $drv -----"
done
exit "$status"
