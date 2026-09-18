#!/usr/bin/env bash
# Asserts the BEAM pins hold. .elixir-version must be the only file naming an
# Elixir version, .otp-version the only file naming an OTP major, and the
# Dockerfile's builder and runtime bases must agree with both and with each
# other.
#
# Run by ci-nix.yml's "Check / BEAM Pin" job, and runnable locally. Needs only
# a git checkout, since it scans tracked files.
#
# Scope: every file that can select an SDK (nix modules, workflows,
# Dockerfiles, compose files, scripts, ./dev and mix.exs). Exclusions, each for
# a reason:
#   - metadata-relay/ and .github/workflows/ci-relay.yml. A separately deployed
#     service with its own mix.exs, CI and release schedule. ci-relay.yml lives
#     under .github/workflows/ rather than metadata-relay/, so it is named by
#     exact path.
#   - Dockerfile. A `FROM` line needs a literal and a digest cannot be derived
#     from a file, so it gets a stronger check than the scan, below.
#   - mix.exs, for the Elixir scan only. Its `elixir:` requirement is a Hex
#     version floor used in dependency resolution, not an SDK selection, and
#     Mix cannot read that floor from an external file.
#   - `uses:` lines. SHA-pinning an action with a trailing version comment is
#     not an SDK selection and must not trip this check.
#   - NIF versions (`nif-N.N`), for the Elixir scan only. A precompiled NIF's
#     ABI version is not an Elixir version, and the wasmex checksum file that
#     names one is itself called checksum-Elixir.*. Only that token is
#     stripped, so an Elixir version elsewhere on the same line still counts.
#
# Both scans ignore case, so shouty spellings such as an ELIXIR_VERSION or
# ERLANG_VERSION env var are caught too.
#
# This script is in scope for its own scan, so do not write a version literal
# in these comments either.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

# $1: grep -E pattern. $2: optional extra grep flag (-i).
scan() {
  git ls-files -z \
      '*.nix' '.github/workflows/*' '*Dockerfile*' '*compose*.yml' \
      'scripts/*' 'dev' 'mix.exs' \
    | xargs -0 grep -HnI ${2:-} -E "$1" \
    | grep -viE '^metadata-relay/|^\.github/workflows/ci-relay\.yml:' \
    | grep -vE '^Dockerfile:' \
    | grep -vE ':[[:space:]]*uses:[[:space:]]*[^[:space:]]+@' \
    || true
}

elixir_hits="$(
  scan 'elixir' -i \
    | grep -vE '^mix\.exs:' \
    | grep -viE 'elixir_make|bcrypt_elixir|argon2_elixir|yaml_elixir' \
    | sed -E 's/nif-[0-9]+(\.[0-9]+)+//gI' \
    | grep -iE '[0-9]+\.[0-9]+|elixir_[0-9]' \
    || true
)"
if [ -n "$elixir_hits" ]; then
  echo "::error::An Elixir version literal escaped .elixir-version"
  echo "$elixir_hits"
  echo
  echo ".elixir-version is the single source of truth. Read from it instead:"
  echo "  nix         -> import ./beam-version.nix { inherit pkgs; }"
  echo "  Dockerfile  -> the base tag is checked against it below"
  fail=1
else
  echo "OK: .elixir-version is the only file naming an Elixir version."
fi

otp_pattern="erlang[_-][0-9]|otp-[0-9]|(otp|erlang)[-_]version[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[0-9]|\\botp[[:space:]]*[0-9]{2}\\b"
otp_hits="$(scan "$otp_pattern" -i)"
if [ -n "$otp_hits" ]; then
  echo "::error::An OTP major escaped .otp-version"
  echo "$otp_hits"
  echo
  echo ".otp-version is the single source of truth. Read from it instead:"
  echo "  nix         -> import ./beam-version.nix { inherit pkgs; }"
  echo "  Dockerfile  -> the base tag is checked against it below"
  fail=1
else
  echo "OK: .otp-version is the only file naming an OTP major."
fi

elixir_pin="$(tr -d '\n' < .elixir-version)"
otp_pin="$(tr -d '\n' < .otp-version)"

builder="$(grep -m1 -oE '^FROM hexpm/elixir:[^@[:space:]]+' Dockerfile | cut -d: -f2 || true)"
runtime="$(grep -oE '^FROM alpine:[^@[:space:]]+' Dockerfile | tail -1 | cut -d: -f2 || true)"
runtime_alpine="$(grep -oE '^[0-9]+\.[0-9]+' <<< "$runtime" || true)"

tag_re='^([0-9]+\.[0-9]+)\.[0-9]+-erlang-([0-9]+)(\.[0-9]+)*-alpine-([0-9]+\.[0-9]+)(\.[0-9]+)?$'
if [[ ! "$builder" =~ $tag_re ]]; then
  echo "::error file=Dockerfile::builder must be FROM hexpm/elixir:<elixir>-erlang-<otp>-alpine-<alpine>, found '${builder:-<none>}'"
  fail=1
else
  tag_elixir="${BASH_REMATCH[1]}"
  tag_otp="${BASH_REMATCH[2]}"
  tag_alpine="${BASH_REMATCH[4]}"

  if [ "$tag_elixir" != "$elixir_pin" ]; then
    echo "::error file=Dockerfile::builder is Elixir $tag_elixir but .elixir-version pins $elixir_pin"
    fail=1
  fi
  if [ "$tag_otp" != "$otp_pin" ]; then
    echo "::error file=Dockerfile::builder is OTP $tag_otp but .otp-version pins $otp_pin"
    fail=1
  fi
  if [ "$tag_alpine" != "$runtime_alpine" ]; then
    echo "::error file=Dockerfile::builder is Alpine $tag_alpine but the runtime stage is FROM alpine:${runtime:-<none>}; the release carries the builder's ERTS, so the minors must match"
    fail=1
  fi
  if [ "$fail" = 0 ]; then
    echo "OK: Dockerfile builder $builder matches both pins and the runtime alpine:$runtime."
  fi
fi

exit "$fail"
