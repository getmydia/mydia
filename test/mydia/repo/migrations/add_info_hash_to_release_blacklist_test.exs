defmodule Mydia.Repo.Migrations.AddInfoHashToReleaseBlacklistTest do
  use Mydia.DataCase, async: true

  alias Mydia.Downloads.ReleaseBlacklist
  alias Mydia.Repo
  alias Mydia.Repo.Migrations.AddInfoHashToReleaseBlacklist

  # Migration modules are not compiled into the app (priv/repo/migrations is
  # not in elixirc_paths), so load the file before calling into it. The test
  # database is already migrated, so the column exists and only the backfill
  # needs exercising.
  Code.require_file("priv/repo/migrations/20260922084004_add_info_hash_to_release_blacklist.exs")

  defp insert_row(guid) do
    now = DateTime.utc_now()

    Repo.insert!(%ReleaseBlacklist{
      indexer: "bitmagnet",
      guid: guid,
      title: "Fictional Release",
      failure_reason: "rejected_by_user",
      inserted_at: now,
      expires_at: DateTime.add(now, 30, :day)
    })
  end

  test "a bare 40-hex guid becomes the row's infohash, lowercased" do
    row = insert_row("AF95D579BE9393E54C1C6E5A7896414198ABD596")

    AddInfoHashToReleaseBlacklist.backfill(Repo)

    assert Repo.get!(ReleaseBlacklist, row.id).info_hash ==
             "af95d579be9393e54c1c6e5a7896414198abd596"
  end

  test "a synthesized sha256 guid is left without a hash" do
    row = insert_row("sha256:" <> String.duplicate("a", 64))

    AddInfoHashToReleaseBlacklist.backfill(Repo)

    assert is_nil(Repo.get!(ReleaseBlacklist, row.id).info_hash)
  end

  test "an indexer url guid is left without a hash" do
    row = insert_row("https://example.test/torrent/123/")

    AddInfoHashToReleaseBlacklist.backfill(Repo)

    assert is_nil(Repo.get!(ReleaseBlacklist, row.id).info_hash)
  end
end
