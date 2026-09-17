#!/usr/bin/env bash
#
# Print the build number (Android versionCode, Apple CFBundleVersion) for a
# version string.
#
#   build = major*10_000_000 + minor*100_000 + patch*1_000 + slot
#
#   slot:  dev.N          -> N          (0..299)
#          alpha.M        -> 300 + M    (300..499)
#          beta.M         -> 500 + M    (500..699)
#          rc.M           -> 700 + M    (700..899)
#          stable         -> 900
#          +refresh.N     -> 900 + N    (901..999)
#
#   The dot is optional in prerelease suffixes: rc13 parses as rc.13.
#
# Every workflow that mints a build number calls this, so the ordering holds
# across them. Android refuses an install whose versionCode is below the
# installed one, which is what makes a dev build sort below the beta and
# stable of the same version rather than above every release forever.
#
# The previous scheme derived numbers from github.run_number with a per
# workflow offset (+10000 releases, +500000 on-demand, +900000 iOS refresh).
# Those orderings were unrelated to version order, so an on-demand build
# permanently blocked every release on any device that installed one.
set -euo pipefail
export LC_ALL=C.UTF-8

die() { echo "build-number: $*" >&2; exit 1; }

version="${1-}"
[ -n "$version" ] || die "usage: build-number.sh <version>"

version="${version#v}"

core="$version"
slot=900

case "$version" in
  *-*)
    core="${version%%-*}"
    suffix="${version#*-}"
    case "$suffix" in
      dev*|Dev*)
        n="${suffix#[Dd]ev}"
        n="${n#.}"
        [[ "$n" =~ ^[0-9]+$ ]] || die "dev suffix must be dev<number> or dev.<number>: $version"
        [ "$n" -le 299 ] || die "dev counter above 299 would collide with the alpha band: $version"
        slot=$(( 10#$n ))
        ;;
      alpha*|Alpha*)
        n="${suffix#[Aa]lpha}"
        n="${n#.}"
        [[ "$n" =~ ^[0-9]+$ ]] || die "alpha suffix must be alpha<number> or alpha.<number>: $version"
        [ "$n" -le 199 ] || die "alpha counter above 199 would collide with the beta band: $version"
        slot=$(( 300 + 10#$n ))
        ;;
      beta*|Beta*)
        n="${suffix#[Bb]eta}"
        n="${n#.}"
        [[ "$n" =~ ^[0-9]+$ ]] || die "beta suffix must be beta<number> or beta.<number>: $version"
        [ "$n" -le 199 ] || die "beta counter above 199 would collide with the rc band: $version"
        slot=$(( 500 + 10#$n ))
        ;;
      rc*|Rc*|RC*)
        n="${suffix#[Rr][Cc]}"
        n="${n#.}"
        [[ "$n" =~ ^[0-9]+$ ]] || die "rc suffix must be rc<number> or rc.<number>: $version"
        [ "$n" -le 199 ] || die "rc counter above 199 would collide with the stable slot: $version"
        slot=$(( 700 + 10#$n ))
        ;;
      *)
        die "unrecognised prerelease suffix: $version"
        ;;
    esac
    ;;
  *+refresh.*)
    core="${version%%+*}"
    n="${version#*+refresh.}"
    [[ "$n" =~ ^[0-9]+$ ]] || die "refresh suffix must be +refresh.<number>: $version"
    [ "$n" -ge 1 ] && [ "$n" -le 99 ] || die "refresh counter must be 1..99: $version"
    slot=$(( 900 + 10#$n ))
    ;;
esac

IFS='.' read -r major minor patch extra <<< "$core"
[ -z "${extra:-}" ] || die "version must be major.minor.patch: $version"
for part in "$major" "$minor" "$patch"; do
  [[ "${part-}" =~ ^[0-9]+$ ]] || die "version must be major.minor.patch: $version"
done
[ "$major" -le 209 ] || die "major above 209 overflows Android's versionCode ceiling: $version"
[ "$minor" -le 99 ] || die "minor above 99 overflows its field: $version"
[ "$patch" -le 99 ] || die "patch above 99 overflows its field: $version"

echo $(( 10#$major * 10000000 + 10#$minor * 100000 + 10#$patch * 1000 + slot ))
