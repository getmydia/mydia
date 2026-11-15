#!/usr/bin/env bash
# Run the player suite the way CI's `Test / Player` does (very_good-style
# bundles, so 850 files compile a handful of times instead of 850), split into
# one bundle per shard so it uses more than one core.
#
# Runs inside the devenv shell from the repo root (`./dev player test` calls
# it). Extra arguments go to every `flutter test`.
#
# Each bundle is very_good_cli 1.5.0's test/.test_optimizer.dart template: each
# file's main() inside a group named after its path, sharing one isolate, so a
# cross-file state leak fails here as it does in CI (player/docs/workflow.md).
# Files are dealt round-robin from the sorted list, not cut into ranges:
# `flutter test --total-shards` cuts contiguous ranges, which put most widget
# tests in one shard (9s to 200s across 8). Neighbours differ from CI's single
# bundle, so CI stays the authority on ordering-dependent leaks.
#
# Files tagged skip_very_good_optimization (browser tests, macOS goldens) run
# in one extra unbundled `flutter test`, as very_good does. On Linux none of
# them runs, and "No tests were found" (exit 79) counts as a pass.
#
# MYDIA_PLAYER_TEST_SHARDS sets the shard count (default: half the cores, 2..8).
set -uo pipefail

cd "$(dirname "$0")/../player" || exit 1

cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
shards=${MYDIA_PLAYER_TEST_SHARDS:-$(( cores / 2 ))}
(( shards < 1 )) && shards=1
(( shards > 8 )) && [ -z "${MYDIA_PLAYER_TEST_SHARDS:-}" ] && shards=8

tag=$(printf '%s' "$(pwd -P)" | cksum | cut -d' ' -f1)
logs="${TMPDIR:-/tmp}/mydia-pt$tag"
rm -rf "$logs"
mkdir -p "$logs"
trap 'rm -f test/.test_optimizer_s*.dart' EXIT

bundled=()
unbundled=()
while IFS= read -r f; do
    if grep -qE "^@Tags\(\[.*['\"]skip_very_good_optimization['\"]" "$f"; then
        unbundled+=("$f")
    else
        bundled+=("${f#test/}")
    fi
done < <(find test -name '*_test.dart' | LC_ALL=C sort)

# Writes the bundle holding every $shards-th file starting at $1.
write_bundle() {
    local shard=$1 out=$2 j
    {
        echo "// GENERATED CODE - DO NOT MODIFY BY HAND (scripts/player-test-sharded.sh)"
        echo "import 'dart:io';"
        echo "import 'dart:typed_data';"
        echo ""
        echo "import 'package:flutter_test/flutter_test.dart';"
        echo ""
        for (( j = shard; j < ${#bundled[@]}; j += shards )); do
            echo "import '${bundled[$j]}' as t$j;"
        done
        echo ""
        echo "void main() {"
        echo "  goldenFileComparator = _TestOptimizationAwareGoldenFileComparator(goldenFileComparator as LocalFileComparator);"
        for (( j = shard; j < ${#bundled[@]}; j += shards )); do
            echo "  group('${bundled[$j]}', () { t$j.main(); });"
        done
        cat <<'DART'
}

class _TestOptimizationAwareGoldenFileComparator extends GoldenFileComparator {
  final List<String> goldenFilePaths;
  final LocalFileComparator previousGoldenFileComparator;

  _TestOptimizationAwareGoldenFileComparator(this.previousGoldenFileComparator)
      : goldenFilePaths = _goldenFilePaths;

  static List<String> get _goldenFilePaths =>
      Directory.fromUri((goldenFileComparator as LocalFileComparator).basedir)
          .listSync(recursive: true, followLinks: true)
          .whereType<File>()
          .map((file) => file.path)
          .where((path) => path.endsWith('.png'))
          .toList();

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) =>
      previousGoldenFileComparator.compare(imageBytes, golden);

  @override
  Uri getTestUri(Uri key, int? version) {
    final keyString = key.toFilePath();
    return Uri.parse(goldenFilePaths
        .singleWhere((goldenFilePath) => goldenFilePath.endsWith(keyString)));
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) =>
      previousGoldenFileComparator.update(golden, imageBytes);
}
DART
    } > "$out"
}

start=$SECONDS
echo "Running ${#bundled[@]} bundled files in $shards bundles, ${#unbundled[@]} unbundled (logs: $logs)"

for i in $(seq 0 $(( shards - 1 ))); do
    bundle="test/.test_optimizer_s$i.dart"
    write_bundle "$i" "$bundle"
    (
        # Every `flutter test` rewrites the shared build/unit_test_assets on
        # start, so one can lose the copy race to another and die before
        # running anything. Retry only that.
        for attempt in 1 2 3; do
            flutter test --concurrency 1 --reporter expanded --no-pub "$@" "$bundle" \
                > "$logs/s$i.log" 2>&1
            code=$?
            grep -q '^Flutter failed to copy file' "$logs/s$i.log" || break
            sleep $(( attempt * 2 ))
        done
        echo "EXIT=$code" > "$logs/s$i.exit"
    ) &
    sleep 1
done
if (( ${#unbundled[@]} > 0 )); then
    (
        flutter test --concurrency 1 --reporter expanded --no-pub "$@" "${unbundled[@]}"
        code=$?
        (( code == 79 )) && code=0
        echo "EXIT=$code" > "$logs/unbundled.exit"
    ) > "$logs/unbundled.log" 2>&1 &
fi
wait

status=0
passed=0
failed=0
skipped=0
for log in "$logs"/*.log; do
    name=$(basename "$log" .log)
    code=$(sed -n 's/^EXIT=//p' "${log%.log}.exit" 2>/dev/null)
    code=${code:-1}
    # Last progress line: "MM:SS +passed ~skipped -failed: ...".
    last=$(tr '\r' '\n' < "$log" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -E '^[0-9]+:[0-9]{2} \+[0-9]+' | tail -1)
    p=$(echo "$last" | grep -oE ' \+[0-9]+' | head -1 | tr -d ' +')
    s=$(echo "$last" | grep -oE ' ~[0-9]+' | head -1 | tr -d ' ~')
    f=$(echo "$last" | grep -oE ' -[0-9]+' | head -1 | tr -d ' -')
    passed=$(( passed + ${p:-0} ))
    skipped=$(( skipped + ${s:-0} ))
    failed=$(( failed + ${f:-0} ))
    elapsed=$(echo "$last" | grep -oE '^[0-9]+:[0-9]{2}')
    printf '%-10s %6s  +%s ~%s -%s (exit %s)\n' "$name" "${elapsed:-?}" "${p:-0}" "${s:-0}" "${f:-0}" "$code"
    if [ "$code" != "0" ]; then
        status=1
        echo "── $name failures (full log: $log) ──"
        tr '\r' '\n' < "$log" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -E '\[E\]$' | sed 's/^[0-9:]* [^:]*: /  /' | sort -u
        [ "${f:-0}" = "0" ] && tail -20 "$log"
    fi
done

echo ""
echo "$passed passed, $skipped skipped, $failed failed in $(( SECONDS - start ))s"
exit $status
