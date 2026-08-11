defmodule Mydia.Repo.Migrations.PurgeFalseAutoRejectBlacklist do
  use Ecto.Migration

  # v0.13.0 (tagged 2026-08-07) shipped a pre-completion content check that
  # judged a torrent's contents from `DownloadStatus.files`. For qBittorrent
  # and rtorrent that field holds a single path which is usually the
  # torrent's root DIRECTORY, so healthy multi-file releases were rejected
  # mid-download, blacklisted, and replaced by another release that met the
  # same fate. Those rows were written as `rejected_by_user` (reject_release/2
  # hardcoded the reason regardless of actor) with a 30-day TTL, so without
  # this purge they keep suppressing good releases for a month.
  #
  # Genuine operator rejections made in the same window are also dropped.
  # That is the accepted trade: they are cheap to redo, and every affected
  # install self-heals on upgrade with no operator action.
  #
  # Rows written after the fix carry `no_importable_files` and are untouched.
  #
  # Plain DELETE. The cutoff is written as a `YYYY-MM-DD HH:MM:SS.ffffff`
  # timestamp literal, matching the stored format exactly rather than the
  # `T`-separated ISO-8601 form: SQLite compares it lexicographically as text,
  # so a format that differs from what is stored would compare wrong, while
  # PostgreSQL casts it to a timestamp. One literal is correct on both, so no
  # adapter branching is needed.
  def up do
    execute("""
    DELETE FROM release_blacklist
    WHERE failure_reason = 'rejected_by_user'
      AND inserted_at >= '2026-08-07 00:00:00.000000'
    """)
  end

  # Deleted rows cannot be reconstructed, and re-adding them would re-suppress
  # the releases this migration exists to free.
  def down, do: :ok
end
