#!/usr/bin/env bash
# Run the full test suite as `mix test --partitions N` processes side by side,
# the way CI shards it across runners. The SQLite suite runs with max_cases: 1
# (test/test_helper.exs), so a single local run keeps one core busy for ~10
# minutes.
#
# Runs inside the devenv shell (./dev test and ./dev mix precommit call it).
# Extra arguments are passed to every partition's `mix test`.
#
# Each partition gets what CI gets from a separate runner:
#   - its own SQLite file (config/test.exs suffixes MIX_TEST_PARTITION), or its
#     own PostgreSQL database (mydia_testN, same suffix);
#   - its own empty TMPDIR, so tmp-rooted fixtures that name paths with
#     System.unique_integer/1 (which restarts low in every BEAM) cannot collide
#     with another partition or with leftovers from an earlier run;
#   - its own S3 bucket (MYDIA_TEST_S3_BUCKET), for the same reason.
#
# --partitions deals test files out round-robin, not by duration, so equal
# partitions finish minutes apart. Cutting more partitions than run at once
# (MYDIA_TEST_PARTITIONS, default 2x jobs) lets a free slot pick up the next
# one. MYDIA_TEST_JOBS caps how many run at once (default: half the cores,
# 2..8). MYDIA_TEST_PARTITIONS=1 runs plain `mix test`.
set -uo pipefail

export MIX_ENV=test

cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
jobs=${MYDIA_TEST_JOBS:-$(( cores / 2 ))}
(( jobs < 2 )) && jobs=2
(( jobs > 8 )) && [ -z "${MYDIA_TEST_JOBS:-}" ] && jobs=8
n=${MYDIA_TEST_PARTITIONS:-$(( jobs * 2 ))}
schedulers=$(( cores / jobs ))
(( schedulers < 2 )) && schedulers=2

if (( n <= 1 )); then
    mix ecto.create --quiet && mix ecto.migrate --quiet || exit $?
    exec mix test "$@"
fi

# Compile once up front; concurrent compiles of a stale _build would race.
mix compile || exit $?

root=$(pwd -P)
# Short and per-checkout: worktrees share /tmp, and a long TMPDIR breaks the
# unix-socket paths some tests create.
tag=$(printf '%s' "$root" | cksum | cut -d' ' -f1)
base="${TMPDIR:-/tmp}/mydia-t$tag"
# A second run in this checkout would share the partition databases, logs and
# exit records, and could report the other run's results as its own.
# In the checkout, not under TMPDIR, so runs with different TMPDIRs still
# exclude each other. _build is gitignored and already exists after compile.
lock="$root/_build/.test-partitioned.lock"
if ! mkdir "$lock" 2>/dev/null; then
    echo "Another partitioned test run is active in this checkout ($lock)." >&2
    echo "If none is, remove that directory and retry." >&2
    exit 1
fi
trap 'rmdir "$lock"' EXIT
rm -rf "$base"
mkdir -p "$base"

s3_bucket=${MYDIA_TEST_S3_BUCKET:-mydia-test}
start=$SECONDS

run_partition() {
    local i=$1
    shift
    mkdir -p "$base/p$i/tmp"
    (
        export MIX_TEST_PARTITION=$i
        export TMPDIR="$base/p$i/tmp"
        export MYDIA_TEST_S3_BUCKET="$s3_bucket-p$i"
        export MYDIA_TEST_FAILURES_MANIFEST="$base/p$i/failures"
        # $jobs BEAMs each starting one scheduler per core, all spinning while
        # idle, starve each other: timing-sensitive tests (2s assert_receive,
        # 5s accept) then fail only here. Split the cores and stop the spin.
        export ERL_FLAGS="${ERL_FLAGS:-} +S $schedulers +sbwt none +sbwtdcpu none +sbwtdio none"
        mix ecto.create --quiet && mix ecto.migrate --quiet &&
            mix test --partitions "$n" "$@"
        echo "EXIT=$?" > "$base/p$i/exit"
    ) > "$base/p$i/log" 2>&1
}

echo "Running $n partitions, $jobs at a time (logs: $base/p*/log)"
for i in $(seq 1 "$n"); do
    while (( $(jobs -rp | wc -l) >= jobs )); do wait -n; done
    run_partition "$i" "$@" &
done
wait

# Each partition wrote its own failures manifest (a shared one is read at start
# and replaced at finish, so partitions would erase each other's failures).
# Merge them into the default path so `./dev test --failed` reruns them all.
# A partition whose files failed to load writes the "rerun everything"
# sentinel, which read/1 would turn into an empty map; keep it. The default
# path follows Mix's build path, which devenv moves for DATABASE_TYPE=postgres.
build_path="${MIX_BUILD_PATH:-${MIX_BUILD_ROOT:-_build}/test}"
case "$build_path" in /*) ;; *) build_path="$root/$build_path" ;; esac
elixir -e '
  alias ExUnit.FailuresManifest, as: M
  [out | parts] = System.argv()

  if Enum.any?(parts, &(M.info(&1) == :all)) do
    M.fail_all!(out)
  else
    parts |> Enum.map(&M.read/1) |> Enum.reduce(%{}, &Map.merge/2) |> M.write!(out)
  end
' "$build_path/lib/mydia/.mix/.mix_test_failures" "$base"/p*/failures 2>/dev/null ||
    echo "warning: could not merge failure manifests; ./dev test --failed may be incomplete" >&2

status=0
passed=0
failed=0
failed_parts=()
for i in $(seq 1 "$n"); do
    log="$base/p$i/log"
    code=$(sed -n 's/^EXIT=//p' "$base/p$i/exit" 2>/dev/null)
    code=${code:-1}
    clean=$(sed 's/\x1b\[[0-9;]*m//g' "$log")
    result=$(echo "$clean" | grep -E '^Result: ' | tail -1)
    # With path arguments, a partition can be dealt no files at all.
    if [ -z "$result" ] && echo "$clean" | grep -q '^Paths given to "mix test" did not match'; then
        code=0
        result="(no files in this partition)"
    fi
    finished=$(echo "$clean" | grep -oE '^Finished in [0-9.]+ seconds' | grep -oE '[0-9.]+' | tail -1)
    # ExUnit prints "Result: 940 passed, ..." or, with failures,
    # "Result: 1237/1238 passed, ...".
    counts=$(echo "$result" | grep -oE '[0-9]+(/[0-9]+)? passed' | grep -oE '[0-9/]+')
    p=${counts%%/*}
    t=${counts##*/}
    passed=$(( passed + ${p:-0} ))
    failed=$(( failed + ${t:-0} - ${p:-0} ))
    if [ "$code" != "0" ]; then
        status=1
        failed_parts+=("$i")
    fi
    printf 'partition %2d/%d  %6ss  %s\n' "$i" "$n" "${finished:-?}" "${result:-no result (exit $code)}"
done

for i in "${failed_parts[@]}"; do
    echo ""
    echo "── partition $i/$n (full log: $base/p$i/log) ──"
    # Numbered failure blocks, else the tail (a crash before the suite started).
    blocks=$(sed 's/\x1b\[[0-9;]*m//g' "$base/p$i/log" | sed -n '/^  [0-9]\+) /,/^$/p')
    if [ -n "$blocks" ]; then echo "$blocks"; else tail -30 "$base/p$i/log"; fi
done

echo ""
# "N tests, M failures" is what ./dev's precommit summary greps for.
echo "$(( passed + failed )) tests, $failed failures across $n partitions in $(( SECONDS - start ))s"
# Empty partitions are fine one at a time; a run that executed nothing (a
# mistyped path in every partition) is not, matching plain `mix test`.
if (( passed + failed == 0 )); then
    echo "No tests ran." >&2
    status=1
fi
exit $status
