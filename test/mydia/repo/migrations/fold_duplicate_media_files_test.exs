defmodule Mydia.Repo.Migrations.FoldDuplicateMediaFilesTest do
  use Mydia.MigrationCase

  Code.require_file(
    "priv/repo/migrations/20260901234336_fold_duplicate_media_files_and_enforce_path_uniqueness.exs"
  )

  alias Mydia.Repo.Migrations.FoldDuplicateMediaFilesAndEnforcePathUniqueness

  @version 20_260_901_234_336

  @tag :tmp_dir
  test "folds two active rows for one canonical path onto the row with more dependents" do
    build_pre_migration_schema()

    # Two library paths over the same tree, one with a trailing slash. Both
    # rows resolve to /media/movies/Cinder Lantern (2014)/Cinder.Lantern.mkv.
    seed_library_path("lib-plain", "/media/movies")
    seed_library_path("lib-slash", "/media/movies/")
    seed_media_item("item-1")

    seed_media_file("winner", "lib-plain", "Cinder Lantern (2014)/Cinder.Lantern.mkv", "item-1")
    seed_media_file("loser", "lib-slash", "Cinder Lantern (2014)/Cinder.Lantern.mkv", "item-1")

    sql!("INSERT INTO media_hashes (media_file_id, opensubtitles_hash) VALUES ('winner', 'aaa')")
    sql!("INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('s1', 'loser', 'h1')")
    sql!("INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('s2', 'winner', 'h1')")
    sql!("INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('s3', 'loser', 'h2')")
    sql!("INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('s4', 'winner', 'h3')")

    run_migration!(FoldDuplicateMediaFilesAndEnforcePathUniqueness, @version)

    assert %{rows: [["winner"]]} = sql!("SELECT id FROM media_files")

    # s3 had no counterpart on the winner and moved across. s1 collided with
    # s2 on (media_file_id, subtitle_hash) and was dropped.
    assert %{rows: [["s2", "h1"], ["s3", "h2"], ["s4", "h3"]]} =
             sql!("SELECT id, subtitle_hash FROM subtitles ORDER BY id")
  end

  @tag :tmp_dir
  test "leaves a trashed duplicate and a lone row alone" do
    build_pre_migration_schema()

    seed_library_path("lib-plain", "/media/movies")
    seed_media_item("item-1")

    seed_media_file("active", "lib-plain", "Harrow Bay (2011)/Harrow.Bay.mkv", "item-1")
    seed_media_file("trashed", "lib-plain", "Harrow Bay (2011)/Harrow.Bay.mkv", "item-1")
    sql!("UPDATE media_files SET trashed_at = '2026-08-01 00:00:00' WHERE id = 'trashed'")

    seed_media_file("solo", "lib-plain", "Pale Orchard (2018)/Pale.Orchard.mkv", "item-1")

    run_migration!(FoldDuplicateMediaFilesAndEnforcePathUniqueness, @version)

    assert %{rows: [["active"], ["solo"], ["trashed"]]} =
             sql!("SELECT id FROM media_files ORDER BY id")
  end

  @tag :tmp_dir
  test "repoints or drops media_hashes, the only dependent with no key beyond media_file_id" do
    build_pre_migration_schema()

    seed_library_path("lib-plain", "/media/movies")
    seed_media_item("item-1")

    # Group A: both winner_a and loser_a already carry a media_hashes row, so
    # the winner's row must survive untouched and the loser's must be
    # dropped rather than merged. winner_a is strictly richer (3 dependents
    # to 2) so the outcome rests on the primary signal, not a tie-break.
    seed_media_file("winner_a", "lib-plain", "Amber Foundry (2013)/Amber.Foundry.mkv", "item-1")
    seed_media_file("loser_a", "lib-plain", "Amber Foundry (2013)/Amber.Foundry.mkv", "item-1")

    sql!(
      "INSERT INTO media_hashes (media_file_id, opensubtitles_hash) VALUES ('winner_a', 'hash-winner-a')"
    )

    sql!(
      "INSERT INTO media_hashes (media_file_id, opensubtitles_hash) VALUES ('loser_a', 'hash-loser-a')"
    )

    sql!(
      "INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('a1', 'winner_a', 'h1')"
    )

    sql!(
      "INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('a2', 'winner_a', 'h2')"
    )

    sql!(
      "INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('a3', 'loser_a', 'h3')"
    )

    # Group B: only loser_b carries a media_hashes row, so it must move onto
    # winner_b rather than being dropped. winner_b is still strictly richer
    # (2 dependents to 1) so this again rests on the primary signal.
    seed_media_file("winner_b", "lib-plain", "Quiet Ledger (2017)/Quiet.Ledger.mkv", "item-1")
    seed_media_file("loser_b", "lib-plain", "Quiet Ledger (2017)/Quiet.Ledger.mkv", "item-1")

    sql!(
      "INSERT INTO media_hashes (media_file_id, opensubtitles_hash) VALUES ('loser_b', 'hash-loser-b')"
    )

    sql!(
      "INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('b1', 'winner_b', 'h1')"
    )

    sql!(
      "INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('b2', 'winner_b', 'h2')"
    )

    run_migration!(FoldDuplicateMediaFilesAndEnforcePathUniqueness, @version)

    assert %{rows: [["winner_a"], ["winner_b"]]} =
             sql!("SELECT id FROM media_files ORDER BY id")

    # Collision: winner_a's own hash survives; loser_a's hash is gone, not
    # merged onto the winner.
    assert %{rows: [["winner_a", "hash-winner-a"]]} =
             sql!(
               "SELECT media_file_id, opensubtitles_hash FROM media_hashes WHERE media_file_id = 'winner_a'"
             )

    assert %{rows: []} =
             sql!("SELECT 1 FROM media_hashes WHERE opensubtitles_hash = 'hash-loser-a'")

    # Move: loser_b's hash now belongs to winner_b.
    assert %{rows: [["winner_b", "hash-loser-b"]]} =
             sql!(
               "SELECT media_file_id, opensubtitles_hash FROM media_hashes WHERE opensubtitles_hash = 'hash-loser-b'"
             )
  end

  @tag :tmp_dir
  test "folds a three-way duplicate group onto the strictly richest row" do
    build_pre_migration_schema()

    seed_library_path("lib-plain", "/media/movies")
    seed_media_item("item-1")

    # Three active rows at one path. Dependent counts are made strictly
    # decreasing (winner 4, loser1 2, loser2 1) so the winner is unambiguous
    # from the primary "most dependents" signal alone and the outcome never
    # rests on the {inserted_at, id} tiebreak.
    seed_media_file("winner", "lib-plain", "Marrow Hollow (2015)/Marrow.Hollow.mkv", "item-1")
    seed_media_file("loser1", "lib-plain", "Marrow Hollow (2015)/Marrow.Hollow.mkv", "item-1")
    seed_media_file("loser2", "lib-plain", "Marrow Hollow (2015)/Marrow.Hollow.mkv", "item-1")

    # winner: 4 dependents (1 media_hashes + 2 subtitles + 1 subtitle_track_settings)
    sql!("INSERT INTO media_hashes (media_file_id, opensubtitles_hash) VALUES ('winner', 'aaa')")

    sql!(
      "INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('s-w1', 'winner', 'h1')"
    )

    sql!(
      "INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('s-w2', 'winner', 'h2')"
    )

    sql!(
      "INSERT INTO subtitle_track_settings (id, media_file_id, track_ref) VALUES ('trk1', 'winner', 'trk-w')"
    )

    # loser1: 2 dependents, one colliding with the winner (dropped) and one
    # that moves across untouched.
    sql!(
      "INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('s-l1-h2', 'loser1', 'h2')"
    )

    sql!(
      "INSERT INTO subtitles (id, media_file_id, subtitle_hash) VALUES ('s-l1-h3', 'loser1', 'h3')"
    )

    # loser2: 1 dependent, no counterpart on the winner, so it moves across.
    sql!(
      "INSERT INTO transcode_jobs (id, media_file_id, resolution, type) VALUES ('tj1', 'loser2', '1080p', 'download')"
    )

    run_migration!(FoldDuplicateMediaFilesAndEnforcePathUniqueness, @version)

    assert %{rows: [["winner"]]} = sql!("SELECT id FROM media_files")

    # s-l1-h2 collided with the winner's own h2 and was dropped; s-l1-h3 had
    # no counterpart and moved onto the winner alongside its original rows.
    assert %{rows: [["s-l1-h3", "h3"], ["s-w1", "h1"], ["s-w2", "h2"]]} =
             sql!("SELECT id, subtitle_hash FROM subtitles ORDER BY id")

    assert %{rows: [["winner", "aaa"]]} =
             sql!("SELECT media_file_id, opensubtitles_hash FROM media_hashes")

    assert %{rows: [["trk1", "winner", "trk-w"]]} =
             sql!("SELECT id, media_file_id, track_ref FROM subtitle_track_settings")

    # loser2's transcode_jobs row had no counterpart on the winner and moved.
    assert %{rows: [["tj1", "winner", "1080p", "download"]]} =
             sql!("SELECT id, media_file_id, resolution, type FROM transcode_jobs")
  end

  @tag :tmp_dir
  test "clears the winner's own supersedes pointer instead of pointing it at itself" do
    build_pre_migration_schema()

    seed_library_path("lib-plain", "/media/movies")
    seed_media_item("item-1")

    # winner was imported as an upgrade over loser (supersedes_media_file_id
    # points at loser), and loser is also the duplicate row this group folds
    # away. A plain repoint (UPDATE ... WHERE supersedes_media_file_id =
    # loser) would land on the winner too, since the winner's own pointer
    # matches the WHERE clause, leaving it pointing at itself.
    seed_media_file("winner", "lib-plain", "Amber Foundry (2013)/Amber.Foundry.mkv", "item-1")
    seed_media_file("loser", "lib-plain", "Amber Foundry (2013)/Amber.Foundry.mkv", "item-1")

    sql!("UPDATE media_files SET supersedes_media_file_id = 'loser' WHERE id = 'winner'")

    # Give the winner strictly more dependents so it is the unambiguous
    # winner regardless of the tiebreak.
    sql!("INSERT INTO media_hashes (media_file_id, opensubtitles_hash) VALUES ('winner', 'aaa')")

    run_migration!(FoldDuplicateMediaFilesAndEnforcePathUniqueness, @version)

    assert %{rows: [["winner", nil]]} =
             sql!("SELECT id, supersedes_media_file_id FROM media_files")
  end

  @tag :tmp_dir
  test "repoints a third row's supersedes pointer off the loser onto the winner" do
    build_pre_migration_schema()

    seed_library_path("lib-plain", "/media/movies")
    seed_media_item("item-1")

    seed_media_file("winner", "lib-plain", "Marrow Hollow (2015)/Marrow.Hollow.mkv", "item-1")
    seed_media_file("loser", "lib-plain", "Marrow Hollow (2015)/Marrow.Hollow.mkv", "item-1")

    seed_media_file(
      "newer",
      "lib-plain",
      "Marrow Hollow (2015) [newer]/Marrow.Hollow.mkv",
      "item-1"
    )

    sql!("UPDATE media_files SET supersedes_media_file_id = 'loser' WHERE id = 'newer'")
    sql!("INSERT INTO media_hashes (media_file_id, opensubtitles_hash) VALUES ('winner', 'aaa')")

    run_migration!(FoldDuplicateMediaFilesAndEnforcePathUniqueness, @version)

    assert %{rows: [["newer", "winner"], ["winner", nil]]} =
             sql!("SELECT id, supersedes_media_file_id FROM media_files ORDER BY id")
  end

  @tag :tmp_dir
  test "rejects a second active row at the same library path and relative path" do
    build_pre_migration_schema()

    seed_library_path("lib-plain", "/media/movies")
    seed_media_item("item-1")
    seed_media_file("first", "lib-plain", "Silver Harbour (2019)/Silver.Harbour.mkv", "item-1")

    run_migration!(FoldDuplicateMediaFilesAndEnforcePathUniqueness, @version)

    assert_raise Exqlite.Error, fn ->
      seed_media_file("second", "lib-plain", "Silver Harbour (2019)/Silver.Harbour.mkv", "item-1")
    end

    # A trashed row at the same path is outside the partial index.
    seed_media_file("third", "lib-plain", "Silver Harbour (2019)/Silver.Harbour.mkv", "item-1",
      trashed_at: "2026-08-01 00:00:00"
    )

    assert %{rows: [[2]]} = sql!("SELECT count(*) FROM media_files")
  end

  @tag :tmp_dir
  test "folds two active rows sharing a path under a non-absolute library root" do
    build_pre_migration_schema()

    seed_library_path("lib-relative", "media/movies")
    seed_media_item("item-1")

    seed_media_file(
      "first",
      "lib-relative",
      "Quiet Ledger (2017)/Quiet.Ledger.mkv",
      "item-1"
    )

    seed_media_file(
      "second",
      "lib-relative",
      "Quiet Ledger (2017)/Quiet.Ledger.mkv",
      "item-1"
    )

    run_migration!(FoldDuplicateMediaFilesAndEnforcePathUniqueness, @version)

    assert %{rows: [[1]]} = sql!("SELECT count(*) FROM media_files")

    assert_raise Exqlite.Error, fn ->
      seed_media_file(
        "third",
        "lib-relative",
        "Quiet Ledger (2017)/Quiet.Ledger.mkv",
        "item-1"
      )
    end
  end

  defp build_pre_migration_schema do
    sql!("CREATE TABLE library_paths (id TEXT PRIMARY KEY, path TEXT NOT NULL)")
    sql!("CREATE TABLE media_items (id TEXT PRIMARY KEY)")

    sql!("""
    CREATE TABLE media_files (
      id TEXT PRIMARY KEY,
      media_item_id TEXT REFERENCES media_items(id) ON DELETE CASCADE,
      episode_id TEXT,
      library_path_id TEXT REFERENCES library_paths(id) ON DELETE CASCADE,
      supersedes_media_file_id TEXT REFERENCES media_files(id) ON DELETE SET NULL,
      relative_path TEXT,
      trashed_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("""
    CREATE TABLE subtitles (
      id TEXT PRIMARY KEY,
      media_file_id TEXT REFERENCES media_files(id) ON DELETE CASCADE,
      subtitle_hash TEXT
    )
    """)

    sql!("CREATE UNIQUE INDEX subtitles_mf_hash ON subtitles (media_file_id, subtitle_hash)")

    sql!("""
    CREATE TABLE media_hashes (
      media_file_id TEXT PRIMARY KEY REFERENCES media_files(id) ON DELETE CASCADE,
      opensubtitles_hash TEXT
    )
    """)

    sql!("""
    CREATE TABLE subtitle_track_settings (
      id TEXT PRIMARY KEY,
      media_file_id TEXT REFERENCES media_files(id) ON DELETE CASCADE,
      track_ref TEXT
    )
    """)

    sql!("""
    CREATE TABLE transcode_jobs (
      id TEXT PRIMARY KEY,
      media_file_id TEXT REFERENCES media_files(id) ON DELETE CASCADE,
      resolution TEXT,
      type TEXT
    )
    """)

    sql!("""
    CREATE TABLE media_segments (
      id TEXT PRIMARY KEY,
      media_file_id TEXT REFERENCES media_files(id) ON DELETE CASCADE,
      type TEXT
    )
    """)

    # media_file_match_candidates is deliberately absent.
    # 20260830143721_split_import_candidates_from_media_files drops it, and that
    # migration runs first, so by the time the fold runs no database has the
    # table. Creating it here once hid #653's real failure: the fold only
    # touches a dependent table when a duplicate group exists, so a fresh
    # install migrated cleanly and CI stayed green while every populated
    # install crashed on boot with "no such table".
  end

  defp seed_library_path(id, path) do
    sql!("INSERT INTO library_paths (id, path) VALUES ('#{id}', '#{path}')")
  end

  defp seed_media_item(id) do
    sql!("INSERT INTO media_items (id) VALUES ('#{id}')")
  end

  defp seed_media_file(id, library_path_id, relative_path, media_item_id, opts \\ []) do
    trashed_at =
      case Keyword.get(opts, :trashed_at) do
        nil -> "NULL"
        value -> "'#{value}'"
      end

    sql!("""
    INSERT INTO media_files
      (id, media_item_id, library_path_id, relative_path, trashed_at, inserted_at, updated_at)
    VALUES
      ('#{id}', '#{media_item_id}', '#{library_path_id}', '#{relative_path}', #{trashed_at},
       '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)
  end
end
