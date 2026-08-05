#!/bin/sh
# Asserts that E2E seeding produced every piece of state the integration tests
# need. Runs inside the mydia container. Exits non-zero naming the first
# missing item, so a broken seed fails here instead of surfacing later as a
# confusing Dart test failure.
set -eu

ADMIN_EMAIL="${E2E_ADMIN_EMAIL:-admin@test.local}"
VIDEO_PATH="/media/movies/e2e-test-video.mp4"

fail() {
    echo "ASSERT FAILED: $1" >&2
    exit 1
}

[ -f "$VIDEO_PATH" ] || fail "test video missing at $VIDEO_PATH"

RESULT=$(su-exec mydia /app/bin/mydia rpc "
    alias Mydia.{Accounts, Media, Repo, RemoteAccess}
    alias Mydia.Settings.LibraryPath

    checks = [
      {\"admin user\", Accounts.get_user_by_email(\"$ADMIN_EMAIL\") != nil},
      {\"remote access enabled\", match?(%{enabled: true}, RemoteAccess.get_config())},
      {\"library path\", Repo.get_by(LibraryPath, path: \"/media/movies\") != nil},
      {\"media item\", Repo.aggregate(Media.MediaItem, :count) > 0},
      {\"media file\", Repo.aggregate(Mydia.Library.MediaFile, :count) > 0}
    ]

    case Enum.reject(checks, fn {_label, ok} -> ok end) do
      [] -> IO.puts(\"SEED_OK\")
      [{label, _} | _] -> IO.puts(\"SEED_MISSING: \" <> label)
    end
")

case "$RESULT" in
    *SEED_OK*) echo "Seed assertions passed." ;;
    *SEED_MISSING:*) fail "$(echo "$RESULT" | grep SEED_MISSING)" ;;
    *) fail "could not evaluate seed state; rpc said: $RESULT" ;;
esac
