#!/usr/bin/env bash
#
# Print the build number (Android versionCode, Apple CFBundleVersion) for a
# version string.
#
#   build = major*100_000_000 + minor*1_000_000 + patch*100_000 + slot
#
#   slot:  dev.K               -> K                    (K 0..9_999)
#          alpha.M[.dev.K]     -> 10_000 + M*1_000 + K (M 0..19)
#          beta.M[.dev.K]      -> 30_000 + M*1_000 + K (M 0..29)
#          rc.M[.dev.K]        -> 60_000 + M*1_000 + K (M 0..29)
#          stable              -> 90_000
#          +refresh.N          -> 90_000 + N           (N 1..99)
#
#   A .dev.K tail (K 1..999) is an on-demand build made K first-parent
#   commits after that prerelease: above it, below the next one. The dot is
#   optional in the prerelease itself: rc13 parses as rc.13.
#
# Every workflow that mints a build number calls this, so the ordering holds
# across them. Android refuses an install whose versionCode is below the
# installed one, and the ordering is what lets a device move from any build to
# any later one.
#
# Two schemes came before this one. Run-number offsets let an on-demand build
# outrank every later release. The first version-derived scheme put every dev
# build below every beta of the same version, so a dev build made after a beta
# looked older than it. Every number here clears both.
set -euo pipefail
export LC_ALL=C.UTF-8

die() { echo "build-number: $*" >&2; exit 1; }

version="${1-}"
[ -n "$version" ] || die "usage: build-number.sh <version>"

version="${version#v}"

core="$version"
slot=90000

case "$version" in
  *-*)
    core="${version%%-*}"
    suffix="$(printf '%s' "${version#*-}" | tr '[:upper:]' '[:lower:]')"
    [[ "$suffix" =~ ^(dev|alpha|beta|rc)\.?([0-9]+)(\.dev\.([0-9]+))?$ ]] \
      || die "unrecognised prerelease suffix: $version"
    band="${BASH_REMATCH[1]}"
    n=$(( 10#${BASH_REMATCH[2]} ))
    tail="${BASH_REMATCH[3]}"
    k=$(( 10#${BASH_REMATCH[4]:-0} ))
    case "$band" in
      dev)
        [ -z "$tail" ] || die "a dev build cannot carry a second dev tail: $version"
        [ "$n" -le 9999 ] || die "dev counter above 9999 would collide with the alpha band: $version"
        slot=$n
        ;;
      *)
        case "$band" in
          alpha) base=10000; max=19 ;;
          beta)  base=30000; max=29 ;;
          rc)    base=60000; max=29 ;;
        esac
        [ "$n" -le "$max" ] || die "$band counter above $max would collide with the next band: $version"
        if [ -n "$tail" ]; then
          [ "$k" -ge 1 ] || die "dev tail must start at 1; dev.0 is the prerelease itself: $version"
          [ "$k" -le 999 ] || die "dev tail above 999 would collide with $band.$(( n + 1 )): $version"
        fi
        slot=$(( base + n * 1000 + k ))
        ;;
    esac
    ;;
  *+refresh.*)
    core="${version%%+*}"
    n="${version#*+refresh.}"
    [[ "$n" =~ ^[0-9]+$ ]] || die "refresh suffix must be +refresh.<number>: $version"
    [ "$n" -ge 1 ] && [ "$n" -le 99 ] || die "refresh counter must be 1..99: $version"
    slot=$(( 90000 + 10#$n ))
    ;;
esac

IFS='.' read -r major minor patch extra <<< "$core"
[ -z "${extra:-}" ] || die "version must be major.minor.patch: $version"
for part in "$major" "$minor" "$patch"; do
  [[ "${part-}" =~ ^[0-9]+$ ]] || die "version must be major.minor.patch: $version"
done
[ $(( 10#$major )) -le 20 ] || die "major above 20 overflows Android's versionCode ceiling: $version"
[ $(( 10#$minor )) -le 99 ] || die "minor above 99 overflows its field: $version"
[ $(( 10#$patch )) -le 9 ] || die "patch above 9 overflows its field: $version"

echo $(( 10#$major * 100000000 + 10#$minor * 1000000 + 10#$patch * 100000 + slot ))
